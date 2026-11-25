#!/usr/bin/env bash
# =============================================================================
# LEXAIR GEO · Instalador offline e idempotente (Ubuntu Server LTS, 8 GB)
# Studio Lexair
#
# Se ejecuta desde un paquete de servidor (ver scripts/build/make_server_bundle.sh):
#   sudo ./scripts/install_lexair_geo.sh --server-name geo.internal
#
# Repetirlo es seguro: conserva secretos, base de datos, certificados y mapas;
# solo aplica lo que falta o ha cambiado. No descarga nada de Internet salvo
# que se indique --online (paquetes del sistema vía apt).
#
# Pasos:
#  1 Comprobaciones previas e integridad del paquete
#  2 Paquetes del sistema (PostgreSQL+PostGIS, Nginx, OpenSSL)
#  3 Usuario de servicio y directorios
#  4 Entorno de ejecución Node.js
#  5 Ajuste de PostgreSQL para 8 GB
#  6 Base de datos y roles
#  7 Despliegue de la versión (releases/ + enlace current)
#  8 Secretos y configuración (/etc/lexair-geo)
#  9 Migraciones de esquema
# 10 CA privada y certificado HTTPS interno
# 11 Paquete cartográfico (MBTiles + manifiesto)
# 12 Catálogo geográfico (direcciones, calles, POI)
# 13 Servicios systemd, Nginx y copia diaria
# 14 Superadministrador inicial y verificación de salud
# =============================================================================
set -Eeuo pipefail
umask 027

BUNDLE="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
SERVER_NAME="geo.internal"
SERVER_IPS=""
ONLINE=0
ADMIN_USER="admin"
SKIP_ADMIN=0
RELOAD_CATALOG=0
PREFIX=/opt/lexair-geo
DATA=/srv/lexair-geo
ETC=/etc/lexair-geo
LOGDIR=/var/log/lexair-geo
DB=lexair_geo
SVC_USER=lexair

usage() {
  sed -n '2,30p' "$0" | sed 's/^# \{0,1\}//'
  cat <<EOF
Opciones:
  --bundle DIR         Paquete de servidor (por defecto: $BUNDLE)
  --server-name NOMBRE Nombre DNS interno (por defecto: geo.internal)
  --server-ip IP[,IP]  IPs para el certificado (por defecto: detectadas)
  --admin-user NOMBRE  Usuario superadministrador inicial (por defecto: admin)
  --skip-admin         No crear superadministrador
  --reload-catalog     Recargar el catálogo geográfico aunque ya exista
  --online             Permitir apt-get desde repositorios (si no hay debs/)
EOF
}

while [[ $# -gt 0 ]]; do
  case "$1" in
    --bundle) BUNDLE="$(cd "$2" && pwd)"; shift 2 ;;
    --server-name) SERVER_NAME="$2"; shift 2 ;;
    --server-ip) SERVER_IPS="$2"; shift 2 ;;
    --admin-user) ADMIN_USER="$2"; shift 2 ;;
    --skip-admin) SKIP_ADMIN=1; shift ;;
    --reload-catalog) RELOAD_CATALOG=1; shift ;;
    --online) ONLINE=1; shift ;;
    -h|--help) usage; exit 0 ;;
    *) echo "Opción desconocida: $1" >&2; usage; exit 2 ;;
  esac
done

[[ $EUID -eq 0 ]] || { echo "Ejecute como root (sudo)." >&2; exit 1; }
[[ "$SERVER_NAME" =~ ^[a-zA-Z0-9]([a-zA-Z0-9.-]{0,251}[a-zA-Z0-9])?$ ]] || { echo "--server-name no válido" >&2; exit 2; }
[[ "$ADMIN_USER" =~ ^[a-z][a-z0-9._-]{2,31}$ ]] || { echo "--admin-user no válido" >&2; exit 2; }

mkdir -p "$LOGDIR"
LOG="$LOGDIR/install-$(date +%Y%m%d-%H%M%S).log"
exec 3>&1                      # terminal directa: SOLO para la contraseña temporal
exec > >(tee -a "$LOG") 2>&1
trap 'echo "ERROR en línea $LINENO (paso $STEP). Registro: $LOG" >&2' ERR

