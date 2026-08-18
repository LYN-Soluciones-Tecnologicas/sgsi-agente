#!/usr/bin/env bash
#
# sgsi-agente — agente de descubrimiento y comprobación para los servidores
# de LYN. Corre dentro del servidor (donde las APIs de los proveedores no
# llegan), recolecta un informe JSON y, si está configurado, lo envía al
# backend del SGSI.
#
# Cinco reglas de diseño, en el orden en que importan:
#
#   1. SOLO LECTURA. No cambia nada del sistema; lo único que escribe es su
#      propio informe en /var/lib/sgsi-agente.
#   2. MIDE, NO JUZGA. El informe son hechos crudos; los criterios de qué está
#      bien o mal viven en el backend (comprobaciones.ts) y se revisan por
#      pull request. El «resumen» local es una evaluación de cortesía para
#      poder usar el agente suelto, no la fuente de verdad.
#   3. UNIDIRECCIONAL. El agente empuja; el backend jamás le ordena nada. No
#      hay canal de vuelta, no hay ejecución remota, no hay túnel.
#   4. SIN SECRETOS (regla 7 del SGSI). Huellas de claves, nunca claves;
#      nombres de ficheros .env, nunca contenidos; URLs de git sin usuario ni
#      token; líneas de cron con las credenciales tachadas.
#   5. TOLERANTE. Cada colector que falla deja `null` en su sección; un
#      servidor raro nunca tumba el informe entero.
#
# Requiere: bash 4+, jq, coreutils. Todo lo demás (docker, ss, ufw, nft,
# sshd, fail2ban, nginx, openssl…) se usa solo si está.

VERSION="0.2.0"
CONFIG="/etc/sgsi-agente/config"
ESTADO_DIR="/var/lib/sgsi-agente"

set -o nounset -o pipefail
export LC_ALL=C

# ── Configuración opcional ─────────────────────────────────────────────────
SGSI_URL=""
SGSI_TOKEN=""
BACKUP_RUTA=""
PUERTOS_ESPERADOS=""
# shellcheck disable=SC1090
[ -r "$CONFIG" ] && . "$CONFIG"

hay() { command -v "$1" >/dev/null 2>&1; }

# Ejecuta un colector; si falla o no emite JSON válido, la sección queda null.
seccion() {
  local salida
  if salida=$("$1" 2>/dev/null) && [ -n "$salida" ] \
     && printf '%s' "$salida" | jq -e . >/dev/null 2>&1; then
    printf '%s' "$salida"
  else
    printf 'null'
  fi
}

# Tacha credenciales incrustadas en URLs: https://usuario:token@host → https://host
sanear() { sed -E 's#(://)[^/@[:space:]]+@#\1#g'; }

# ── Servidor ───────────────────────────────────────────────────────────────
col_servidor() {
  local os_pretty="" os_id="" os_ver="" os_code=""
  if [ -r /etc/os-release ]; then
    # shellcheck disable=SC1091
    . /etc/os-release
    os_pretty="${PRETTY_NAME:-}"; os_id="${ID:-}"
    os_ver="${VERSION_ID:-}"; os_code="${VERSION_CODENAME:-}"
  fi
  local ips
  ips=$(ip -o -4 addr show scope global 2>/dev/null \
    | awk '{split($4,a,"/"); print a[1]}' | jq -R . | jq -s .)
  [ -n "$ips" ] || ips='[]'

  jq -n \
    --arg hostname "$(hostname)" \
    --arg fqdn "$(hostname -f 2>/dev/null || hostname)" \
    --arg so "$os_pretty" --arg distro "$os_id" \
    --arg version "$os_ver" --arg nombreClave "$os_code" \
    --arg kernel "$(uname -r)" --arg arquitectura "$(uname -m)" \
    --arg virtualizacion "$(systemd-detect-virt 2>/dev/null || echo desconocida)" \
    --arg zonaHoraria "$(timedatectl show -p Timezone --value 2>/dev/null || true)" \
    --arg arrancadoEl "$(uptime -s 2>/dev/null || true)" \
    --argjson cpus "$(nproc 2>/dev/null || echo 0)" \
    --argjson ramMb "$(awk '/^MemTotal/{print int($2/1024)}' /proc/meminfo 2>/dev/null || echo 0)" \
    --argjson swapMb "$(awk '/^SwapTotal/{print int($2/1024)}' /proc/meminfo 2>/dev/null || echo 0)" \
    --argjson ips "$ips" \
    '{hostname: $hostname, fqdn: $fqdn, so: $so, distro: $distro,
      version: $version, nombreClave: $nombreClave, kernel: $kernel,
      arquitectura: $arquitectura, virtualizacion: $virtualizacion,
      zonaHoraria: $zonaHoraria, arrancadoEl: $arrancadoEl, cpus: $cpus,
      ramMb: $ramMb, swapMb: $swapMb, ips: $ips}'
}

# ── Servicios systemd ──────────────────────────────────────────────────────
# «propio» = la unidad vive en /etc/systemd/system: la instaló una persona,
# no un paquete. Son las primeras candidatas a mapear a un activo del SGSI.
col_servicios() {
  hay systemctl || return 1
  local propios
  propios=$(find /etc/systemd/system -maxdepth 1 -name '*.service' -printf '%f\n' 2>/dev/null \
    | jq -R . | jq -s .)
  [ -n "$propios" ] || propios='[]'

  systemctl list-units --type=service --all --no-legend --plain 2>/dev/null \
    | sed 's/^[^[:alnum:]]*//' \
    | jq -R --argjson propios "$propios" '
        [splits(" +")] | select(length >= 4) |
        {unidad: .[0], activo: .[2], estado: .[3],
         descripcion: (.[4:] | join(" ")),
         propio: (.[0] as $u | ($propios | index($u)) != null)}' \
    | jq -s '[.[] | select(.unidad | endswith(".service"))]'
}

