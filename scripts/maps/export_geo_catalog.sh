#!/usr/bin/env bash
# LEXAIR GEO · Exporta el catálogo geográfico (tablas cat_*) a un paquete
# portable: CSV + catalog.json con sumas SHA-256. Máquina de preparación.
# Uso: export_geo_catalog.sh <PREP_DATABASE_URL> <PBF> <OUT_DIR>
set -euo pipefail
umask 027

if [[ $# -ne 3 ]]; then
  echo "Uso: $0 <PREP_DATABASE_URL> <fichero.osm.pbf> <directorio_salida>" >&2
  exit 2
fi
DB="$1"; PBF="$2"; OUT="$3"
[[ -f "$PBF" ]] || { echo "No existe $PBF" >&2; exit 2; }
mkdir -p "$OUT"

q() { psql "$DB" -v ON_ERROR_STOP=1 -At -c "$1"; }
copy_out() { # tabla columnas fichero
  psql "$DB" -v ON_ERROR_STOP=1 -q -c "\\copy (SELECT $2 FROM $1 ORDER BY osm_id) TO '$OUT/$3' WITH (FORMAT csv, HEADER true)"
}

echo "[1/3] Exportando tablas cat_* desde la base de preparación"
copy_out cat_municipalities "osm_id, code, name, ST_AsText(boundary) AS wkt" municipalities.csv
copy_out cat_localities "osm_id, name, kind, municipality_osm_id, ST_AsText(geom) AS wkt" localities.csv
copy_out cat_dwellings "osm_id, street_name, house_number, municipality_osm_id, ST_AsText(geom) AS wkt" dwellings.csv
copy_out cat_streets "osm_id, street_name, municipality_osm_id, ST_AsText(geom) AS wkt" streets.csv
copy_out cat_street_aliases "osm_id, alias, street_name, municipality_osm_id, ST_AsText(geom) AS wkt" street_aliases.csv
copy_out cat_pois "osm_id, name, category, municipality_osm_id, ST_AsText(geom) AS wkt" pois.csv

echo "[2/3] Calculando sumas de verificación"
PBF_SHA=$(sha256sum "$PBF" | cut -d' ' -f1)
REPL_TS=$(q "SELECT value FROM osm2pgsql_properties WHERE property = 'replication_timestamp'" || true)
files_json=""
for f in municipalities localities dwellings streets street_aliases pois; do
  sha=$(sha256sum "$OUT/$f.csv" | cut -d' ' -f1)
  rows=$(( $(wc -l < "$OUT/$f.csv") - 1 ))
  files_json+="${files_json:+,}\"$f\":{\"file\":\"$f.csv\",\"sha256\":\"$sha\",\"rows\":$rows}"
done

echo "[3/3] Escribiendo catalog.json"
cat > "$OUT/catalog.json" <<JSON
{
  "format": "lexair-geo-catalog/1",
  "region": "Villa Clara, Cuba (OSM relation 1923804)",
  "generatedAt": "$(date -u +%Y-%m-%dT%H:%M:%SZ)",
  "source": {
    "code": "osm_geofabrik",
    "name": "OpenStreetMap (extracto Geofabrik de Cuba)",
    "license": "ODbL-1.0",
    "attribution": "© OpenStreetMap contributors",
    "file": "$(basename "$PBF")",
    "sha256": "$PBF_SHA",
    "timestamp": "${REPL_TS:-null}"
  },
  "isSynthetic": false,
  "files": {$files_json}
}
JSON
echo "Paquete listo en $OUT"