STEP=0
step() { STEP=$1; echo; echo "[$1/14] $2"; }
ok()   { echo "  ✓ $*"; }
warn() { echo "  ! $*"; }
die()  { echo "  ✗ $*" >&2; exit 1; }
psql_su() { sudo -u postgres PGOPTIONS="-c client_min_messages=warning" psql -v ON_ERROR_STOP=1 -qAt "$@"; }
secret() { openssl rand -base64 96 | tr -d '\n/+=' | cut -c1-"${1:-40}"; }  # 96 bytes = 128 car. antes de filtrar

# ---------------------------------------------------------------------------
step 1 "Comprobaciones previas"
. /etc/os-release
if [[ "${ID:-}" == ubuntu && "${VERSION_ID:-}" =~ ^(22\.04|24\.04|26\.04)$ ]]; then
  ok "Sistema: $PRETTY_NAME"
elif [[ "${LEXAIR_ALLOW_UNSUPPORTED_OS:-0}" == 1 ]]; then
  warn "Sistema no soportado oficialmente ($PRETTY_NAME); continuando por LEXAIR_ALLOW_UNSUPPORTED_OS=1"
else
  die "Se requiere Ubuntu Server LTS (22.04/24.04/26.04). Detectado: ${PRETTY_NAME:-desconocido}"
fi
MEM_MB=$(awk '/MemTotal/ {print int($2/1024)}' /proc/meminfo)
(( MEM_MB >= 7000 )) && ok "Memoria: ${MEM_MB} MB" || warn "Memoria ${MEM_MB} MB (< 8 GB recomendados): se ajusta PostgreSQL en proporción"
FREE_GB=$(df -BG --output=avail / | tail -1 | tr -dc 0-9)
(( FREE_GB >= 10 )) || die "Espacio libre insuficiente en / (${FREE_GB} GB < 10 GB)"
ok "Disco libre: ${FREE_GB} GB"
[[ -f "$BUNDLE/VERSION" && -f "$BUNDLE/SHA256SUMS" ]] || die "Paquete incompleto: falta VERSION o SHA256SUMS en $BUNDLE"
VERSION="$(tr -dc 'A-Za-z0-9._+-' < "$BUNDLE/VERSION")"
(cd "$BUNDLE" && sha256sum --quiet -c SHA256SUMS) || die "La suma SHA-256 del paquete no coincide: paquete dañado o modificado"
ok "Paquete $VERSION íntegro"

