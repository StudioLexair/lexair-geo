#!/usr/bin/env bash
# LEXAIR GEO · Copia de seguridad (base de datos + configuración, sin claves privadas).
# Uso: sudo backup_lexair_geo.sh [--dir /srv/lexair-geo/backups] [--keep 14] [--quiet]
# Genera lexair_geo_<fecha>.dump (pg_dump -Fc) y lexair_geo_<fecha>.meta.json con
# SHA-256, versión y recuentos. La copia contiene datos personales: guárdela cifrada
# y fuera del servidor (docs/OPERATIONS.md). Nunca la suba a repositorios.
set -Eeuo pipefail
umask 077
DIR=/srv/lexair-geo/backups; KEEP=14; QUIET=0; DB=lexair_geo
while [[ $# -gt 0 ]]; do
  case "$1" in
    --dir) DIR="$2"; shift 2 ;; --keep) KEEP="$2"; shift 2 ;; --quiet) QUIET=1; shift ;;
    *) echo "Opción desconocida: $1" >&2; exit 2 ;;
  esac
done
[[ $EUID -eq 0 ]] || { echo "Ejecute como root." >&2; exit 1; }
[[ "$KEEP" =~ ^[0-9]+$ && "$KEEP" -ge 1 ]] || { echo "--keep no válido" >&2; exit 2; }
say() { (( QUIET )) || echo "$@"; }
install -d -m 0750 -o postgres -g lexair "$DIR" 2>/dev/null || install -d -m 0750 -o postgres "$DIR"
STAMP=$(date -u +%Y%m%dT%H%M%SZ)
OUT="$DIR/lexair_geo_${STAMP}.dump"
FREE_MB=$(df -Pm "$DIR" | awk 'NR==2 {print $4}')
DB_MB=$(sudo -u postgres psql -qAt -c "SELECT pg_database_size('$DB') / 1048576")
(( FREE_MB > DB_MB )) || { echo "Espacio insuficiente en $DIR (${FREE_MB} MB libres, base ${DB_MB} MB)" >&2; exit 1; }

say "Volcando $DB → $OUT"
T0=$(date +%s)
sudo -u postgres pg_dump -d "$DB" -Fc -Z 6 --no-owner --no-acl -f "$OUT.part"
mv "$OUT.part" "$OUT"
sudo -u postgres pg_restore -l "$OUT" > /dev/null   # el archivo es legible
SHA=$(sha256sum "$OUT" | cut -d' ' -f1)
COUNTS=$(sudo -u postgres psql -d "$DB" -qAt -c "SELECT json_build_object(
  'persons', (SELECT count(*) FROM directory.persons),
  'locations', (SELECT count(*) FROM geo.person_locations),
  'memberships', (SELECT count(*) FROM directory.person_memberships),
  'users', (SELECT count(*) FROM identity.users),
  'audit', (SELECT count(*) FROM audit.audit_logs),
  'lastMigration', (SELECT max(version) FROM public.schema_migrations))")
VER=$(cat /opt/lexair-geo/current/VERSION 2>/dev/null || echo desconocida)
cat > "$DIR/lexair_geo_${STAMP}.meta.json" <<JSON
{"file":"$(basename "$OUT")","sha256":"$SHA","createdAt":"$STAMP","appVersion":"$VER",
 "pgVersion":"$(sudo -u postgres psql -qAt -c 'SHOW server_version')","sizeBytes":$(stat -c %s "$OUT"),
 "seconds":$(( $(date +%s) - T0 )),"counts":$COUNTS}
JSON
# Configuración (sin claves privadas ni secretos de base de datos).
tar -C / -czf "$DIR/lexair_geo_${STAMP}_config.tar.gz" --exclude='etc/lexair-geo/pki/private' \
  --exclude='etc/lexair-geo/db-secrets.env' --exclude='etc/lexair-geo/api.env' \
  etc/lexair-geo etc/nginx/sites-available/lexair-geo.conf 2>/dev/null || true
chown postgres:lexair "$DIR"/lexair_geo_"${STAMP}"* 2>/dev/null || true
chmod 0640 "$DIR"/lexair_geo_"${STAMP}"*

# Rotación: conservar las KEEP copias más recientes.
ls -1t "$DIR"/lexair_geo_*.dump 2>/dev/null | tail -n +$((KEEP + 1)) | while read -r old; do
  base="${old%.dump}"; rm -f "$old" "$base.meta.json" "${base}_config.tar.gz"; say "Rotada: $(basename "$old")"
done
say "OK $(basename "$OUT") $(du -h "$OUT" | cut -f1) sha256=$SHA"
logger -t lexair-geo-backup "OK $(basename "$OUT") sha256=$SHA" 2>/dev/null || true
