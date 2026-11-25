#!/usr/bin/env bash
# LEXAIR GEO · Carga un paquete de catálogo (export_geo_catalog.sh) en la
# base de producción. Idempotente: actualiza por osm_id y retira los objetos
# OSM que ya no existen. No toca direcciones/alias administrados localmente.
# Uso: DATABASE_URL=... load_geo_catalog.sh <directorio_paquete>
set -euo pipefail

PKG="${1:?Uso: DATABASE_URL=... $0 <directorio_paquete>}"
: "${DATABASE_URL:?Defina DATABASE_URL (rol propietario del esquema geo)}"
[[ -f "$PKG/catalog.json" ]] || { echo "Falta $PKG/catalog.json" >&2; exit 2; }

json() { python3 -c "import json,sys;d=json.load(open(sys.argv[1]));print(eval('d'+sys.argv[2]))" "$PKG/catalog.json" "$1"; }

echo "[1/3] Verificando sumas SHA-256"
for f in municipalities localities dwellings streets pois; do
  expected=$(json "['files']['$f']['sha256']")
  actual=$(sha256sum "$PKG/$f.csv" | cut -d' ' -f1)
  [[ "$expected" == "$actual" ]] || { echo "Suma incorrecta en $f.csv" >&2; exit 3; }
done
[[ "$(json "['isSynthetic']")" == "False" ]] || echo "AVISO: paquete marcado como sintético"

SRC_CODE=$(json "['source']['code']")
SRC_TS=$(json "['source']['timestamp']")
SRC_SHA=$(json "['source']['sha256']")

echo "[2/3] Cargando en una única transacción"
psql "$DATABASE_URL" -v ON_ERROR_STOP=1 -q \
  -v src="$SRC_CODE" -v ts="$SRC_TS" -v sha="$SRC_SHA" <<SQL
BEGIN;
CREATE TEMP TABLE s_mun (osm_id bigint, code text, name text, wkt text) ON COMMIT DROP;
CREATE TEMP TABLE s_loc (osm_id text, name text, kind text, municipality_osm_id bigint, wkt text) ON COMMIT DROP;
CREATE TEMP TABLE s_dw (osm_id text, street_name text, house_number text, municipality_osm_id bigint, wkt text) ON COMMIT DROP;
CREATE TEMP TABLE s_st (osm_id text, street_name text, municipality_osm_id bigint, wkt text) ON COMMIT DROP;
CREATE TEMP TABLE s_poi (osm_id text, name text, category text, municipality_osm_id bigint, wkt text) ON COMMIT DROP;
\copy s_mun FROM '$PKG/municipalities.csv' WITH (FORMAT csv, HEADER true)
\copy s_loc FROM '$PKG/localities.csv' WITH (FORMAT csv, HEADER true)
\copy s_dw FROM '$PKG/dwellings.csv' WITH (FORMAT csv, HEADER true)
\copy s_st FROM '$PKG/streets.csv' WITH (FORMAT csv, HEADER true)
\copy s_poi FROM '$PKG/pois.csv' WITH (FORMAT csv, HEADER true)

INSERT INTO geo.data_sources (code, name, license, attribution, extract_date, sha256, is_synthetic)
VALUES (:'src', 'OpenStreetMap (extracto Geofabrik de Cuba)', 'ODbL-1.0', '© OpenStreetMap contributors',
        NULLIF(:'ts', 'null')::timestamptz, :'sha', false)
ON CONFLICT (code) DO UPDATE SET extract_date = EXCLUDED.extract_date, sha256 = EXCLUDED.sha256,
  imported_at = now();

INSERT INTO geo.municipalities (code, name, osm_id, boundary, source_code)
SELECT code, name, osm_id, ST_Multi(ST_GeomFromText(wkt, 4326)), :'src' FROM s_mun
ON CONFLICT (osm_id) DO UPDATE SET name = EXCLUDED.name, boundary = EXCLUDED.boundary,
  source_code = EXCLUDED.source_code;

CREATE TEMP TABLE mmap ON COMMIT DROP AS SELECT id, osm_id FROM geo.municipalities WHERE osm_id IS NOT NULL;