# ---------------------------------------------------------------------------
step 2 "Paquetes del sistema"
need_pkgs=()
command -v psql >/dev/null || need_pkgs+=(postgresql)
ls /usr/share/postgresql/*/extension/postgis.control >/dev/null 2>&1 || need_pkgs+=(postgis)
[[ -x /usr/sbin/nginx ]] || need_pkgs+=(nginx-light)
command -v openssl >/dev/null || need_pkgs+=(openssl)
if ((${#need_pkgs[@]})); then
  if compgen -G "$BUNDLE/debs/*.deb" >/dev/null; then
    echo "  Instalando desde paquetes locales: ${need_pkgs[*]}"
    DEBIAN_FRONTEND=noninteractive apt-get install -y --no-download "$BUNDLE"/debs/*.deb
  elif (( ONLINE )); then
    DEBIAN_FRONTEND=noninteractive apt-get update
    DEBIAN_FRONTEND=noninteractive apt-get install -y --no-install-recommends "${need_pkgs[@]}" postgresql-contrib
  else
    die "Faltan paquetes (${need_pkgs[*]}) y el paquete no incluye debs/. Use --online o un paquete con debs/."
  fi
fi
PG_VER=$(ls /usr/lib/postgresql | sort -n | tail -1)
PG_PKG_VER=$(ls /usr/share/postgresql/"$PG_VER"/extension/postgis--*.sql 2>/dev/null | head -1 || true)
[[ -n "$PG_PKG_VER" ]] || die "PostGIS no está disponible para PostgreSQL $PG_VER"
ok "PostgreSQL $PG_VER con PostGIS, Nginx $(/usr/sbin/nginx -v 2>&1 | sed 's/.*\///'), $(openssl version | cut -d' ' -f1-2)"

# ---------------------------------------------------------------------------
step 3 "Usuario de servicio y directorios"
id "$SVC_USER" >/dev/null 2>&1 || useradd --system --home-dir "$PREFIX" --shell /usr/sbin/nologin "$SVC_USER"
install -d -m 0755 "$PREFIX" "$PREFIX/releases" "$DATA" "$DATA/maps"
install -d -m 0750 -o root -g "$SVC_USER" "$ETC"
install -d -m 0700 "$ETC/pki/private"
install -d -m 0750 -o postgres -g "$SVC_USER" "$DATA/backups"
install -d -m 0750 -o "$SVC_USER" -g "$SVC_USER" "$LOGDIR"
ok "Usuario $SVC_USER; $PREFIX, $DATA, $ETC"

# ---------------------------------------------------------------------------
step 4 "Entorno Node.js"
NODE_TAR=$(ls "$BUNDLE"/node/node-v*-linux-x64.tar.xz 2>/dev/null | head -1 || true)
[[ -n "$NODE_TAR" ]] || die "El paquete no incluye node/node-v*-linux-x64.tar.xz"
NODE_DIR="$PREFIX/$(basename "$NODE_TAR" .tar.xz)"
if [[ ! -x "$NODE_DIR/bin/node" ]]; then
  tar -xJf "$NODE_TAR" -C "$PREFIX"
  chown -R root:root "$NODE_DIR"; chmod -R go-w "$NODE_DIR"
fi
ln -sfn "$NODE_DIR" "$PREFIX/node"
NODE="$PREFIX/node/bin/node"
ok "Node $("$NODE" --version)"

# ---------------------------------------------------------------------------
step 5 "Ajuste de PostgreSQL"
PG_CONF_DIR=/etc/postgresql/$PG_VER/main/conf.d
install -d "$PG_CONF_DIR"
SB_MB=$(( MEM_MB / 4 )); (( SB_MB > 2048 )) && SB_MB=2048
ECS_MB=$(( MEM_MB * 5 / 8 ))
TMP_CONF=$(mktemp)
sed -e "s/^shared_buffers = .*/shared_buffers = ${SB_MB}MB/" \
    -e "s/^effective_cache_size = .*/effective_cache_size = ${ECS_MB}MB/" \
    "$BUNDLE/infrastructure/postgresql/90-lexair-geo.conf" > "$TMP_CONF"
if ! cmp -s "$TMP_CONF" "$PG_CONF_DIR/90-lexair-geo.conf"; then
  install -m 0644 "$TMP_CONF" "$PG_CONF_DIR/90-lexair-geo.conf"
  systemctl restart "postgresql@$PG_VER-main" 2>/dev/null || systemctl restart postgresql
  ok "Configuración aplicada (shared_buffers ${SB_MB}MB) y PostgreSQL reiniciado"
else
  ok "Configuración sin cambios"
fi
rm -f "$TMP_CONF"
systemctl enable --now postgresql >/dev/null 2>&1 || true
for _ in $(seq 1 30); do sudo -u postgres pg_isready -q && break; sleep 1; done
sudo -u postgres pg_isready -q || die "PostgreSQL no responde"

# ---------------------------------------------------------------------------
step 6 "Base de datos y roles"
SECRETS="$ETC/db-secrets.env"
if [[ -f "$SECRETS" ]]; then
  # shellcheck disable=SC1090
  . "$SECRETS"; ok "Secretos de base de datos existentes conservados"
else
  OWNER_PASSWORD=$(secret 40); API_PASSWORD=$(secret 40)
  ( umask 077; printf 'OWNER_PASSWORD=%s\nAPI_PASSWORD=%s\n' "$OWNER_PASSWORD" "$API_PASSWORD" > "$SECRETS" )
  ok "Secretos generados localmente en $SECRETS (0600)"
