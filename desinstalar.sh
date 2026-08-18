#!/usr/bin/env bash
# Retira el agente SGSI del servidor. No borra la config ni los informes
# (llevan estado del SGSI); se avisa de dónde quedan.
set -euo pipefail

[ "$(id -u)" = 0 ] || { echo "Ejecuta la desinstalación como root."; exit 1; }

systemctl disable --now sgsi-agente.timer 2>/dev/null || true
rm -f /etc/systemd/system/sgsi-agente.service /etc/systemd/system/sgsi-agente.timer
systemctl daemon-reload
rm -f /usr/local/sbin/sgsi-agente

echo "Agente retirado. Config e informes conservados en:"
echo "  /etc/sgsi-agente  ·  /var/lib/sgsi-agente"
echo "Bórralos a mano si ya no hacen falta."
