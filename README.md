# sgsi-agente

Agente de descubrimiento y comprobación para los servidores de LYN. Corre
**dentro** del servidor —donde las APIs de los proveedores no llegan— y
genera un informe JSON con todo lo que el SGSI necesita saber de la máquina:
qué servicios hay, en qué estado están, de qué repositorio vienen, y cómo de
bien están las medidas de seguridad básicas.

Nació porque IONOS no ofrece API de servidores: su API pública solo cubre
dominios y DNS, así que el VPS más crítico del inventario era invisible para
el SGSI. El agente le da la vuelta al problema: en vez de preguntarle al
proveedor, se mira desde dentro. El mismo agente vale para cualquier servidor
Linux (IONOS, DigitalOcean, o el que venga).

## Reglas de diseño

1. **Solo lectura.** No cambia nada del sistema; lo único que escribe es su
   propio informe en `/var/lib/sgsi-agente`.
2. **Mide, no juzga.** El informe son hechos crudos. Los criterios de qué
   está bien o mal viven en el backend del SGSI (`comprobaciones.ts`) y se
   revisan por pull request. El `resumen` local es una evaluación de cortesía
   para poder usar el agente suelto, no la fuente de verdad.
3. **Los datos solo suben.** El agente empuja; no hay ejecución remota ni
   túnel. Lo único que baja por el sondeo son dos banderas sin parámetros
   («genera tu informe ya», «actualízate desde tu git») que el propio agente
   ejecuta con su propio código. Ante un auditor (y ante un atacante) esto
   importa: comprometer el SGSI no da acceso a los servidores; como mucho,
   les hace medirse antes de hora.
4. **Sin secretos** (regla 7 del SGSI). Huellas de claves SSH, nunca claves;
   nombres y permisos de ficheros `.env`, nunca contenidos; URLs de git con
   las credenciales tachadas; líneas de cron saneadas.
5. **Tolerante.** Cada colector que falla deja `null` en su sección; un
   servidor raro nunca tumba el informe entero.

## Qué descubre