fi
psql_su <<SQL
DO \$\$ BEGIN
  IF NOT EXISTS (SELECT 1 FROM pg_roles WHERE rolname = 'lexair_owner') THEN
    CREATE ROLE lexair_owner LOGIN NOSUPERUSER NOCREATEDB NOCREATEROLE; END IF;
  IF NOT EXISTS (SELECT 1 FROM pg_roles WHERE rolname = 'lexair_api') THEN
    CREATE ROLE lexair_api NOLOGIN; END IF;
  IF NOT EXISTS (SELECT 1 FROM pg_roles WHERE rolname = 'lexair_api_login') THEN
    CREATE ROLE lexair_api_login LOGIN NOSUPERUSER NOCREATEDB NOCREATEROLE; END IF;
END \$\$;
SQL
# Contraseñas por stdin (no aparecen en la lista de procesos ni en el registro).
psql_su -v owner="$OWNER_PASSWORD" -v api="$API_PASSWORD" >/dev/null <<'SQL'
ALTER ROLE lexair_owner PASSWORD :'owner';
ALTER ROLE lexair_api_login PASSWORD :'api';
GRANT lexair_api TO lexair_api_login;
SQL
if [[ -z "$(psql_su -c "SELECT 1 FROM pg_database WHERE datname = '$DB'")" ]]; then
  sudo -u postgres createdb -O lexair_owner -E UTF8 -T template0 --locale=C.UTF-8 "$DB"
  ok "Base $DB creada"
else
  ok "Base $DB existente conservada"
fi
psql_su -d "$DB" -c "CREATE EXTENSION IF NOT EXISTS postgis; CREATE EXTENSION IF NOT EXISTS pg_trgm; CREATE EXTENSION IF NOT EXISTS unaccent;
  REVOKE CREATE ON SCHEMA public FROM PUBLIC; GRANT ALL ON SCHEMA public TO lexair_owner;
  REVOKE ALL ON DATABASE $DB FROM PUBLIC; GRANT CONNECT ON DATABASE $DB TO lexair_owner, lexair_api;"
ok "Roles lexair_owner (migraciones) y lexair_api_login (aplicación, privilegios mínimos)"

# ---------------------------------------------------------------------------
step 7 "Despliegue de la versión $VERSION"
REL="$PREFIX/releases/$VERSION"
if [[ ! -f "$REL/.complete" ]] || ! cmp -s "$BUNDLE/SHA256SUMS" "$REL/SHA256SUMS"; then
  rm -rf "$REL.tmp"; install -d "$REL.tmp"
  for d in api tile_service web database scripts infrastructure; do
    [[ -d "$BUNDLE/$d" ]] && cp -a "$BUNDLE/$d" "$REL.tmp/"
  done
  cp "$BUNDLE/VERSION" "$BUNDLE/SHA256SUMS" "$REL.tmp/"
  chown -R root:root "$REL.tmp"; chmod -R u=rwX,go=rX "$REL.tmp"
  rm -rf "$REL"; mv "$REL.tmp" "$REL"; touch "$REL/.complete"
  ok "Copiada en $REL"
else
  ok "Versión ya desplegada"
