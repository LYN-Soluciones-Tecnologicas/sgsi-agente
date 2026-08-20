#!/usr/bin/env bash
# Instala el agente SGSI en este servidor: binario, config y timer de systemd.
# Ejecutar como root desde el directorio del repositorio clonado.
#
#   sudo ./instalar.sh                          # instala; enrolar después
#   sudo ./instalar.sh https://sgsi.ejemplo.es  # instala Y pide el enrolado:
#                                               # acepta la invitación en la web
#                                               # y el token llega solo.
set -euo pipefail

URL_SGSI="${1:-}"

[ "$(id -u)" = 0 ] || { echo "Ejecuta la instalación como root."; exit 1; }
[ -f agente.sh ] || { echo "Ejecuta desde el directorio del repositorio (falta agente.sh)."; exit 1; }

if ! command -v jq >/dev/null 2>&1; then
  echo "· instalando jq…"
  apt-get update -qq && apt-get install -y -qq jq
fi

echo "· copiando el agente a /usr/local/sbin/sgsi-agente"
install -m 0700 -o root -g root agente.sh /usr/local/sbin/sgsi-agente

install -d -m 0750 /etc/sgsi-agente
install -d -m 0700 /var/lib/sgsi-agente

if [ ! -f /etc/sgsi-agente/config ]; then
  echo "· creando /etc/sgsi-agente/config (edítalo para activar el envío)"
  cat > /etc/sgsi-agente/config <<'FIN'
# Configuración del agente SGSI. Todo es opcional: sin nada de esto, el
# informe queda en /var/lib/sgsi-agente/informe.json y no se envía.

# URL base del backend del SGSI (sin barra final). Con solo esto, el agente
# pide una invitación de enrolado y, cuando alguien la acepta en la web, el
# token llega solo y queda en /var/lib/sgsi-agente/token. `sgsi-agente
# --enrolar URL` hace lo mismo esperando en primer plano.
#SGSI_URL="https://sgsi.lynsoluciones.es"

# Vía antigua: pegar aquí a mano un token generado en la web. Si está, manda
# sobre el token recibido por invitación.
#SGSI_TOKEN=""

# Dónde deja sus ficheros el mecanismo de copias, para vigilar su frescura.
#BACKUP_RUTA="/var/backups"

# Puertos que DEBEN estar expuestos a internet (línea base), separados por
# comas. Si se define, cualquier otro puerto expuesto hace fallar srv-puertos.
#PUERTOS_ESPERADOS="22,80,443"

# Cadencia del sondeo de solicitudes en segundos (el backend puede ajustarla
# en caliente) y repositorio del que se actualiza el agente.
#SONDEO_SEGUNDOS=5
#REPO_URL="https://github.com/LYN-Soluciones-Tecnologicas/sgsi-agente.git"
FIN
  chmod 0600 /etc/sgsi-agente/config
fi

# La URL entra en la config ANTES de arrancar el sondeo: así el servicio nace
# ya apuntando al SGSI y empuja el enrolado desde el primer latido.
if [ -n "$URL_SGSI" ]; then
  echo "· configurando SGSI_URL=$URL_SGSI"
  if grep -q '^SGSI_URL=' /etc/sgsi-agente/config; then
    sed -i "s|^SGSI_URL=.*|SGSI_URL=\"$URL_SGSI\"|" /etc/sgsi-agente/config
  elif grep -q '^#SGSI_URL=' /etc/sgsi-agente/config; then
    sed -i "s|^#SGSI_URL=.*|SGSI_URL=\"$URL_SGSI\"|" /etc/sgsi-agente/config
  else
    printf 'SGSI_URL="%s"\n' "$URL_SGSI" >> /etc/sgsi-agente/config
  fi
fi

echo "· instalando unidades de systemd"
install -m 0644 systemd/sgsi-agente.service systemd/sgsi-agente.timer \
  systemd/sgsi-agente-sondeo.service /etc/systemd/system/
systemctl daemon-reload
systemctl enable --now sgsi-agente.timer

# El sondeo atiende «escanear ahora» y «actualizar agente» desde la web.
systemctl enable sgsi-agente-sondeo.service >/dev/null 2>&1 || true
if [ -n "${INVOCATION_ID:-}" ]; then
  # Nos está ejecutando el propio servicio de sondeo (--actualizar): no se
  # reinicia a sí mismo; al terminar hará exec de la versión recién instalada.
  :
elif systemctl is-active --quiet sgsi-agente-sondeo.service; then
  echo "· reiniciando el sondeo con la versión nueva"
  systemctl restart sgsi-agente-sondeo.service
else
  systemctl start sgsi-agente-sondeo.service || true
fi

# Commit instalado: es la referencia contra la que --actualizar compara.
if COMMIT=$(git rev-parse HEAD 2>/dev/null); then
  install -d -m 0700 /var/lib/sgsi-agente
  printf '%s\n' "$COMMIT" > /var/lib/sgsi-agente/version-instalada
  echo "· versión instalada: $(git rev-parse --short HEAD 2>/dev/null)"
fi

echo "· primera pasada (puede tardar unos segundos)…"
/usr/local/sbin/sgsi-agente --resumen || true

echo
echo "Listo. El agente correrá cada 6 horas (systemctl list-timers sgsi-agente.timer)."
echo "Informe: /var/lib/sgsi-agente/informe.json · A mano: sgsi-agente --resumen"

if [ -n "$URL_SGSI" ]; then
  echo
  echo "· pidiendo el enrolado a $URL_SGSI…"
  /usr/local/sbin/sgsi-agente --enrolar "$URL_SGSI" || true
else
  echo "Para conectarlo al SGSI: sudo sgsi-agente --enrolar https://sgsi.ejemplo.es"
fi