| Sección | Contenido |
|---|---|
| `servidor` | Hostname, distro, kernel, virtualización, IPs, CPU/RAM, arranque |
| `servicios` | Unidades systemd con su estado; marca cuáles son «propias» (instaladas a mano en `/etc/systemd/system`, primeras candidatas a activo) |
| `contenedores` | Docker: imagen, estado, salud, reinicios, **proyecto/servicio/directorio de docker compose**, puertos publicados, si expone a internet, y **repositorio de origen aunque no haya checkout en disco** (etiqueta OCI `org.opencontainers.image.source` o inferido de `ghcr.io/<org>/<repo>`) |
| `aplicaciones` | Directorios de despliegue detectados (compose, cwd de procesos vivos, `/var/www`, `/srv`, `/opt`, `/home/*`) con **repositorio git de origen, rama, commit y fecha** |
| `red.puertos` | Todo lo que escucha: protocolo, puerto, dirección de escucha, proceso, y si está expuesto |
| `web` | Dominios servidos (nginx/apache/**caddy**), **sitios del proxy inverso** (por cada sitio de caddy: dominios, upstreams de `reverse_proxy` y raíces de ficheros, leídos de su admin API en JSON) y certificados TLS con días restantes (incluidos los que gestiona caddy) |
| `accesos` | Usuarios con shell, sudo, último acceso, y **huellas de todas las authorized_keys** |
| `parches` | Actualizaciones de seguridad pendientes, unattended-upgrades, reinicio pendiente, paquetes instalados a mano |
| `tareasProgramadas` | Cron (sistema y usuarios, saneado) y timers de systemd |
| `copias` | Herramientas de backup presentes, tareas que suenan a copia, frescura del directorio vigilado |
| `seguridad` | ufw/nftables, reglas `DOCKER-USER`, configuración efectiva del sshd, fail2ban, NTP, registros |
| `recursos` | Discos, inodos, memoria, carga |
| `versiones` | Versiones de node, python, php, nginx, docker, git, openssl, psql |

### Las webs detrás del proxy inverso

Con caddy presente, el informe además dice qué **dominios** sirve el servidor
y hacia dónde manda cada uno (`web.sitios`). El backend cruza el puerto del
upstream con los puertos publicados de los contenedores y cuelga cada dominio
de su servicio: «examenes.lyn.es lo sirve el servicio examenes». Un sitio
cuyo upstream no casa con ningún servicio (una web estática, un destino
remoto) se inventaría como recurso `sitio` propio. Y como varios servicios
pueden compartir repositorio (app, worker, mcp del mismo proyecto), la
reconciliación del SGSI los empareja **deterministamente** con el activo cuya
URL coincide con ese repositorio, sin pasar por la IA.

### El mapeo a activos y repositorios

La sección `aplicaciones` existe para una cosa: que cada servicio del
servidor se pueda mapear a un activo del inventario del SGSI y a su
repositorio en GitHub. Por cada aplicación desplegada el informe dice
*dónde está* (`ruta`), *de dónde viene* (`repositorio`, ya saneado), *qué
versión corre* (`rama`, `commit`, `fechaCommit`) y, cruzando con
`contenedores`, qué contenedores le pertenecen (`proyectoCompose` /
`directorioCompose`). Con eso, la pantalla de integraciones del SGSI puede
ofrecer el mismo flujo que ya usa con GitHub: recurso descubierto → persona
decide → activo inventariado.

Cuando el servicio corre solo como contenedor (imagen del registro, sin
checkout en disco), el repositorio sale de la etiqueta OCI
`org.opencontainers.image.source` de la imagen, o se infiere si viene de
`ghcr.io/<org>/<repo>`. Si tampoco así aparece, el recurso queda inventariado
igualmente (por proyecto/servicio de compose) y el mapeo se hace a mano en la
app — y la corrección de fondo es añadir las etiquetas OCI en los builds de
`lyn-actions`, para que toda imagen futura declare de qué repo viene.

## Comprobaciones del resumen local

18 comprobaciones, pensadas para mapear al catálogo verificado del SGSI
cuando exista el conector (`requisitos` de ISO 27001:2022 entre paréntesis):

| Código | Qué comprueba | Requisitos |
|---|---|---|
| `srv-cortafuegos` | ufw activo con deny por defecto, o nftables con policy drop | A.8.20, A.8.21, A.8.22 |
| `srv-docker-expuesto` | Contenedores publicando en 0.0.0.0 sin reglas en `DOCKER-USER` (docker **puentea** ufw) | A.8.20, A.8.22 |
| `srv-ssh-contrasena` | `PasswordAuthentication no` efectivo | A.5.17, A.8.5 |
| `srv-ssh-root` | `PermitRootLogin` no/prohibit-password | A.5.15, A.8.2 |
| `srv-fuerza-bruta` | fail2ban activo (con baneados e intentos de las últimas 24 h) | A.8.5, A.8.16 |
| `srv-parches` | Cero actualizaciones de seguridad pendientes | A.8.8 |
| `srv-reinicio-pendiente` | Sin reinicio pendiente por kernel/librerías | A.8.8 |
| `srv-actualizaciones-automaticas` | unattended-upgrades activo | A.8.8 |
| `srv-reloj` | NTP sincronizado | A.8.17 |
| `srv-registros` | journald persistente o rsyslog activo | A.8.15 |
| `srv-disco` | Ningún sistema de ficheros por encima del 85 % | A.8.6 |
| `srv-certificados` | Ningún certificado TLS a menos de 30 días | A.8.24 |
| `srv-bd-expuesta` | Ningún puerto de BD (5432, 3306, 6379, 27017, 9200, 11211, 5672) expuesto | A.8.20, A.8.22 |
| `srv-env-legibles` | Ningún `.env` legible por cualquier usuario | A.8.12, A.5.17 |
| `srv-copias` | Hay mecanismo de copias con indicios de ejecutarse | A.8.13 |
| `srv-puertos` | Puertos expuestos coinciden con la línea base declarada | A.8.20, A.8.9 |
| `srv-servicios-caidos` | Ninguna unidad systemd en `failed` | A.8.16, A.8.14 |
| `srv-contenedores` | Ningún contenedor `restarting`/`unhealthy` | A.8.16 |

## Instalación

```bash
git clone https://github.com/LYN-Soluciones-Tecnologicas/sgsi-agente.git
cd sgsi-agente
sudo ./instalar.sh https://sgsi.lynsoluciones.es
```

El instalador deja el agente en `/usr/local/sbin/sgsi-agente` (root, 0700),
la configuración en `/etc/sgsi-agente/config` (0600) y un timer de systemd
que lo ejecuta cada 6 horas. Con la URL como argumento, además **pide el
enrolado**: imprime un código de verificación y espera a que alguien acepte
la invitación en la web del SGSI (ver «Enrolado por invitación»). Sin URL,
instala igual y el enrolado se hace después con `sudo sgsi-agente --enrolar
https://…`. `sudo ./desinstalar.sh` lo retira conservando config e informes.

### Uso a mano

```bash
sudo sgsi-agente --resumen        # tabla de comprobaciones, de un vistazo
sudo sgsi-agente --stdout | less  # informe completo
sudo sgsi-agente --seccion aplicaciones   # una sección concreta
```

Sin root funciona, pero el informe queda incompleto (claves SSH, procesos de
otros usuarios, `sshd -T`) y lo dice.

## Enrolado por invitación

La vía normal de conectar el agente al SGSI. En el servidor solo se define
**la URL de la web** (config o `--enrolar URL`); el token no se copia a mano
en ninguna dirección:

1. El agente hace `POST /api/agentes/invitaciones {nombre: hostname}` y
   recibe un **código de sondeo** secreto (`sgi_…`, solo lo conoce este
   servidor) más un **código de verificación** corto que imprime en consola.
2. La invitación aparece en la web del SGSI (Integraciones → Agentes) con el
   mismo código de verificación. Una persona lo coteja con la consola del
   servidor y **acepta o rechaza**: eso es lo que impide que un impostor que
   conozca el hostname cuele su propia máquina.
3. El agente sondea `POST /api/agentes/invitaciones/canje {codigo}` —en
   primer plano si se lanzó `--enrolar`, o una vez por pasada del timer— y,
   cuando la invitación está aceptada, el token nace **en ese momento** y
   viaja una única vez: queda en `/var/lib/sgsi-agente/token` (0600) y en el
   backend solo vive su hash. Un segundo canje del mismo código ya solo ve
   «consumida».

Las invitaciones caducan a las 24 horas; una rechazada deja al agente en
silencio (no insiste) hasta que alguien vuelva a lanzar `--enrolar`. La vía
antigua sigue existiendo: generar el token en la web y pegarlo como
`SGSI_TOKEN` en la config, que manda sobre el fichero de token.

## Sondeo: «escanear ahora» y «actualizar agente» desde la web

El servicio `sgsi-agente-sondeo` (systemd, `Restart=always`) pregunta al SGSI
cada **5 segundos** si hay solicitudes pendientes, con el mismo token de
entrega. La respuesta son dos banderas sin parámetros, entregadas una sola
vez:

- **escanear** — el agente genera y envía un informe completo al momento, sin
  esperar al timer de 6 horas. Es lo que hay detrás del botón «Escanear
  ahora» de cada servidor en la pantalla de integraciones.
- **actualizar** — el agente clona su repositorio (somero, rama por defecto),
  compara el commit remoto con el instalado (`/var/lib/sgsi-agente/
  version-instalada`, lo escribe `instalar.sh`) y, si difieren, reinstala
  conservando config, token e informes; después envía un informe con la
  versión nueva y el sondeo se re-ejecuta para soltar el código viejo. Botón
  «Actualizar agente».

El mismo bucle empuja el enrolado cuando aún no hay token: la invitación se
canjea en segundos en cuanto alguien la acepta. La pantalla enseña si el
sondeo está **en línea** (último latido hace segundos); si no lo está, las
solicitudes quedan en cola hasta que vuelva. La cadencia la decide el
backend (viaja en cada respuesta) y se puede fijar con `SONDEO_SEGUNDOS` en
la config; el repositorio de actualización, con `REPO_URL`.

## Actualizar a mano un agente antiguo

Un agente anterior al sondeo no puede actualizarse desde la web (no hay
nadie escuchando). En el servidor:

```bash
cd sgsi-agente        # el checkout desde el que se instaló…
git pull              # …o clona de nuevo si ya no está
sudo ./instalar.sh
```

La instalación conserva config, token e informes, apunta el commit instalado
y deja en marcha el servicio de sondeo: a partir de ahí las siguientes
actualizaciones ya se piden desde la pantalla. `sudo sgsi-agente
--actualizar` hace lo mismo sin checkout previo (clona él solo), y sirve
también para comprobar si hay versión nueva: dice «ya está en la última
versión» y no toca nada.

## Envío al SGSI

Con la URL configurada y el token obtenido, cada pasada hace
`POST $SGSI_URL/api/agentes/informe` con `Authorization: Bearer` y el JSON
como cuerpo. Si el envío falla, el informe queda en disco y se reintenta en
la siguiente pasada; el propio silencio es señal: el backend debe abrir
hallazgo cuando un servidor lleve más de dos periodos sin reportar
(`agente-latido`), porque un agente muerto no puede parecer un servidor sano.

El token es **por servidor** y solo sirve para entregar informes: robarlo no
da acceso a nada del SGSI.

## El lado sgsi-lyn (hecho)

El backend del SGSI ya tiene la contrapartida completa:

- Tabla `agente_servidor` (nombre, hash del token, último informe con fecha)
  y endpoint público `POST /api/agentes/informe` autenticado por token.
- Enrolado por invitación (tabla `agente_invitacion`, endpoints públicos de
  alta y canje, y la pantalla de integraciones donde una persona acepta o
  rechaza cotejando el código de verificación). El alta manual por API sigue:
  `POST /api/agentes {nombre}` devuelve el token **una única vez**;
  `POST /api/agentes/:id/token` lo rota.
- Proveedor `agente` con su conector: `descubrir()` inventaría el servidor
  como activo y cada **servicio** como recurso externo mapeable (fundiendo
  proyectos compose, contenedores sueltos, directorios con repo y unidades
  systemd propias); `comprobar()` re-evalúa el informe crudo con las
  definiciones `srv-*` de `comprobaciones.ts` (el agente mide, el backend
  juzga; la única excepción es `srv-puertos`, cuya línea base vive en el
  servidor).
- **Reconciliación con el inventario**: en la pantalla de integraciones, el
  panel «Recursos» de cada integración enseña lo descubierto y su vínculo
  con los activos. «Reconciliar con IA» pide al modelo que proponga, por
  cada recurso sin activo, si ES un activo que ya existe (vincular) o si
  merece alta propia (crear); la propuesta queda pendiente y **la firma una
  persona** —regla 3—, que también puede vincular a mano sin modelo.
- **Sondeo de solicitudes**: `POST /api/agentes/sondeo` (token del agente)
  entrega las banderas pendientes una sola vez y registra el latido;
  `POST /api/agentes/:id/escaneo` y `POST /api/agentes/:id/actualizacion`
  son los botones «Escanear ahora» y «Actualizar agente» de la pantalla, que
  además enseña si el sondeo está en línea y la versión del agente.
- `agente-latido`: hallazgo automático si un servidor calla más de 24 horas
  o se enroló y nunca reportó.
- La pestaña de hallazgos filtra por **fuente**: cada proveedor (github,
  dns, agente…) y, dentro de `agente`, cada servidor por separado.

Pendiente: etiquetas OCI en los builds de `lyn-actions` para que toda imagen
declare su repositorio de origen.