fi
PREV=""; [[ -L "$PREFIX/current" ]] && PREV=$(readlink -f "$PREFIX/current")
ln -sfn "$REL" "$PREFIX/current.new" && mv -T "$PREFIX/current.new" "$PREFIX/current"
[[ -n "$PREV" && "$PREV" != "$REL" ]] && ok "Versión anterior disponible para retroceso: $PREV"
# Conservar solo las 3 últimas versiones.
ls -1dt "$PREFIX"/releases/*/ 2>/dev/null | tail -n +4 | while read -r old; do
  [[ "$(readlink -f "$old")" != "$REL" ]] && rm -rf "$old" && echo "  · eliminada versión antigua $old"
done

# ---------------------------------------------------------------------------
step 8 "Secretos y configuración"
API_ENV="$ETC/api.env"
if [[ -f "$API_ENV" ]] && grep -q '^JWT_SECRET=.\{32,\}' "$API_ENV"; then
  JWT_SECRET=$(grep '^JWT_SECRET=' "$API_ENV" | cut -d= -f2-)
  ok "JWT_SECRET existente conservado (las sesiones siguen siendo válidas)"
else
  JWT_SECRET=$(secret 64); ok "JWT_SECRET generado"
fi
TMP_ENV=$(mktemp)
cat > "$TMP_ENV" <<EOF
# Generado por install_lexair_geo.sh — NO versionar. 0640 root:$SVC_USER
NODE_ENV=production
HOST=127.0.0.1
PORT=3000
DATABASE_URL=postgres://lexair_api_login:${API_PASSWORD}@127.0.0.1:5432/${DB}
DB_POOL_MAX=16
JWT_SECRET=${JWT_SECRET}
TRUST_PROXY=127.0.0.1
MAP_MANIFEST_PATH=${DATA}/maps/current/manifest.json
TILE_SERVICE_URL=http://127.0.0.1:8081
BACKUP_DIR=${DATA}/backups
MIGRATIONS_DIR=${PREFIX}/current/database/migrations
APP_VERSION=${VERSION}
LOG_LEVEL=info
EOF
install -m 0640 -o root -g "$SVC_USER" "$TMP_ENV" "$API_ENV"; rm -f "$TMP_ENV"
ok "$API_ENV"

# ---------------------------------------------------------------------------
step 9 "Migraciones de esquema"
OWNER_URL="postgres://lexair_owner:${OWNER_PASSWORD}@127.0.0.1:5432/${DB}"
(cd "$PREFIX/current/api" && DATABASE_URL="$OWNER_URL" MIGRATIONS_DIR="$PREFIX/current/database/migrations" \
  "$NODE" dist/cli/migrate.js) | sed 's/^/  /'
# Objetos creados por migraciones anteriores con otro propietario (p. ej. postgres).
psql_su -d "$DB" -c "GRANT USAGE ON SCHEMA identity, directory, geo, catalog, security, audit TO lexair_api;" >/dev/null
ok "Esquema al día"

# ---------------------------------------------------------------------------
step 10 "CA privada y certificado HTTPS"
PKI="$ETC/pki"
if [[ ! -f "$PKI/ca.crt" ]]; then
  openssl genpkey -algorithm EC -pkeyopt ec_paramgen_curve:P-384 -out "$PKI/private/ca.key" 2>/dev/null
  openssl req -x509 -new -key "$PKI/private/ca.key" -sha384 -days 3650 \
    -subj "/O=Studio Lexair/OU=LEXAIR GEO/CN=LEXAIR GEO CA interna" \
    -addext "basicConstraints=critical,CA:TRUE,pathlen:0" -addext "keyUsage=critical,keyCertSign,cRLSign" \
    -out "$PKI/ca.crt"
  chmod 0600 "$PKI/private/ca.key"; chmod 0644 "$PKI/ca.crt"
  ok "CA privada creada (clave en $PKI/private, nunca sale del servidor)"
else
  ok "CA privada existente conservada"
fi
[[ -n "$SERVER_IPS" ]] || SERVER_IPS=$(hostname -I 2>/dev/null | tr ' ' '\n' | grep -E '^[0-9.]+$' | paste -sd, - || true)
SAN="DNS:${SERVER_NAME},DNS:localhost,IP:127.0.0.1"
IFS=',' read -ra ips <<< "$SERVER_IPS"
for ip in "${ips[@]}"; do [[ -n "$ip" && ",$SAN," != *",IP:$ip,"* ]] && SAN+=",IP:$ip"; done
NEED_CERT=1
if [[ -f "$PKI/server.crt" ]] && openssl x509 -in "$PKI/server.crt" -noout -checkend $((30*86400)) >/dev/null \
   && [[ "$(cat "$PKI/server.san" 2>/dev/null)" == "$SAN" ]]; then NEED_CERT=0; fi
if (( NEED_CERT )); then
  openssl genpkey -algorithm EC -pkeyopt ec_paramgen_curve:P-256 -out "$PKI/server.key" 2>/dev/null
  openssl req -new -key "$PKI/server.key" -subj "/O=Studio Lexair/CN=${SERVER_NAME}" -out "$PKI/server.csr"
  printf 'basicConstraints=CA:FALSE\nkeyUsage=critical,digitalSignature,keyEncipherment\nextendedKeyUsage=serverAuth\nsubjectAltName=%s\n' "$SAN" > "$PKI/server.ext"
  openssl x509 -req -in "$PKI/server.csr" -CA "$PKI/ca.crt" -CAkey "$PKI/private/ca.key" -CAcreateserial \
    -days 825 -sha256 -extfile "$PKI/server.ext" -out "$PKI/server.crt" 2>/dev/null
  cat "$PKI/server.crt" "$PKI/ca.crt" > "$PKI/server.fullchain.crt"
  echo "$SAN" > "$PKI/server.san"
  chmod 0600 "$PKI/server.key"; chmod 0644 "$PKI/server.crt" "$PKI/server.fullchain.crt"
  rm -f "$PKI/server.csr"
  ok "Certificado emitido para $SAN (825 días)"
else
  ok "Certificado vigente conservado ($SAN)"
fi
# Publicar solo el certificado público de la CA: Nginx (www-data) no puede ni debe
# leer /etc/lexair-geo, donde están los secretos.
install -d -m 0755 "$PREFIX/ca"
install -m 0644 "$PKI/ca.crt" "$PREFIX/ca/lexair-geo-ca.crt"
chmod 0750 "$PKI"   # solo root (Nginx maestro lee clave y certificado)

# ---------------------------------------------------------------------------
step 11 "Paquete cartográfico"
if [[ -f "$BUNDLE/maps/manifest.json" ]]; then
  MAP_VER=$("$NODE" -e 'const m=JSON.parse(require("fs").readFileSync(process.argv[1]));if(!/^[A-Za-z0-9._-]+$/.test(m.version))process.exit(3);console.log(m.version)' "$BUNDLE/maps/manifest.json")
  "$NODE" -e '
    const fs=require("fs"),path=require("path"),crypto=require("crypto");
    const dir=process.argv[1], m=JSON.parse(fs.readFileSync(path.join(dir,"manifest.json")));
    for (const s of m.styles) {
      if (!/^[a-z0-9_]+\.mbtiles$/.test(s.file)) throw new Error("archivo no válido: "+s.file);
      const h=crypto.createHash("sha256").update(fs.readFileSync(path.join(dir,s.file))).digest("hex");
      if (h!==s.sha256) throw new Error("SHA-256 incorrecto en "+s.file);
    }
    if (m.isSynthetic) console.log("  ! AVISO: paquete SINTÉTICO (no es cartografía real)");
  ' "$BUNDLE/maps"
  if [[ ! -f "$DATA/maps/$MAP_VER/.complete" ]]; then
    rm -rf "$DATA/maps/$MAP_VER.tmp"; install -d "$DATA/maps/$MAP_VER.tmp"
    cp "$BUNDLE"/maps/manifest.json "$BUNDLE"/maps/*.mbtiles "$DATA/maps/$MAP_VER.tmp/"
    chmod 0644 "$DATA/maps/$MAP_VER.tmp"/*
    rm -rf "$DATA/maps/$MAP_VER"; mv "$DATA/maps/$MAP_VER.tmp" "$DATA/maps/$MAP_VER"; touch "$DATA/maps/$MAP_VER/.complete"
  fi
  ln -sfn "$DATA/maps/$MAP_VER" "$DATA/maps/current.new" && mv -T "$DATA/maps/current.new" "$DATA/maps/current"
  ok "Mapas $MAP_VER verificados y activos"
elif [[ -e "$DATA/maps/current/manifest.json" ]]; then
  ok "El paquete no trae mapas; se conservan los actuales ($(readlink -f "$DATA/maps/current"))"
else
  warn "No hay paquete cartográfico: el visor mostrará fondo vacío hasta instalar uno (docs/MAP_DATA.md)"
fi

# ---------------------------------------------------------------------------
step 12 "Catálogo geográfico"
MUNIS=$(psql_su -d "$DB" -c "SELECT count(*) FROM geo.municipalities")
if [[ -f "$BUNDLE/catalog/catalog.json" ]] && { (( MUNIS == 0 )) || (( RELOAD_CATALOG )); }; then
  DATABASE_URL="$OWNER_URL" bash "$PREFIX/current/scripts/maps/load_geo_catalog.sh" "$BUNDLE/catalog" | sed 's/^/  /'
  ok "Catálogo cargado"
elif (( MUNIS > 0 )); then
  ok "Catálogo existente ($MUNIS municipios); use --reload-catalog para recargar"
else
  warn "Sin catálogo geográfico: la búsqueda de direcciones no tendrá resultados"
fi

# ---------------------------------------------------------------------------
step 13 "Servicios systemd, Nginx y copia diaria"
install -m 0644 "$BUNDLE"/infrastructure/systemd/lexair-geo-*.service "$BUNDLE"/infrastructure/systemd/lexair-geo-*.timer /etc/systemd/system/
install -m 0644 "$BUNDLE/infrastructure/nginx/nginx-proxy.conf" "$BUNDLE/infrastructure/nginx/nginx-headers.conf" "$ETC/"
WEB_ROOT="$PREFIX/current/web"
if [[ -d "$WEB_ROOT" ]]; then
  printf '{\n  "serverUrl": "https://%s",\n  "healthPollSeconds": 15\n}\n' "$SERVER_NAME" > "$ETC/web-config.json"
  chmod 0644 "$ETC/web-config.json"
  ln -sfn "$ETC/web-config.json" "$WEB_ROOT/config.json"
fi
sed -e "s#__SERVER_NAME__#${SERVER_NAME}#g" -e "s#__WEB_ROOT__#${WEB_ROOT}#g" \
  "$BUNDLE/infrastructure/nginx/lexair-geo.conf" > /etc/nginx/sites-available/lexair-geo.conf
ln -sfn /etc/nginx/sites-available/lexair-geo.conf /etc/nginx/sites-enabled/lexair-geo.conf
rm -f /etc/nginx/sites-enabled/default
install -d -o www-data -m 0700 /var/cache/nginx/lexair_tiles
/usr/sbin/nginx -t 2>&1 | sed 's/^/  /'
systemctl daemon-reload
systemctl enable lexair-geo-api lexair-geo-tiles nginx lexair-geo-backup.timer >/dev/null 2>&1
systemctl restart lexair-geo-api lexair-geo-tiles
systemctl reload-or-restart nginx
systemctl start lexair-geo-backup.timer
ok "lexair-geo-api, lexair-geo-tiles, nginx y lexair-geo-backup.timer activos"

# ---------------------------------------------------------------------------
step 14 "Superadministrador y verificación"
for _ in $(seq 1 30); do curl -fsS http://127.0.0.1:3000/api/v1/health/live >/dev/null 2>&1 && break; sleep 1; done
USERS=$(psql_su -d "$DB" -c "SELECT count(*) FROM identity.users")
if (( SKIP_ADMIN )); then
  ok "Creación de superadministrador omitida"
elif (( USERS == 0 )); then
  OUT=$(cd "$PREFIX/current/api" && DATABASE_URL="$OWNER_URL" "$NODE" dist/cli/create-admin.js \
        --username "$ADMIN_USER" --display-name "Superadministrador" --role superadmin)
  TEMP=$(printf '%s' "$OUT" | "$NODE" -e 'let s="";process.stdin.on("data",d=>s+=d).on("end",()=>{const j=JSON.parse(s);console.log(j.temporaryPassword??"")})')
  ok "Superadministrador '$ADMIN_USER' creado (deberá cambiar la contraseña al entrar)"
  if [[ -n "$TEMP" ]]; then
    # Solo a la terminal (descriptor 3): no se escribe en el registro.
    printf '\n  ┌─ CONTRASEÑA TEMPORAL (se muestra una sola vez) ─┐\n  │  usuario: %s\n  │  clave:   %s\n  └──────────────────────────────────────────────────┘\n\n' "$ADMIN_USER" "$TEMP" >&3
  fi
else
  ok "Ya existen $USERS usuarios; no se crea superadministrador"
fi
bash "$PREFIX/current/scripts/healthcheck_lexair_geo.sh" --local | sed 's/^/  /' || warn "La verificación de salud informó problemas (ver arriba)"

cat <<EOF

LEXAIR GEO $VERSION instalado.
  Web:          https://${SERVER_NAME}/
  API:          https://${SERVER_NAME}/api/v1/health
  Mosaicos:     https://${SERVER_NAME}/tiles/{estilo}/{z}/{x}/{y}.png
  CA interna:   http://${SERVER_NAME}/ca/lexair-geo-ca.crt  (instálela en cada cliente)
  Registro:     $LOG
  Copias:       ${DATA}/backups (diaria 02:30)
EOF
