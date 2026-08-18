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
3. **Unidireccional.** El agente empuja; el backend jamás le ordena nada. No
   hay canal de vuelta, ni ejecución remota, ni túnel. Ante un auditor (y
   ante un atacante) esto importa: comprometer el SGSI no da acceso a los
   servidores.
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
| `web` | Dominios servidos (nginx/apache) y certificados TLS con días restantes |
| `accesos` | Usuarios con shell, sudo, último acceso, y **huellas de todas las authorized_keys** |
| `parches` | Actualizaciones de seguridad pendientes, unattended-upgrades, reinicio pendiente, paquetes instalados a mano |
| `tareasProgramadas` | Cron (sistema y usuarios, saneado) y timers de systemd |
| `copias` | Herramientas de backup presentes, tareas que suenan a copia, frescura del directorio vigilado |
| `seguridad` | ufw/nftables, reglas `DOCKER-USER`, configuración efectiva del sshd, fail2ban, NTP, registros |
| `recursos` | Discos, inodos, memoria, carga |
| `versiones` | Versiones de node, python, php, nginx, docker, git, openssl, psql |

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
sudo ./instalar.sh
```

El instalador deja el agente en `/usr/local/sbin/sgsi-agente` (root, 0700),
la configuración en `/etc/sgsi-agente/config` (0600) y un timer de systemd
que lo ejecuta cada 6 horas. `sudo ./desinstalar.sh` lo retira conservando
config e informes.

### Uso a mano

```bash
sudo sgsi-agente --resumen        # tabla de comprobaciones, de un vistazo
sudo sgsi-agente --stdout | less  # informe completo
sudo sgsi-agente --seccion aplicaciones   # una sección concreta
```

Sin root funciona, pero el informe queda incompleto (claves SSH, procesos de
otros usuarios, `sshd -T`) y lo dice.

## Envío al SGSI

Con `SGSI_URL` y `SGSI_TOKEN` en la config, cada pasada hace
`POST $SGSI_URL/api/agentes/informe` con `Authorization: Bearer` y el JSON
como cuerpo. Si el envío falla, el informe queda en disco y se reintenta en
la siguiente pasada; el propio silencio es señal: el backend debe abrir
hallazgo cuando un servidor lleve más de dos periodos sin reportar
(`agente-latido`), porque un agente muerto no puede parecer un servidor sano.

El token es **por servidor**, se genera al enrolarlo y solo sirve para
entregar informes: robarlo no da acceso a nada del SGSI.

## Hoja de ruta (lado sgsi-lyn)

1. Migración: tablas `agentes` (id, nombre, hash del token, último informe)
   e ingesta del informe.
2. Endpoint `POST /api/agentes/informe` autenticado por token de agente.
3. Proveedor `agente` con su conector: `descubrir()` lee los informes
   (servidor + aplicaciones como recursos externos, mapeables a activos),
   `comprobar()` evalúa con las definiciones `srv-*` de `comprobaciones.ts`,
   con severidad, requisitos y remediación paso a paso como el resto.
4. Enrolado desde la pantalla de integraciones: alta del servidor → token →
   pegar en `/etc/sgsi-agente/config`.
5. `agente-latido`: hallazgo automático si un servidor deja de reportar.
