#!/usr/bin/env bash
#
# Konekt Sales - instalacion en un servidor Debian/Ubuntu
# ---------------------------------------------------------------
#   sudo git clone https://github.com/Konekt-ai/Konekt-sales.git /opt/konekt-sales
#   cd /opt/konekt-sales
#   sudo ./install.sh
#
# Se puede volver a correr las veces que quieras: no pisa el .env que ya
# exista y no duplica nada.

set -euo pipefail

DESTINO="/opt/konekt-sales"
USUARIO="konekt"
NODE_MAYOR="22"

verde()  { printf '\033[0;32m%s\033[0m\n' "$*"; }
azul()   { printf '\033[0;34m%s\033[0m\n' "$*"; }
rojo()   { printf '\033[0;31m%s\033[0m\n' "$*" >&2; }
amaril() { printf '\033[0;33m%s\033[0m\n' "$*"; }
paso()   { echo; azul "== $* =="; }
morir()  { rojo "ERROR: $*"; exit 1; }

# ---------------------------------------------------------------
paso "Revisando el sistema"

[ "$(id -u)" -eq 0 ] || morir "Corre esto con sudo:  sudo ./install.sh"

command -v apt-get >/dev/null || morir "Este script es para Debian o Ubuntu. Para otra distro, sigue DEPLOY.md a mano."
command -v systemctl >/dev/null || morir "No se encontro systemd."

. /etc/os-release 2>/dev/null || true
verde "Sistema: ${PRETTY_NAME:-desconocido}"

RAM_MB=$(awk '/MemTotal/ {print int($2/1024)}' /proc/meminfo)
verde "RAM disponible: ${RAM_MB} MB"
if [ "$RAM_MB" -lt 700 ]; then
  amaril "Aviso: con menos de 700 MB esto va a ir muy justo."
fi

# ---------------------------------------------------------------
paso "Colocando los archivos en $DESTINO"

ORIGEN="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
if [ "$ORIGEN" != "$DESTINO" ]; then
  amaril "El proyecto esta en $ORIGEN, no en $DESTINO."
  read -r -p "Lo copio a $DESTINO? Las actualizaciones se haran ahi. [S/n] " R
  if [[ ! "${R:-S}" =~ ^[Nn] ]]; then
    mkdir -p "$DESTINO"
    # Se excluye node_modules: puede venir compilado para otra arquitectura.
    if command -v rsync >/dev/null; then
      rsync -a --exclude node_modules --exclude .env "$ORIGEN"/ "$DESTINO"/
    else
      cp -r "$ORIGEN"/. "$DESTINO"/
      rm -rf "$DESTINO/node_modules"
    fi
    verde "Copiado."
  else
    DESTINO="$ORIGEN"
    amaril "Se instalara en $DESTINO."
  fi
fi
cd "$DESTINO"

if [ ! -f server.js ] || [ ! -f package.json ]; then
  morir "No encuentro server.js ni package.json en $DESTINO."
fi

# ---------------------------------------------------------------
paso "Instalando dependencias del sistema"

export DEBIAN_FRONTEND=noninteractive
apt-get update -qq
apt-get install -y -qq curl ca-certificates git rsync >/dev/null
verde "Herramientas basicas listas."

NODE_OK=0
if command -v node >/dev/null; then
  MAYOR="$(node -p 'process.versions.node.split(".")[0]')"
  if [ "$MAYOR" -ge 18 ]; then
    NODE_OK=1
    verde "Node ya instalado: $(node -v)"
  fi
fi
if [ "$NODE_OK" -eq 0 ]; then
  echo "Instalando Node ${NODE_MAYOR}..."
  curl -fsSL "https://deb.nodesource.com/setup_${NODE_MAYOR}.x" | bash - >/dev/null 2>&1
  apt-get install -y -qq nodejs >/dev/null
  verde "Node instalado: $(node -v)"
fi

for P in nginx certbot python3-certbot-nginx ufw; do
  dpkg -s "$P" >/dev/null 2>&1 || apt-get install -y -qq "$P" >/dev/null
done
verde "nginx, certbot y ufw listos."

# ---------------------------------------------------------------
paso "Creando el usuario del servicio"

if id "$USUARIO" >/dev/null 2>&1; then
  verde "El usuario '$USUARIO' ya existe."
else
  useradd --system --home "$DESTINO" --shell /usr/sbin/nologin "$USUARIO"
  verde "Usuario '$USUARIO' creado: sin shell y sin privilegios."
fi

# ---------------------------------------------------------------
paso "Configuracion (.env)"

if [ -f .env ]; then
  verde "Ya existe un .env. No lo toco."