INSERT INTO geo.localities (municipality_id, name, kind, centroid, osm_id, source_code)
SELECT m.id, s.name, s.kind, ST_GeomFromText(s.wkt, 4326)::geography, s.osm_id, :'src'
  FROM s_loc s LEFT JOIN mmap m ON m.osm_id = s.municipality_osm_id
ON CONFLICT (osm_id) DO UPDATE SET municipality_id = EXCLUDED.municipality_id, name = EXCLUDED.name,
  kind = EXCLUDED.kind, centroid = EXCLUDED.centroid;
DELETE FROM geo.localities l WHERE l.source_code = :'src' AND NOT EXISTS (SELECT 1 FROM s_loc s WHERE s.osm_id = l.osm_id);

-- Localidad más cercana (<= 3 km) para direcciones y calles.
CREATE TEMP TABLE s_addr ON COMMIT DROP AS
SELECT osm_id, street_name, house_number, municipality_osm_id, 'dwelling'::text AS granularity,
       ST_GeomFromText(wkt, 4326)::geography AS geom FROM s_dw
UNION ALL
SELECT osm_id, street_name, NULL, municipality_osm_id, 'street', ST_GeomFromText(wkt, 4326)::geography FROM s_st;

INSERT INTO geo.addresses (street_name, house_number, locality_id, municipality_id, granularity, geom, osm_id, source_code)
SELECT a.street_name, a.house_number,
       (SELECT l.id FROM geo.localities l WHERE ST_DWithin(l.centroid, a.geom, 3000)
         ORDER BY l.centroid <-> a.geom LIMIT 1),
       m.id, a.granularity, a.geom, a.osm_id, :'src'
  FROM s_addr a LEFT JOIN mmap m ON m.osm_id = a.municipality_osm_id
ON CONFLICT (osm_id) WHERE osm_id IS NOT NULL DO UPDATE SET street_name = EXCLUDED.street_name,
  house_number = EXCLUDED.house_number, locality_id = EXCLUDED.locality_id,
  municipality_id = EXCLUDED.municipality_id, granularity = EXCLUDED.granularity, geom = EXCLUDED.geom;
DELETE FROM geo.addresses ad WHERE ad.source_code = :'src' AND NOT EXISTS (SELECT 1 FROM s_addr s WHERE s.osm_id = ad.osm_id);

INSERT INTO geo.points_of_interest (name, category, municipality_id, geom, osm_id, source_code)
SELECT s.name, s.category, m.id, ST_GeomFromText(s.wkt, 4326)::geography, s.osm_id, :'src'
  FROM s_poi s LEFT JOIN mmap m ON m.osm_id = s.municipality_osm_id
ON CONFLICT (osm_id) DO UPDATE SET name = EXCLUDED.name, category = EXCLUDED.category,
  municipality_id = EXCLUDED.municipality_id, geom = EXCLUDED.geom;
DELETE FROM geo.points_of_interest p WHERE p.source_code = :'src' AND NOT EXISTS (SELECT 1 FROM s_poi s WHERE s.osm_id = p.osm_id);

INSERT INTO audit.audit_logs (action, entity_type, entity_id, success, details)
VALUES ('geo.catalog_load', 'data_source', :'src', true,
        json_build_object('sha256', :'sha', 'timestamp', :'ts',
          'municipalities', (SELECT count(*) FROM s_mun), 'addresses', (SELECT count(*) FROM s_addr),
          'pois', (SELECT count(*) FROM s_poi))::jsonb);
COMMIT;
ANALYZE geo.municipalities; ANALYZE geo.localities; ANALYZE geo.addresses; ANALYZE geo.points_of_interest;
SQL

echo "[3/3] Recuento tras la carga"
psql "$DATABASE_URL" -At -c "SELECT 'municipios', count(*) FROM geo.municipalities
  UNION ALL SELECT 'localidades', count(*) FROM geo.localities
  UNION ALL SELECT 'direcciones', count(*) FROM geo.addresses
  UNION ALL SELECT 'pdi', count(*) FROM geo.points_of_interest"