# ── Contenedores Docker ────────────────────────────────────────────────────
# Las etiquetas de docker compose son la mina para el mapeo: proyecto,
# servicio y directorio de despliegue de cada contenedor.
col_contenedores() {
  hay docker || return 1
  docker info >/dev/null 2>&1 || return 1
  local version ids
  version=$(docker --version 2>/dev/null | head -1)
  ids=$(docker ps -aq 2>/dev/null | tr '\n' ' ')
  if [ -z "${ids// /}" ]; then
    jq -n --arg version "$version" '{version: $version, total: 0, contenedores: []}'
    return 0
  fi
  # shellcheck disable=SC2086
  docker inspect $ids 2>/dev/null | jq --arg version "$version" '{
    version: $version,
    total: length,
    contenedores: map({
      nombre: (.Name | ltrimstr("/")),
      imagen: .Config.Image,
      etiquetaLatest: ((.Config.Image | test(":latest$"))
                       or ((.Config.Image | contains(":")) | not)),
      estado: .State.Status,
      salud: (.State.Health.Status // null),
      reinicios: .RestartCount,
      politicaReinicio: .HostConfig.RestartPolicy.Name,
      creadoEl: .Created,
      arrancadoEl: .State.StartedAt,
      proyectoCompose: (.Config.Labels["com.docker.compose.project"] // null),
      servicioCompose: (.Config.Labels["com.docker.compose.service"] // null),
      directorioCompose: (.Config.Labels["com.docker.compose.project.working_dir"] // null),
      # Repo de origen aunque no haya checkout en disco: la etiqueta OCI que
      # GitHub Actions/GHCR ponen al construir, o inferido del nombre ghcr.io.
      repositorio: ((.Config.Labels["org.opencontainers.image.source"] // null)
                    // ([.Config.Image | capture("^ghcr\\.io/(?<org>[^/]+)/(?<repo>[^/:@]+)")] | .[0]
                        | if . then "https://github.com/" + .org + "/" + .repo else null end)),
      revision: (.Config.Labels["org.opencontainers.image.revision"] // null),
      puertos: [ (.NetworkSettings.Ports // {}) | to_entries[]
                 | {interno: .key,
                    publicaciones: ((.value // []) | map({ip: .HostIp, puerto: .HostPort}))} ],
      expuestoAInternet: ([ (.NetworkSettings.Ports // {}) | to_entries[]
                            | (.value // [])[]? | .HostIp ]
                          | any(. == "0.0.0.0" or . == "::"))
    })
  }'
}

# ── Aplicaciones desplegadas ───────────────────────────────────────────────
# El corazón del descubrimiento para el SGSI: qué hay desplegado, en qué
# directorio, y DE QUÉ REPOSITORIO viene. Con esto cada servicio del servidor
# se puede mapear a un activo del inventario y a su repositorio en GitHub.
#
# Candidatos, por tres vías que se complementan:
#   a) directorios de trabajo de los proyectos de docker compose;
#   b) cwd de procesos de aplicación vivos (node, python, php, java…);
#   c) convención: /var/www, /srv, /opt y /home/* con .git o compose.
col_aplicaciones() {
  local -a candidatos=()
  local d base pid

  if hay docker && docker info >/dev/null 2>&1; then
    while IFS= read -r d; do
      [ -n "$d" ] && candidatos+=("$d")
    done < <(docker ps -aq 2>/dev/null | xargs -r docker inspect 2>/dev/null \
      | jq -r '.[].Config.Labels["com.docker.compose.project.working_dir"] // empty' \
      | sort -u)
  fi

  while IFS= read -r pid; do
    d=$(readlink "/proc/$pid/cwd" 2>/dev/null) || continue
    case "$d" in
      /|/root|/usr*|/proc*|/sys*|/dev*|/run*|/tmp*) continue ;;
    esac
    candidatos+=("$d")
  done < <(ps -eo pid=,comm= 2>/dev/null \
    | awk '$2 ~ /^(node|python[0-9.]*|php|php-fpm[0-9.]*|java|ruby|gunicorn|uvicorn|dotnet|bun|deno)$/ {print $1}')

  for base in /var/www /srv /opt /home/*; do
    [ -d "$base" ] || continue
    for d in "$base"/*; do
      [ -d "$d" ] || continue
      if [ -e "$d/.git" ] || [ -f "$d/docker-compose.yml" ] \
         || [ -f "$d/docker-compose.yaml" ] || [ -f "$d/compose.yaml" ]; then
        candidatos+=("$d")
      fi
    done
  done

  if [ "${#candidatos[@]}" -eq 0 ]; then
    echo '[]'
    return 0
  fi

  printf '%s\n' "${candidatos[@]}" | sort -u | while IFS= read -r ruta; do
    [ -d "$ruta" ] || continue
    raiz=$(git -C "$ruta" rev-parse --show-toplevel 2>/dev/null || true)
    repo=""; rama=""; commit=""; fechaCommit=""
    if [ -n "$raiz" ]; then
      ruta="$raiz"
      repo=$(git -C "$raiz" config --get remote.origin.url 2>/dev/null | sanear || true)
      rama=$(git -C "$raiz" rev-parse --abbrev-ref HEAD 2>/dev/null || true)
      commit=$(git -C "$raiz" rev-parse --short HEAD 2>/dev/null || true)
      fechaCommit=$(git -C "$raiz" log -1 --format=%cI 2>/dev/null || true)
    fi

    tieneCompose=false
    { [ -f "$ruta/docker-compose.yml" ] || [ -f "$ruta/docker-compose.yaml" ] \
      || [ -f "$ruta/compose.yaml" ]; } && tieneCompose=true

    # Ficheros .env: solo nombre y permisos, JAMÁS su contenido (regla 7).
    envs=$(find "$ruta" -maxdepth 1 -name '.env*' ! -name '*.example' ! -name '*.sample' \
             -type f 2>/dev/null \
      | while IFS= read -r f; do
          modo=$(stat -c '%a' "$f" 2>/dev/null) || continue
          otros="${modo: -1}"
          jq -n --arg nombre "$(basename "$f")" --arg permisos "$modo" \
            --argjson legiblePorTodos "$( [ "$otros" -ge 4 ] 2>/dev/null && echo true || echo false )" \
            '{nombre: $nombre, permisos: $permisos, legiblePorTodos: $legiblePorTodos}'
        done | jq -s .)
    [ -n "$envs" ] || envs='[]'

    jq -n --arg ruta "$ruta" --arg repositorio "$repo" --arg rama "$rama" \
      --arg commit "$commit" --arg fechaCommit "$fechaCommit" \
      --argjson tieneCompose "$tieneCompose" --argjson ficherosEnv "$envs" \
      '{ruta: $ruta,
        repositorio: (if $repositorio == "" then null else $repositorio end),
        rama: (if $rama == "" then null else $rama end),
        commit: (if $commit == "" then null else $commit end),
        fechaCommit: (if $fechaCommit == "" then null else $fechaCommit end),
        tieneCompose: $tieneCompose, ficherosEnv: $ficherosEnv}'
  done | jq -s 'unique_by(.ruta)'
}

# ── Puertos a la escucha ───────────────────────────────────────────────────
col_puertos() {
  hay ss || return 1
  ss -tulpnH 2>/dev/null | jq -R '
    [splits(" +")] | select(length >= 5) |
    ([.[4] | capture("^(?<dir>.*):(?<puerto>[0-9]+)$")] | .[0]) as $l |
    select($l != null) |
    ([(.[6] // "") | capture("\\(\\(\"(?<n>[^\"]+)\",pid=(?<pid>[0-9]+)")] | .[0]) as $p |
    {proto: .[0], direccion: $l.dir, puerto: ($l.puerto | tonumber),
     proceso: (if $p != null then {nombre: $p.n, pid: ($p.pid | tonumber)} else null end),
     expuesto: ($l.dir | IN("0.0.0.0", "::", "*", "[::]"))}' \
  | jq -s 'unique_by([.proto, .puerto, .direccion])'
}

# ── Web: dominios servidos y certificados ──────────────────────────────────
col_web() {
  local dominios='[]' certs='[]' renovacion=false

  if hay nginx; then
    dominios=$(nginx -T 2>/dev/null \
      | awk '/^[ \t]*server_name/ {for (i = 2; i <= NF; i++) {gsub(/;/, "", $i); if ($i != "_" && $i != "localhost") print $i}}' \
      | sort -u | jq -R . | jq -s .)
    [ -n "$dominios" ] || dominios='[]'
  elif hay apache2ctl; then
    dominios=$(apache2ctl -S 2>/dev/null \
      | awk '/namevhost/ {print $4}' | sort -u | jq -R . | jq -s .)
    [ -n "$dominios" ] || dominios='[]'
  fi

  if hay openssl; then
    certs=$( { find /etc/letsencrypt/live -name fullchain.pem 2>/dev/null;
               nginx -T 2>/dev/null \
                 | awk '/^[ \t]*ssl_certificate[ \t]/ {gsub(/;/, "", $2); print $2}'; } \
      | sort -u | while IFS= read -r c; do
          [ -r "$c" ] || continue
          fin=$(openssl x509 -enddate -noout -in "$c" 2>/dev/null | cut -d= -f2-) || continue
          fin_epoch=$(date -d "$fin" +%s 2>/dev/null) || continue
          dias=$(( (fin_epoch - $(date +%s)) / 86400 ))
          sujeto=$(openssl x509 -subject -noout -in "$c" 2>/dev/null | sed 's/^subject=//')
          jq -n --arg ruta "$c" --arg sujeto "$sujeto" \
            --arg caducaEl "$(date -d "$fin" -Iseconds 2>/dev/null || echo "$fin")" \
            --argjson diasRestantes "$dias" \
            '{ruta: $ruta, sujeto: $sujeto, caducaEl: $caducaEl, diasRestantes: $diasRestantes}'
        done | jq -s 'unique_by(.sujeto) | sort_by(.diasRestantes)')
    [ -n "$certs" ] || certs='[]'
  fi

  systemctl is-active --quiet certbot.timer 2>/dev/null && renovacion=true

  jq -n --argjson dominios "$dominios" --argjson certificados "$certs" \
    --argjson renovacionAutomatica "$renovacion" \
    '{dominios: $dominios, certificados: $certificados,
      renovacionAutomatica: $renovacionAutomatica}'
}

# ── Accesos: usuarios, sudo y claves SSH ───────────────────────────────────
# Las huellas de authorized_keys son la evidencia técnica de las altas y
# bajas: una clave que no corresponde a nadie del inventario es un acceso
# que alguien olvidó retirar.
col_accesos() {
  local usuarios claves sudoers grupo_sudo nopasswd

  grupo_sudo=$( { getent group sudo; getent group admin; getent group wheel; } 2>/dev/null \
    | cut -d: -f4 | tr ',' '\n' | sed '/^$/d' | sort -u | jq -R . | jq -s .)
  [ -n "$grupo_sudo" ] || grupo_sudo='[]'

  usuarios=$(getent passwd 2>/dev/null \
    | awk -F: '$7 !~ /(nologin|false)$/ {print $1 "\t" $3 "\t" $6 "\t" $7}' \
    | while IFS=$'\t' read -r u uid home shell; do
        ultimo=$(lastlog -u "$u" 2>/dev/null | awk 'NR == 2 && $2 != "" {$1 = ""; sub(/^ +/, ""); print}')
        case "$ultimo" in
          (*Never*) ultimo="" ;;
        esac
        jq -n --arg usuario "$u" --argjson uid "$uid" --arg home "$home" \
          --arg shell "$shell" --arg ultimoAcceso "$ultimo" \
          --argjson grupoSudo "$grupo_sudo" \
          '{usuario: $usuario, uid: $uid, home: $home, shell: $shell,
            ultimoAcceso: (if $ultimoAcceso == "" then null else $ultimoAcceso end),
            sudo: (($grupoSudo | index($usuario)) != null or $uid == 0)}'
      done | jq -s .)
  [ -n "$usuarios" ] || usuarios='[]'

  claves=$(getent passwd 2>/dev/null | awk -F: '{print $1 "\t" $6}' \
    | while IFS=$'\t' read -r u home; do
        fichero="$home/.ssh/authorized_keys"
        [ -r "$fichero" ] || continue
        ssh-keygen -lf "$fichero" 2>/dev/null | while IFS= read -r linea; do
          jq -n --arg usuario "$u" --arg clave "$linea" '
            ($clave | [splits(" +")]) as $c |
            {usuario: $usuario, bits: ($c[0] | tonumber? // null), huella: $c[1],
             comentario: ($c[2:-1] | join(" ")), tipo: ($c[-1] | gsub("[()]"; ""))}'
        done
      done | jq -s .)
  [ -n "$claves" ] || claves='[]'

  sudoers=$(find /etc/sudoers.d -maxdepth 1 -type f -printf '%f\n' 2>/dev/null \
    | jq -R . | jq -s .)
  [ -n "$sudoers" ] || sudoers='[]'
  nopasswd=$(grep -hs NOPASSWD /etc/sudoers /etc/sudoers.d/* 2>/dev/null \
    | grep -cv '^\s*#' || true)

  jq -n --argjson usuarios "$usuarios" --argjson clavesSsh "$claves" \
    --argjson ficherosSudoers "$sudoers" --argjson reglasNopasswd "${nopasswd:-0}" \
    '{usuarios: $usuarios, clavesSsh: $clavesSsh,
      ficherosSudoers: $ficherosSudoers, reglasNopasswd: $reglasNopasswd}'
}

# ── Parches y actualizaciones ──────────────────────────────────────────────
col_parches() {
  hay apt-get || return 1
  local simulado pendientes seguridad lista reboot_req reboot_edad_dias
  local autoactivas indices manuales

  simulado=$(apt-get -s dist-upgrade 2>/dev/null | grep '^Inst ' || true)
  pendientes=$(printf '%s\n' "$simulado" | grep -c '^Inst ' || true)
  seguridad=$(printf '%s\n' "$simulado" | grep -ci 'securi' || true)
  lista=$(printf '%s\n' "$simulado" | grep -i 'securi' | awk '{print $2}' \
    | head -50 | jq -R . | jq -s .)
  [ -n "$lista" ] || lista='[]'

  reboot_req=false; reboot_edad_dias=null
  if [ -f /var/run/reboot-required ]; then
    reboot_req=true
    reboot_edad_dias=$(( ($(date +%s) - $(stat -c %Y /var/run/reboot-required)) / 86400 ))
  fi

  autoactivas=false
  if [ "$(apt-config dump APT::Periodic::Unattended-Upgrade 2>/dev/null \
          | grep -o '"[0-9]*"' | tr -d '"')" = "1" ] \
     && systemctl is-enabled --quiet apt-daily-upgrade.timer 2>/dev/null; then
    autoactivas=true
  fi

  indices=null
  if [ -f /var/lib/apt/periodic/update-success-stamp ]; then
    indices=$(( ($(date +%s) - $(stat -c %Y /var/lib/apt/periodic/update-success-stamp)) / 3600 ))
  elif [ -f /var/cache/apt/pkgcache.bin ]; then
    indices=$(( ($(date +%s) - $(stat -c %Y /var/cache/apt/pkgcache.bin)) / 3600 ))
  fi

  manuales=$(apt-mark showmanual 2>/dev/null | jq -R . | jq -s .)
  [ -n "$manuales" ] || manuales='[]'

  jq -n --argjson pendientes "${pendientes:-0}" --argjson seguridadPendientes "${seguridad:-0}" \
    --argjson paquetesSeguridad "$lista" --argjson reinicioPendiente "$reboot_req" \
    --argjson reinicioPendienteDias "$reboot_edad_dias" \
    --argjson actualizacionesAutomaticas "$autoactivas" \
    --argjson indicesActualizadosHaceHoras "$indices" \
    --argjson paquetesManuales "$manuales" \
    '{pendientes: $pendientes, seguridadPendientes: $seguridadPendientes,
      paquetesSeguridad: $paquetesSeguridad, reinicioPendiente: $reinicioPendiente,
      reinicioPendienteDias: $reinicioPendienteDias,
      actualizacionesAutomaticas: $actualizacionesAutomaticas,
      indicesActualizadosHaceHoras: $indicesActualizadosHaceHoras,
      paquetesManuales: {total: ($paquetesManuales | length),
                         lista: $paquetesManuales}}'
}

# ── Tareas programadas ─────────────────────────────────────────────────────
col_programadas() {
  local cron timers u f

  cron=$( {
    for f in /etc/crontab /etc/cron.d/*; do
      [ -f "$f" ] || continue
      grep -v '^\s*#' "$f" 2>/dev/null | grep -v '^\s*$' | grep -v '^[A-Z_]*=' \
        | sanear | while IFS= read -r linea; do
            jq -n --arg origen "$f" --arg linea "$linea" '{origen: $origen, linea: $linea}'
          done
    done
    if hay crontab; then
      for u in $(cut -d: -f1 /etc/passwd); do
        crontab -l -u "$u" 2>/dev/null | grep -v '^\s*#' | grep -v '^\s*$' \
          | sanear | while IFS= read -r linea; do
              jq -n --arg origen "crontab:$u" --arg linea "$linea" '{origen: $origen, linea: $linea}'
            done
      done
    fi
  } | jq -s .)
  [ -n "$cron" ] || cron='[]'

  # systemd 246+ sabe emitir JSON; para los anteriores, lista simple.
  timers=$(systemctl list-timers --all --output=json 2>/dev/null \
    | jq 'map({timer: .unit, activa: .activates, proxima: (.next // null), ultima: (.last // null)})' \
    || true)
  if [ -z "$timers" ]; then
    timers=$(systemctl list-unit-files --type=timer --state=enabled --no-legend --plain 2>/dev/null \
      | awk '{print $1}' | jq -R '{timer: ., activa: null, proxima: null, ultima: null}' | jq -s .)
  fi
  [ -n "$timers" ] || timers='[]'

  jq -n --argjson cron "$cron" --argjson timers "$timers" \
    '{cron: $cron, timers: $timers}'
}

# ── Copias de seguridad ────────────────────────────────────────────────────
# El agente no sabe qué política de copias hay: reporta los INDICIOS (qué
# herramientas existen, qué tareas suenan a copia, y la frescura del
# directorio configurado) y el criterio se aplica al otro lado.
col_copias() {
  local herramientas indicios ultima b

  herramientas=$(for b in restic borg rclone duplicity rsnapshot pg_dump mysqldump; do
      hay "$b" && echo "$b"
    done | jq -R . | jq -s .)
  [ -n "$herramientas" ] || herramientas='[]'

  indicios=$( { grep -rhsiE 'backup|copia|restic|borg|dump|snapshot' \
                  /etc/crontab /etc/cron.d /etc/cron.daily /etc/cron.weekly 2>/dev/null \
                | grep -v '^\s*#' | sanear
                systemctl list-unit-files --type=timer --no-legend --plain 2>/dev/null \
                | awk '{print $1}' | grep -iE 'backup|copia|restic|borg|snapshot'
              } | head -20 | jq -R . | jq -s .)
  [ -n "$indicios" ] || indicios='[]'

  ultima=null
  if [ -n "$BACKUP_RUTA" ] && [ -d "$BACKUP_RUTA" ]; then
    ultima=$(find "$BACKUP_RUTA" -type f -printf '%T@ %p\n' 2>/dev/null \
      | sort -nr | head -1 \
      | jq -R 'if . == "" then null else
          ([splits(" ")] | {fichero: (.[1:] | join(" ")),
                            haceHoras: ((now - (.[0] | tonumber)) / 3600 | floor)})
        end')
    [ -n "$ultima" ] || ultima=null
  fi

  jq -n --argjson herramientas "$herramientas" --argjson indicios "$indicios" \
    --argjson ultimaCopia "$ultima" --arg ruta "$BACKUP_RUTA" \
    '{herramientas: $herramientas, indicios: $indicios,
      rutaVigilada: (if $ruta == "" then null else $ruta end),
      ultimaCopia: $ultimaCopia}'
}

# ── Medidas de seguridad ───────────────────────────────────────────────────
col_seguridad() {
  local ufw_json nft_json docker_user ssh_json f2b_json ntp_json reg_json

  # Cortafuegos de host. OJO: docker publica puertos directamente en
  # iptables y PUENTEA ufw; por eso se mira también la cadena DOCKER-USER.
  ufw_json='null'
  if hay ufw; then
    local ufw_salida ufw_activo=false ufw_defecto=""
    ufw_salida=$(ufw status verbose 2>/dev/null || true)
    grep -q '^Status: active' <<< "$ufw_salida" && ufw_activo=true
    ufw_defecto=$(grep '^Default:' <<< "$ufw_salida" | sed 's/^Default: //' || true)
    local ufw_reglas
    ufw_reglas=$(ufw status numbered 2>/dev/null | grep -c '^\[')
    ufw_json=$(jq -n --argjson activo "$ufw_activo" --arg porDefecto "$ufw_defecto" \
      --argjson reglas "${ufw_reglas:-0}" \
      '{activo: $activo, porDefecto: $porDefecto, reglas: $reglas}')
  fi

  nft_json='null'
  if hay nft; then
    local nft_reglas nft_drop=false
    nft_reglas=$(nft list ruleset 2>/dev/null || true)
    grep -E 'type filter hook input' <<< "$nft_reglas" | grep -q 'policy drop' && nft_drop=true
    nft_json=$(jq -n \
      --argjson presente "$( [ -n "$nft_reglas" ] && echo true || echo false )" \
      --argjson politicaDropEntrada "$nft_drop" \
      '{presente: $presente, politicaDropEntrada: $politicaDropEntrada}')
  fi

  docker_user=0
  if hay iptables; then
    docker_user=$(iptables -S DOCKER-USER 2>/dev/null \
      | grep -v '^-N' | grep -cv 'RETURN' || true)
  fi

  # Configuración EFECTIVA del sshd (sshd -T exige root; si no, el fichero).
  ssh_json='null'
  local ssh_conf=""
  if hay sshd; then ssh_conf=$(sshd -T 2>/dev/null || true); fi
  if [ -z "$ssh_conf" ] && [ -r /etc/ssh/sshd_config ]; then
    ssh_conf=$(grep -vE '^\s*#' /etc/ssh/sshd_config | tr '[:upper:]' '[:lower:]')
  fi
  if [ -n "$ssh_conf" ]; then
    coge() { awk -v k="$1" '$1 == k {print $2; exit}' <<< "$ssh_conf"; }
    local fallidos=null
    if hay journalctl; then
      fallidos=$(journalctl -u ssh -u sshd --since '24 hours ago' 2>/dev/null \
        | grep -cE 'Failed password|Invalid user')
      fallidos=${fallidos:-0}
    fi
    ssh_json=$(jq -n \
      --arg puerto "$(coge port)" \
      --arg autenticacionContrasena "$(coge passwordauthentication)" \
      --arg accesoRoot "$(coge permitrootlogin)" \
      --arg autenticacionClave "$(coge pubkeyauthentication)" \
      --arg maxIntentos "$(coge maxauthtries)" \
      --arg x11 "$(coge x11forwarding)" \
      --argjson intentosFallidos24h "${fallidos:-null}" \
      '{puerto: ($puerto | tonumber? // $puerto),
        autenticacionContrasena: $autenticacionContrasena,
        accesoRoot: $accesoRoot, autenticacionClave: $autenticacionClave,
        maxIntentos: ($maxIntentos | tonumber? // null), x11: $x11,
        intentosFallidos24h: $intentosFallidos24h}')
  fi

  f2b_json='null'
  if hay fail2ban-client && fail2ban-client ping >/dev/null 2>&1; then
    local jails baneados=0 j n
    jails=$(fail2ban-client status 2>/dev/null \
      | awk -F: '/Jail list/ {gsub(/[ \t]/, "", $2); print $2}' | tr ',' ' ')
    for j in $jails; do
      n=$(fail2ban-client status "$j" 2>/dev/null \
        | awk -F: '/Currently banned/ {gsub(/[ \t]/, "", $2); print $2}')
      baneados=$(( baneados + ${n:-0} ))
    done
    f2b_json=$(jq -n \
      --argjson carceles "$(printf '%s\n' $jails | sed '/^$/d' | jq -R . | jq -s .)" \
      --argjson baneadosAhora "$baneados" \
      '{activo: true, carceles: $carceles, baneadosAhora: $baneadosAhora}')
  elif hay fail2ban-client; then
    f2b_json='{"activo": false}'
  fi

  ntp_json=$(jq -n \
    --arg sincronizado "$(timedatectl show -p NTPSynchronized --value 2>/dev/null || true)" \
    --arg servicio "$(timedatectl show -p NTP --value 2>/dev/null || true)" \
    '{sincronizado: ($sincronizado == "yes"), servicioActivo: ($servicio == "yes")}')

  reg_json=$(jq -n \
    --argjson journalPersistente "$( [ -d /var/log/journal ] && echo true || echo false )" \
    --argjson rsyslogActivo "$(systemctl is-active --quiet rsyslog 2>/dev/null && echo true || echo false)" \
    --argjson logrotate "$( [ -f /etc/logrotate.conf ] && echo true || echo false )" \
    '{journalPersistente: $journalPersistente, rsyslogActivo: $rsyslogActivo,
      logrotate: $logrotate}')

  jq -n --argjson ufw "$ufw_json" --argjson nftables "$nft_json" \
    --argjson reglasDockerUser "${docker_user:-0}" --argjson ssh "$ssh_json" \
    --argjson fail2ban "$f2b_json" --argjson ntp "$ntp_json" \
    --argjson registros "$reg_json" \
    '{cortafuegos: {ufw: $ufw, nftables: $nftables,
                    reglasDockerUser: $reglasDockerUser},
      ssh: $ssh, fail2ban: $fail2ban, ntp: $ntp, registros: $registros}'
}

# ── Recursos: disco, inodos, memoria, carga ────────────────────────────────
col_recursos() {
  local discos inodos memoria carga

  discos=$(df -PT 2>/dev/null \
    | awk 'NR > 1 && $2 !~ /tmpfs|squashfs|devtmpfs|overlay|iso9660/ \
        {gsub(/%/, "", $6); print $1 "\t" $2 "\t" $7 "\t" int($3/1024) "\t" $6}' \
    | while IFS=$'\t' read -r fs tipo montaje mb uso; do
        jq -n --arg sistema "$fs" --arg tipo "$tipo" --arg montaje "$montaje" \
          --argjson tamanoMb "$mb" --argjson usoPct "$uso" \
          '{sistema: $sistema, tipo: $tipo, montaje: $montaje,
            tamanoMb: $tamanoMb, usoPct: $usoPct}'
      done | jq -s .)
  [ -n "$discos" ] || discos='[]'

  inodos=$(df -Pi 2>/dev/null \
    | awk 'NR > 1 && $1 !~ /tmpfs|devtmpfs|overlay/ && $5 ~ /%/ \
        {gsub(/%/, "", $5); print $6 "\t" $5}' \
    | while IFS=$'\t' read -r montaje uso; do
        jq -n --arg montaje "$montaje" --argjson usoPct "$uso" \
          '{montaje: $montaje, usoPct: $usoPct}'
      done | jq -s .)
  [ -n "$inodos" ] || inodos='[]'

  memoria=$(free -m 2>/dev/null | awk '
    /^Mem:/  {mt = $2; mu = $3; md = $7}
    /^Swap:/ {st = $2; su = $3}
    END {printf "{\"totalMb\": %d, \"usadaMb\": %d, \"disponibleMb\": %d, \"swapTotalMb\": %d, \"swapUsadaMb\": %d}", mt, mu, md, st, su}')
  [ -n "$memoria" ] || memoria='null'

  carga=$(awk '{printf "[%s, %s, %s]", $1, $2, $3}' /proc/loadavg 2>/dev/null)
  [ -n "$carga" ] || carga='null'

  jq -n --argjson discos "$discos" --argjson inodos "$inodos" \
    --argjson memoria "$memoria" --argjson carga "$carga" \
    '{discos: $discos, inodos: $inodos, memoria: $memoria, carga: $carga}'
}

# ── Versiones de runtimes ──────────────────────────────────────────────────
col_versiones() {
  local b v
  for b in node python3 php nginx docker git openssl psql; do
    hay "$b" || continue
    v=$("$b" --version 2>&1 | head -1)
    jq -n --arg binario "$b" --arg version "$v" '{binario: $binario, version: $version}'
  done | jq -s .
}

# ── Evaluación local ───────────────────────────────────────────────────────
# Cortesía para usar el agente suelto; cuando el conector «agente» exista en
# el SGSI, la fuente de verdad serán sus definiciones (comprobaciones.ts).
evaluar() {
  local esperados='null'
  if [ -n "$PUERTOS_ESPERADOS" ]; then
    esperados=$(tr ',' '\n' <<< "$PUERTOS_ESPERADOS" | sed 's/[^0-9]//g' \
      | sed '/^$/d' | jq -R 'tonumber' | jq -s .)
  fi

  printf '%s' "$1" | jq --argjson esperados "$esperados" '
    def comp(c; e; d): {codigo: c, estado: e, detalle: d};
    def si(cond): if cond then "pasa" else "falla" end;

    (.seguridad.cortafuegos // null) as $fw |
    (.seguridad.ssh // null) as $ssh |
    ([.contenedores.contenedores // [] | .[] | select(.expuestoAInternet) | .nombre]) as $dockerExpuesto |
    ([.red.puertos // [] | .[] | select(.expuesto)]) as $expuestos |

    [
      (if $fw == null then comp("srv-cortafuegos"; "no_aplica"; {motivo: "sin datos"})
       else ((($fw.ufw.activo // false) and (($fw.ufw.porDefecto // "") | test("deny|reject"))) or
             ($fw.nftables.politicaDropEntrada // false)) as $ok |
         comp("srv-cortafuegos"; si($ok);
              {ufw: ($fw.ufw.activo // false), nftables: ($fw.nftables.politicaDropEntrada // false)})
       end),

      (if (.contenedores // null) == null then comp("srv-docker-expuesto"; "no_aplica"; {motivo: "sin docker"})
       else comp("srv-docker-expuesto";
              si(($dockerExpuesto | length) == 0 or (($fw.reglasDockerUser // 0) > 0));
              {contenedores: $dockerExpuesto, reglasDockerUser: ($fw.reglasDockerUser // 0),
               nota: "docker publica en iptables y puentea ufw; si hay contenedores en 0.0.0.0 hace falta gobernar DOCKER-USER o publicar en 127.0.0.1"})
       end),

      (if $ssh == null then comp("srv-ssh-contrasena"; "no_aplica"; {motivo: "sin datos"})
       else comp("srv-ssh-contrasena"; si(($ssh.autenticacionContrasena // "") == "no");
                 {valor: ($ssh.autenticacionContrasena // null)}) end),

      (if $ssh == null then comp("srv-ssh-root"; "no_aplica"; {motivo: "sin datos"})
       else comp("srv-ssh-root"; si(($ssh.accesoRoot // "") | IN("no", "prohibit-password", "without-password"));
                 {valor: ($ssh.accesoRoot // null)}) end),

      (if (.seguridad.fail2ban // null) == null then comp("srv-fuerza-bruta"; "no_aplica"; {motivo: "sin fail2ban instalado"})
       else comp("srv-fuerza-bruta"; si(.seguridad.fail2ban.activo == true);
                 {baneadosAhora: (.seguridad.fail2ban.baneadosAhora // 0),
                  intentosFallidos24h: ($ssh.intentosFallidos24h // null)}) end),

      (if (.parches // null) == null then comp("srv-parches"; "no_aplica"; {motivo: "sin datos"})
       else comp("srv-parches"; si((.parches.seguridadPendientes // 0) == 0);
                 {seguridadPendientes: .parches.seguridadPendientes,
                  pendientes: .parches.pendientes}) end),

      (if (.parches // null) == null then comp("srv-reinicio-pendiente"; "no_aplica"; {motivo: "sin datos"})
       else comp("srv-reinicio-pendiente"; si((.parches.reinicioPendiente // false) | not);
                 {dias: .parches.reinicioPendienteDias}) end),

      (if (.parches // null) == null then comp("srv-actualizaciones-automaticas"; "no_aplica"; {motivo: "sin datos"})
       else comp("srv-actualizaciones-automaticas"; si(.parches.actualizacionesAutomaticas == true);
                 {}) end),

      comp("srv-reloj"; si(.seguridad.ntp.sincronizado == true);
           {servicioActivo: (.seguridad.ntp.servicioActivo // false)}),

      comp("srv-registros";
           si((.seguridad.registros.journalPersistente == true) or (.seguridad.registros.rsyslogActivo == true));
           (.seguridad.registros // {})),

      comp("srv-disco"; si([.recursos.discos // [] | .[] | .usoPct] | all(. < 85));
           {peor: ([.recursos.discos // [] | .[]] | max_by(.usoPct) // null)}),

      (if ((.web.certificados // []) | length) == 0 then comp("srv-certificados"; "no_aplica"; {motivo: "sin certificados detectados"})
       else comp("srv-certificados"; si([.web.certificados[].diasRestantes] | all(. >= 30));
                 {porCaducar: [.web.certificados[] | select(.diasRestantes < 30)],
                  renovacionAutomatica: (.web.renovacionAutomatica // false)}) end),

      comp("srv-bd-expuesta";
           si([$expuestos[] | select(.puerto | IN(5432, 3306, 6379, 27017, 9200, 11211, 5672))] | length == 0);
           {puertos: [$expuestos[] | select(.puerto | IN(5432, 3306, 6379, 27017, 9200, 11211, 5672))]}),

      comp("srv-env-legibles";
           si([.aplicaciones // [] | .[] | .ficherosEnv[]? | select(.legiblePorTodos)] | length == 0);
           {ficheros: [.aplicaciones // [] | .[] | . as $a | .ficherosEnv[]? |
                       select(.legiblePorTodos) | {ruta: $a.ruta, nombre: .nombre, permisos: .permisos}]}),

      (if (.copias // null) == null then comp("srv-copias"; "no_aplica"; {motivo: "sin datos"})
       else comp("srv-copias";
              si(((.copias.herramientas | length) > 0 and (.copias.indicios | length) > 0) or
                 ((.copias.ultimaCopia.haceHoras // 9999) < 48));
              {herramientas: .copias.herramientas, indicios: (.copias.indicios | length),
               ultimaCopia: .copias.ultimaCopia}) end),

      (if $esperados == null then
         comp("srv-puertos"; "no_aplica";
              {motivo: "sin línea base (PUERTOS_ESPERADOS)",
               expuestosAhora: ([$expuestos[].puerto] | unique)})
       else comp("srv-puertos";
              si([$expuestos[].puerto] | unique | all(. as $p | $esperados | index($p) != null));
              {inesperados: ([$expuestos[].puerto] | unique | map(select(. as $p | ($esperados | index($p)) == null))),
               lineaBase: $esperados}) end),

      comp("srv-servicios-caidos";
           si([.servicios // [] | .[] | select(.activo == "failed")] | length == 0);
           {caidos: [.servicios // [] | .[] | select(.activo == "failed") | .unidad]}),

      (if (.contenedores // null) == null then comp("srv-contenedores"; "no_aplica"; {motivo: "sin docker"})
       else comp("srv-contenedores";
              si([.contenedores.contenedores[] |
                  select(.estado == "restarting" or .salud == "unhealthy")] | length == 0);
              {conProblemas: [.contenedores.contenedores[] |
                select(.estado == "restarting" or .salud == "unhealthy") |
                {nombre, estado, salud}]}) end)
    ]'
}

# ── Envío al SGSI ──────────────────────────────────────────────────────────
enviar() {
  local fichero="$1"
  [ -n "$SGSI_URL" ] && [ -n "$SGSI_TOKEN" ] || return 0
  if curl -fsS --max-time 60 -X POST "${SGSI_URL%/}/api/agentes/informe" \
       -H "Authorization: Bearer $SGSI_TOKEN" \
       -H "Content-Type: application/json" \
       --data-binary @"$fichero" >/dev/null 2>&1; then
    echo "informe enviado a ${SGSI_URL%/}" >&2
  else
    echo "AVISO: no se pudo enviar el informe a ${SGSI_URL%/}; queda en $fichero" >&2
  fi
}

# ── Principal ──────────────────────────────────────────────────────────────
uso() {
  cat <<FIN
sgsi-agente $VERSION — descubre y mide el estado de este servidor para el SGSI.

Uso: sgsi-agente [opción]
  (sin opción)  genera el informe, lo guarda en $ESTADO_DIR y lo envía si hay config
  --stdout      imprime el informe completo y no guarda ni envía nada
  --resumen     imprime solo la tabla de comprobaciones, legible
  --seccion N   imprime solo una sección (servidor, servicios, contenedores,
                aplicaciones, puertos, web, accesos, parches, programadas,
                copias, seguridad, recursos, versiones)
  --version     versión del agente
FIN
}

generar_informe() {
  local inicio="$SECONDS" completo=true
  [ "$(id -u)" = 0 ] || { completo=false; echo "AVISO: sin root el informe queda incompleto (claves ssh, procesos, sshd -T…)" >&2; }

  local servidor servicios contenedores aplicaciones puertos web accesos
  local parches programadas copias seguridad recursos versiones

  echo "recolectando…" >&2
  servidor=$(seccion col_servidor)
  servicios=$(seccion col_servicios)
  contenedores=$(seccion col_contenedores)
  aplicaciones=$(seccion col_aplicaciones)
  puertos=$(seccion col_puertos)
  web=$(seccion col_web)
  accesos=$(seccion col_accesos)
  parches=$(seccion col_parches)
  programadas=$(seccion col_programadas)
  copias=$(seccion col_copias)
  seguridad=$(seccion col_seguridad)
  recursos=$(seccion col_recursos)
  versiones=$(seccion col_versiones)

  local informe
  informe=$(jq -n \
    --arg version "$VERSION" \
    --arg generadoEl "$(date -Iseconds)" \
    --argjson completo "$completo" \
    --argjson servidor "$servidor" \
    --argjson servicios "$servicios" \
    --argjson contenedores "$contenedores" \
    --argjson aplicaciones "$aplicaciones" \
    --argjson puertos "$puertos" \
    --argjson web "$web" \
    --argjson accesos "$accesos" \
    --argjson parches "$parches" \
    --argjson programadas "$programadas" \
    --argjson copias "$copias" \
    --argjson seguridad "$seguridad" \
    --argjson recursos "$recursos" \
    --argjson versiones "$versiones" \
    '{agente: {nombre: "sgsi-agente", version: $version,
               generadoEl: $generadoEl, completo: $completo},
      servidor: $servidor, servicios: $servicios, contenedores: $contenedores,
      aplicaciones: $aplicaciones, red: {puertos: $puertos}, web: $web,
      accesos: $accesos, parches: $parches, tareasProgramadas: $programadas,
      copias: $copias, seguridad: $seguridad, recursos: $recursos,
      versiones: $versiones}')

  echo "evaluando…" >&2
  local resumen
  resumen=$(evaluar "$informe")
  [ -n "$resumen" ] || resumen='[]'

  printf '%s' "$informe" | jq --argjson resumen "$resumen" \
    --argjson duracion "$(( SECONDS - inicio ))" \
    '. + {resumen: $resumen} | .agente.duracionSegundos = $duracion'
}

main() {
  hay jq || { echo "ERROR: hace falta jq (apt-get install jq)" >&2; exit 1; }

  case "${1:-}" in
    --version) echo "sgsi-agente $VERSION"; exit 0 ;;
    -h|--ayuda|--help) uso; exit 0 ;;
    --seccion)
      [ -n "${2:-}" ] || { uso; exit 1; }
      case "$2" in
        servidor|servicios|contenedores|aplicaciones|puertos|web|accesos|parches|programadas|copias|seguridad|recursos|versiones)
          seccion "col_$2" | jq .; exit 0 ;;
        *) echo "sección desconocida: $2" >&2; exit 1 ;;
      esac ;;
    --stdout)
      generar_informe | jq .; exit 0 ;;
    --resumen)
      generar_informe | jq -r '
        .resumen[] |
        (if .estado == "pasa" then "✔" elif .estado == "falla" then "✘" else "·" end)
        + " " + .codigo + (" " * (34 - (.codigo | length))) + .estado'
      exit 0 ;;
    "") ;;
    *) uso; exit 1 ;;
  esac

  umask 077
  mkdir -p "$ESTADO_DIR"
  local destino="$ESTADO_DIR/informe.json" temporal
  temporal=$(mktemp "$ESTADO_DIR/.informe.XXXXXX")

  if ! generar_informe > "$temporal"; then
    rm -f "$temporal"
    echo "ERROR: no se pudo generar el informe" >&2
    exit 1
  fi
  [ -f "$destino" ] && mv -f "$destino" "$ESTADO_DIR/informe-anterior.json"
  mv -f "$temporal" "$destino"
  echo "informe en $destino" >&2

  enviar "$destino"

  # Resumen a stderr: si se lanza a mano, se ve el estado de un vistazo.
  jq -r '.resumen[] | select(.estado == "falla") | "  ✘ " + .codigo' "$destino" >&2 || true
}

main "$@"
