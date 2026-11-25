#!/usr/bin/env bash
# LEXAIR GEO · Restauración desde una copia de backup_lexair_geo.sh.
# DESTRUCTIVO: reemplaza la base lexair_geo completa. Requiere confirmación
# explícita escribiendo el nombre de la base (o --confirm lexair_geo en
# procedimientos automatizados y documentados).
# Uso: sudo restore_lexair_geo.sh /srv/lexair-geo/backups/lexair_geo_<fecha>.dump [--confirm lexair_geo]
set -Eeuo pipefail
DB=lexair_geo
FILE="${1:?Uso: $0 <archivo.dump> [--confirm lexair_geo]}"; shift || true
CONFIRM=""
while [[ $# -gt 0 ]]; do
  case "$1" in --confirm) CONFIRM="$2"; shift 2 ;; *) echo "Opción desconocida: $1" >&2; exit 2 ;; esac
done
[[ $EUID -eq 0 ]] || { echo "Ejecute como root." >&2; exit 1; }
[[ -f "$FILE" ]] || { echo "No existe $FILE" >&2; exit 1; }
META="${FILE%.dump}.meta.json"
if [[ -f "$META" ]]; then
  EXPECTED=$(grep -o '"sha256":"[0-9a-f]\{64\}"' "$META" | cut -d'"' -f4)
  ACTUAL=$(sha256sum "$FILE" | cut -d' ' -f1)
  [[ "$EXPECTED" == "$ACTUAL" ]] || { echo "SHA-256 no coincide con $META: copia dañada" >&2; exit 1; }
  echo "Integridad verificada (sha256 $ACTUAL)"
  cat "$META"; echo
else
  echo "AVISO: no hay $META; no se puede verificar la integridad."
fi
sudo -u postgres pg_restore -l "$FILE" > /dev/null || { echo "El archivo no es un volcado válido" >&2; exit 1; }

echo
echo "Esta operación BORRARÁ la base '$DB' actual y la sustituirá por la copia."
if [[ -z "$CONFIRM" ]]; then
  if [[ -t 0 ]]; then read -r -p "Escriba el nombre de la base ($DB) para confirmar: " CONFIRM
  else echo "Sin terminal: use --confirm $DB" >&2; exit 1; fi
fi
[[ "$CONFIRM" == "$DB" ]] || { echo "Confirmación incorrecta. No se ha modificado nada."; exit 1; }

# Copia de seguridad previa automática (punto de retorno).
if [[ -n "$(sudo -u postgres psql -qAt -c "SELECT 1 FROM pg_database WHERE datname='$DB'")" ]]; then
  echo "Creando copia previa de la base actual…"
  "$(dirname "$0")/backup_lexair_geo.sh" --keep 1000 --quiet
fi
systemctl stop lexair-geo-api 2>/dev/null || true
TMPDB="${DB}_restore_$$"
sudo -u postgres createdb -O lexair_owner -E UTF8 -T template0 --locale=C.UTF-8 "$TMPDB"
trap 'sudo -u postgres dropdb --if-exists "$TMPDB" 2>/dev/null || true' EXIT
sudo -u postgres psql -qAt -d "$TMPDB" -c "CREATE EXTENSION IF NOT EXISTS postgis; CREATE EXTENSION IF NOT EXISTS pg_trgm; CREATE EXTENSION IF NOT EXISTS unaccent;"
echo "Restaurando en base temporal $TMPDB…"
sudo -u postgres pg_restore -d "$TMPDB" --no-owner --role=lexair_owner -j 2 --exit-on-error "$FILE" 2>&1 \
  | grep -v 'already exists' || true
# Comprobar que lo esencial existe antes de sustituir.
N=$(sudo -u postgres psql -qAt -d "$TMPDB" -c "SELECT count(*) FROM directory.persons")
echo "Base restaurada contiene $N personas"
sudo -u postgres psql -qAt -c "SELECT pg_terminate_backend(pid) FROM pg_stat_activity WHERE datname='$DB' AND pid <> pg_backend_pid()" >/dev/null
sudo -u postgres psql -qAt -c "DROP DATABASE IF EXISTS $DB" -c "ALTER DATABASE $TMPDB RENAME TO $DB"
trap - EXIT
# Permisos del rol de aplicación (pg_dump se hizo con --no-acl).
MIG=/opt/lexair-geo/current/database/migrations
for f in "$MIG"/0006_*.sql "$MIG"/0007_*.sql; do [[ -f "$f" ]] && sudo -u postgres psql -q -d "$DB" -v ON_ERROR_STOP=1 -f "$f"; done
sudo -u postgres psql -qAt -d "$DB" -c "REVOKE ALL ON DATABASE $DB FROM PUBLIC; GRANT CONNECT ON DATABASE $DB TO lexair_owner, lexair_api;"
systemctl start lexair-geo-api 2>/dev/null || true
logger -t lexair-geo-restore "Restaurada $(basename "$FILE") ($N personas)" 2>/dev/null || true
echo "Restauración completada. Ejecute healthcheck_lexair_geo.sh para verificar."
