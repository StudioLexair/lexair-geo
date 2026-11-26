#!/usr/bin/env bash
# LEXAIR GEO · Genera el paquete cartográfico raster (MBTiles + manifest.json).
# Máquina de preparación o runner de CI ÚNICAMENTE (no en producción).
# Requisitos previos: base de preparación importada con osm2pgsql_lexair.lua,
# tabla vc_boundary y polígonos de tierra de osmcoastline.
# Uso: build_map_package.sh <PREP_DSN> <coast.db> <PBF> <OUT_DIR> [minzoom] [maxzoom] [paralelo]
set -euo pipefail
DSN="$1"; LAND="$2"; PBF="$3"; OUT="$4"; MINZ="${5:-6}"; MAXZ="${6:-15}"; PAR="${7:-2}"
HERE="$(cd "$(dirname "$0")" && pwd)"
RESUME="${RESUME:-}"   # RESUME=1: conserva los niveles de zoom ya completos
mkdir -p "$OUT"
STYLES=(standard dark high_contrast)

render() {
  /usr/bin/python3 "$HERE/render_mbtiles.py" --dsn "$DSN" --land "$LAND" --style "$1" \
    --minzoom "$MINZ" --maxzoom "$MAXZ" --out "$OUT/$1.mbtiles" ${RESUME:+--resume} > "$OUT/render_$1.log" 2>&1
}
export -f render; export DSN LAND MINZ MAXZ OUT HERE RESUME
printf '%s\n' "${STYLES[@]}" | xargs -P "$PAR" -I{} bash -c 'render {}'

PBF_SHA=$(sha256sum "$PBF" | cut -d' ' -f1)
TS=$(psql "$DSN" -At -c "SELECT value FROM osm2pgsql_properties WHERE property = 'replication_timestamp'")
BOUNDS=$(/usr/bin/python3 -c "import sqlite3;print(sqlite3.connect('$OUT/standard.mbtiles').execute(\"select value from metadata where name='bounds'\").fetchone()[0])")
VERSION="vc-$(date -u +%Y%m%d)-z${MAXZ}"

/usr/bin/python3 - "$OUT" "$VERSION" "$PBF" "$PBF_SHA" "$TS" "$BOUNDS" "$MINZ" "$MAXZ" <<'PY'
import hashlib, json, os, sys, datetime
out, version, pbf, sha, ts, bounds, minz, maxz = sys.argv[1:]
names = {"standard": ("Estándar", "#aad3df"), "dark": ("Oscuro", "#17263a"), "high_contrast": ("Alto contraste", "#0047ab")}
styles = []
for sid, (name, bg) in names.items():
    f = f"{sid}.mbtiles"
    h = hashlib.sha256(open(os.path.join(out, f), "rb").read()).hexdigest()
    styles.append({"id": sid, "name": name, "file": f, "sha256": h, "kind": sid, "background": bg})
b = [float(v) for v in bounds.split(",")]
manifest = {
    "name": "lexair-villa-clara", "version": version,
    "generatedAt": datetime.datetime.now(datetime.timezone.utc).strftime("%Y-%m-%dT%H:%M:%SZ"),
    "isSynthetic": False,
    "source": {"name": "OpenStreetMap — extracto Geofabrik de Cuba", "file": os.path.basename(pbf),
               "sha256": sha, "timestamp": ts or None, "license": "ODbL-1.0"},
    "attribution": "© OpenStreetMap contributors", "license": "ODbL-1.0 (datos); teselas renderizadas por Studio Lexair",
    "bounds": b, "center": [-79.9653, 22.4067], "minzoom": int(minz), "maxzoom": int(maxz),
    "styles": styles,
    "missingFeatures": ["Topográfico: no hay datos de relieve locales", "Satélite: no hay imágenes con licencia"],
    "renderer": "Mapnik 4 · scripts/maps/lexair_styles.py",
}
json.dump(manifest, open(os.path.join(out, "manifest.json"), "w"), ensure_ascii=False, indent=2)
print(json.dumps({k: manifest[k] for k in ("version", "minzoom", "maxzoom", "bounds")}))
PY
ls -la "$OUT"
