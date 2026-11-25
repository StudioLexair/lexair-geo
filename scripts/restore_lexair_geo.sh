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
LIST=$(mktemp); ERRLOG=$(mktemp); chmod 0644 "$LIST"
# Si algo falla antes de sustituir la base: se borra la temporal, la base actual
# queda intacta y el API vuelve a arrancar.
cleanup() {
  sudo -u postgres dropdb --if-exists "$TMPDB" 2>/dev/null || true
  rm -f "$LIST" "$ERRLOG"
  systemctl start lexair-geo-api 2>/dev/null || true
}
trap cleanup EXIT
sudo -u postgres createdb -O lexair_owner -E UTF8 -T template0 --locale=C.UTF-8 "$TMPDB"
sudo -u postgres psql -qAt -d "$TMPDB" -c "CREATE EXTENSION IF NOT EXISTS postgis; CREATE EXTENSION IF NOT EXISTS pg_trgm; CREATE EXTENSION IF NOT EXISTS unaccent;"
# Las extensiones ya existen (creadas como superusuario, con spatial_ref_sys
# poblada por PostGIS); sus entradas del volcado (CREATE/COMMENT ON EXTENSION y los
# datos de spatial_ref_sys) solo puede aplicarlas su propietario.
sudo -u postgres pg_restore -l "$FILE" \
  | grep -vE ' (EXTENSION - |COMMENT - EXTENSION |TABLE DATA public spatial_ref_sys )' > "$LIST"
echo "Restaurando en base temporal $TMPDB…"
if ! sudo -u postgres pg_restore -d "$TMPDB" --no-owner --role=lexair_owner -j 2 --exit-on-error \
     -L "$LIST" "$FILE" 2> "$ERRLOG"; then
  cat "$ERRLOG" >&2
  echo "FALLO al restaurar: la base '$DB' no se ha modificado." >&2
  exit 1
fi
# Comprobar lo esencial antes de sustituir: datos y permisos del rol de aplicación.
N=$(sudo -u postgres psql -qAt -d "$TMPDB" -c "SELECT count(*) FROM directory.persons")
GRANTS=$(sudo -u postgres psql -qAt -d "$TMPDB" -c "SELECT has_table_privilege('lexair_api', 'directory.persons', 'SELECT')
  AND has_table_privilege('lexair_api', 'geo.map_cluster_cells', 'SELECT')
  AND has_function_privilege('lexair_api', 'geo.refresh_map_clusters(boolean)', 'EXECUTE')")
[[ "$GRANTS" == t ]] || { echo "FALLO: la copia no conserva los permisos de lexair_api (¿generada con --no-acl?). Base '$DB' sin cambios." >&2; exit 1; }
echo "Base restaurada contiene $N personas"
sudo -u postgres psql -qAt -c "SELECT pg_terminate_backend(pid) FROM pg_stat_activity WHERE datname='$DB' AND pid <> pg_backend_pid()" >/dev/null
sudo -u postgres psql -qAt -c "DROP DATABASE IF EXISTS $DB" -c "ALTER DATABASE $TMPDB RENAME TO $DB"
trap - EXIT
rm -f "$LIST" "$ERRLOG"
sudo -u postgres psql -qAt -d "$DB" -c "REVOKE ALL ON DATABASE $DB FROM PUBLIC; GRANT CONNECT ON DATABASE $DB TO lexair_owner, lexair_api;"
systemctl start lexair-geo-api 2>/dev/null || true
logger -t lexair-geo-restore "Restaurada $(basename "$FILE") ($N personas)" 2>/dev/null || true
echo "Restauración completada. Ejecute healthcheck_lexair_geo.sh para verificar."