else
  cp .env.example .env
  echo "Necesito tres datos. Los puedes pegar ahora o dejarlos vacios y editarlos despues."
  echo
  read -r -p "  SUPABASE_URL      : " V_URL
  read -r -p "  SUPABASE_ANON_KEY : " V_ANON
  read -r -p "  ANTHROPIC_API_KEY : " V_ANT

  # El separador de sed es | para no chocar con las diagonales de las URLs.
  [ -n "${V_URL:-}" ]  && sed -i "s|^SUPABASE_URL=.*|SUPABASE_URL=${V_URL}|" .env
  [ -n "${V_ANON:-}" ] && sed -i "s|^SUPABASE_ANON_KEY=.*|SUPABASE_ANON_KEY=${V_ANON}|" .env
  [ -n "${V_ANT:-}" ]  && sed -i "s|^ANTHROPIC_API_KEY=.*|ANTHROPIC_API_KEY=${V_ANT}|" .env

  sed -i 's|^NODE_ENV=.*|NODE_ENV=production|' .env
  sed -i 's|^TRUST_PROXY=.*|TRUST_PROXY=1|' .env
  # 127.0.0.1: el puerto 3000 no queda expuesto, solo nginx lo alcanza.
  sed -i 's|^HOST=.*|HOST=127.0.0.1|' .env
  verde ".env creado."
fi

chown "$USUARIO:$USUARIO" .env
chmod 600 .env

# ---------------------------------------------------------------
paso "Instalando las dependencias de la aplicacion"

chown -R "$USUARIO:$USUARIO" "$DESTINO"
sudo -u "$USUARIO" npm ci --omit=dev --no-audit --no-fund
verde "Dependencias instaladas."

# ---------------------------------------------------------------
paso "Registrando el servicio"

RUTA_NODE="$(command -v node)"
sed -e "s|^WorkingDirectory=.*|WorkingDirectory=${DESTINO}|" \
    -e "s|^EnvironmentFile=.*|EnvironmentFile=${DESTINO}/.env|" \
    -e "s|^ExecStart=.*|ExecStart=${RUTA_NODE} server.js|" \
    -e "s|^User=.*|User=${USUARIO}|" \
    -e "s|^Group=.*|Group=${USUARIO}|" \
    deploy/konekt-sales.service > /etc/systemd/system/konekt-sales.service

systemctl daemon-reload
systemctl enable konekt-sales >/dev/null 2>&1
systemctl restart konekt-sales
sleep 3

if systemctl is-active --quiet konekt-sales; then
  verde "Servicio corriendo."
else
  rojo "El servicio no arranco. Revisa:  journalctl -u konekt-sales -n 40"
  exit 1
fi

# ---------------------------------------------------------------
paso "nginx y HTTPS"

read -r -p "Dominio que va a usar (ej. ventas.konekt.mx), o Enter para saltarlo: " DOMINIO

if [ -n "${DOMINIO:-}" ]; then
  sed "s|ventas\.konekt\.mx|${DOMINIO}|g" deploy/nginx.conf > /etc/nginx/sites-available/konekt-sales
  ln -sf /etc/nginx/sites-available/konekt-sales /etc/nginx/sites-enabled/konekt-sales
  rm -f /etc/nginx/sites-enabled/default

  if nginx -t 2>/dev/null; then
    systemctl reload nginx
    verde "nginx configurado para ${DOMINIO}."
    echo
    amaril "El certificado necesita que ${DOMINIO} YA apunte por DNS a este servidor."
    read -r -p "Pido el certificado ahora con certbot? [s/N] " R
    if [[ "${R:-N}" =~ ^[SsYy] ]]; then
      certbot --nginx -d "$DOMINIO" || amaril "certbot fallo. Reintenta luego: sudo certbot --nginx -d ${DOMINIO}"
    else
      echo "Cuando quieras:  sudo certbot --nginx -d ${DOMINIO}"
    fi
  else
    rojo "La configuracion de nginx tiene un error. Revisa:  nginx -t"
  fi
else
  amaril "nginx sin configurar. La app solo responde en 127.0.0.1:3000."
fi

# ---------------------------------------------------------------
paso "Firewall"

read -r -p "Activo ufw dejando solo SSH y web? [s/N] " R
if [[ "${R:-N}" =~ ^[SsYy] ]]; then
  ufw allow OpenSSH >/dev/null
  ufw allow 'Nginx Full' >/dev/null
  ufw --force enable >/dev/null
  verde "Firewall activo. El puerto 3000 queda cerrado desde fuera, como debe ser."
fi

# ---------------------------------------------------------------
paso "Comprobacion final"

SALUD="$(curl -s -m 5 http://127.0.0.1:3000/api/health || true)"
echo "  ${SALUD:-sin respuesta}"
echo

if echo "${SALUD:-}" | grep -q '"ok":true'; then
  verde "==========================================="
  verde "  Konekt Sales quedo instalado y corriendo."
  verde "==========================================="
else
  amaril "El servicio corre, pero falta configuracion en el .env."
  amaril "Edita ${DESTINO}/.env y luego:  sudo systemctl restart konekt-sales"
fi

echo
echo "  Ver logs:     sudo journalctl -u konekt-sales -f"
echo "  Reiniciar:    sudo systemctl restart konekt-sales"
echo "  Actualizar:   cd ${DESTINO} && sudo ./deploy/actualizar.sh"
echo
echo "  Antes de dar acceso al equipo, corre la prueba de RLS que esta"
echo "  al final de supabase/README.md."
echo
