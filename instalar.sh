#!/usr/bin/env bash
# Instala el agente SGSI en este servidor: binario, config y timer de systemd.
# Ejecutar como root desde el directorio del repositorio clonado.
set -euo pipefail

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

# URL base del backend del SGSI (sin barra final) y token de ESTE servidor.
# El token se genera al enrolar el servidor en la pantalla de integraciones.
#SGSI_URL="https://sgsi.lynsoluciones.es"
#SGSI_TOKEN=""

# Dónde deja sus ficheros el mecanismo de copias, para vigilar su frescura.
#BACKUP_RUTA="/var/backups"

# Puertos que DEBEN estar expuestos a internet (línea base), separados por
# comas. Si se define, cualquier otro puerto expuesto hace fallar srv-puertos.
#PUERTOS_ESPERADOS="22,80,443"
FIN
  chmod 0600 /etc/sgsi-agente/config
fi

echo "· instalando unidades de systemd"
install -m 0644 systemd/sgsi-agente.service systemd/sgsi-agente.timer /etc/systemd/system/
systemctl daemon-reload
systemctl enable --now sgsi-agente.timer

echo "· primera pasada (puede tardar unos segundos)…"
/usr/local/sbin/sgsi-agente --resumen || true

echo
echo "Listo. El agente correrá cada 6 horas (systemctl list-timers sgsi-agente.timer)."
echo "Informe: /var/lib/sgsi-agente/informe.json · A mano: sgsi-agente --resumen"
