#!/usr/bin/env bash
#
# Konekt Sales - actualizar a la ultima version
#
#   cd /opt/konekt-sales && sudo ./deploy/actualizar.sh
#
# Trae los cambios, reinstala dependencias si hicieron falta y reinicia.
# Si algo sale mal, regresa a la version anterior automaticamente.

set -euo pipefail

USUARIO="konekt"
DESTINO="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"

verde()  { printf '\033[0;32m%s\033[0m\n' "$*"; }
rojo()   { printf '\033[0;31m%s\033[0m\n' "$*" >&2; }
amaril() { printf '\033[0;33m%s\033[0m\n' "$*"; }

[ "$(id -u)" -eq 0 ] || { rojo "Corre esto con sudo."; exit 1; }
cd "$DESTINO"

ANTERIOR="$(git rev-parse HEAD)"
echo "Version actual: $(git log -1 --format='%h %s')"

echo
echo "Trayendo cambios..."
sudo -u "$USUARIO" git fetch --quiet origin
NUEVO="$(git rev-parse '@{u}')"

if [ "$ANTERIOR" = "$NUEVO" ]; then
  verde "Ya estas en la ultima version. No hay nada que hacer."
  exit 0
fi

sudo -u "$USUARIO" git merge --ff-only '@{u}'
verde "Actualizado a: $(git log -1 --format='%h %s')"

# Solo reinstalar si cambiaron las dependencias: npm ci borra y rehace
# node_modules completo, y en una maquina lenta eso tarda.
if ! git diff --quiet "$ANTERIOR" HEAD -- package-lock.json package.json; then
  echo
  echo "Cambiaron las dependencias, reinstalando..."
  sudo -u "$USUARIO" npm ci --omit=dev --no-audit --no-fund
else
  echo "Las dependencias no cambiaron."
fi

chown -R "$USUARIO:$USUARIO" "$DESTINO"
chmod 600 .env 2>/dev/null || true

echo
echo "Reiniciando el servicio..."
systemctl restart konekt-sales
sleep 3

SALUD="$(curl -s -m 5 http://127.0.0.1:3000/api/health || true)"

if echo "${SALUD:-}" | grep -q '"ok":true'; then
  verde "Listo. El servicio quedo corriendo."
  echo "  $SALUD"
else
  rojo "El servicio no respondio bien despues de actualizar."
  echo "  ${SALUD:-sin respuesta}"
  echo
  amaril "Regresando a la version anterior..."
  sudo -u "$USUARIO" git reset --hard "$ANTERIOR"
  sudo -u "$USUARIO" npm ci --omit=dev --no-audit --no-fund
  systemctl restart konekt-sales
  sleep 3
  if systemctl is-active --quiet konekt-sales; then
    amaril "Se restauro la version anterior y el servicio esta arriba."
  else
    rojo "El servicio sigue caido. Revisa:  journalctl -u konekt-sales -n 50"
  fi
  echo
  rojo "La actualizacion fallo. Revisa los logs antes de reintentar."
  exit 1
fi
