#!/usr/bin/env python3
"""VIGÍA · Convierte un paquete de catálogo (export_geo_catalog.sh) en un
único fichero SQL autocontenido (COPY FROM STDIN) que psql.exe puede cargar
en Windows sin rutas relativas ni variables psql. Se usa para el servidor
integrado de la distribución Windows (servidor/sql/cargar_catalogo.sql).

Uso: make_catalog_sql.py <paquete> <salida.sql>
"""
import csv
import json
import sys
from pathlib import Path

pkg = Path(sys.argv[1])
out = Path(sys.argv[2])

meta = json.loads((pkg / "catalog.json").read_text(encoding="utf-8"))
src = meta["source"]
ts = src.get("timestamp") or "null"
if ts != "null":
    ts = f"'{ts}'::timestamptz"

FILES = {
    "mun": ("municipalities.csv", "osm_id bigint, code text, name text, wkt text"),
    "loc": ("localities.csv", "osm_id text, name text, kind text, municipality_osm_id bigint, wkt text"),
    "dw": ("dwellings.csv", "osm_id text, street_name text, house_number text, municipality_osm_id bigint, wkt text"),
    "st": ("streets.csv", "osm_id text, street_name text, municipality_osm_id bigint, wkt text"),
    "sa": ("street_aliases.csv", "osm_id text, alias text, street_name text, municipality_osm_id bigint, wkt text"),
    "poi": ("pois.csv", "osm_id text, name text, category text, municipality_osm_id bigint, wkt text"),
}


def copy_block(key: str) -> str:
    fname, cols = FILES[key]
    data = (pkg / fname).read_text(encoding="utf-8")
    if not data.endswith("\n"):
        data += "\n"
    if "\\." in data:
        raise SystemExit(f"{fname} contiene la secuencia de fin de COPY")
    return (
        f"CREATE TEMP TABLE s_{key} ({cols}) ON COMMIT DROP;\n"
        f"COPY s_{key} FROM STDIN WITH (FORMAT csv, HEADER true);\n"
        f"{data}"
        "\\.\n"
    )


def quote(s: str) -> str:
    return "'" + s.replace("'", "''") + "'"


parts = [f"""-- VIGÍA · Catálogo geográfico de Villa Clara (autogenerado).
-- Origen: {src['name']} — {src.get('file', 'n/d')} · licencia {src['license']}
-- {src['attribution']} — no se inventa ningún dato (todos los objetos con osm_id).
-- Ejecutar con: psql -d lexair_geo -f cargar_catalogo.sql
\\set ON_ERROR_STOP on
BEGIN;

INSERT INTO geo.data_sources (code, name, license, attribution, extract_date, sha256, is_synthetic)
VALUES ({quote(src['code'])}, {quote(src['name'])}, {quote(src['license'])}, {quote(src['attribution'])},
        {ts}, {quote(src['sha256'])}, false)
ON CONFLICT (code) DO UPDATE SET extract_date = EXCLUDED.extract_date, sha256 = EXCLUDED.sha256,
  imported_at = now();

{copy_block('mun')}
{copy_block('loc')}
{copy_block('dw')}
{copy_block('st')}
{copy_block('sa')}
{copy_block('poi')}

INSERT INTO geo.municipalities (code, name, osm_id, boundary, source_code)
SELECT code, name, osm_id, ST_Multi(ST_GeomFromText(wkt, 4326)), {quote(src['code'])} FROM s_mun
ON CONFLICT (osm_id) DO UPDATE SET name = EXCLUDED.name, boundary = EXCLUDED.boundary,
  source_code = EXCLUDED.source_code;

CREATE TEMP TABLE mmap ON COMMIT DROP AS SELECT id, osm_id FROM geo.municipalities WHERE osm_id IS NOT NULL;

INSERT INTO geo.localities (municipality_id, name, kind, centroid, osm_id, source_code)
SELECT m.id, s.name, s.kind, ST_GeomFromText(s.wkt, 4326)::geography, s.osm_id, {quote(src['code'])}
  FROM s_loc s LEFT JOIN mmap m ON m.osm_id = s.municipality_osm_id
ON CONFLICT (osm_id) DO UPDATE SET municipality_id = EXCLUDED.municipality_id, name = EXCLUDED.name,
  kind = EXCLUDED.kind, centroid = EXCLUDED.centroid;
DELETE FROM geo.localities l WHERE l.source_code = {quote(src['code'])} AND NOT EXISTS
  (SELECT 1 FROM s_loc s WHERE s.osm_id = l.osm_id);

-- Localidad más cercana (<= 3 km) para direcciones y tramos de calle.
CREATE TEMP TABLE s_addr ON COMMIT DROP AS
SELECT osm_id, street_name, house_number, municipality_osm_id, 'dwelling'::text AS granularity,
       ST_GeomFromText(wkt, 4326)::geography AS geom FROM s_dw
UNION ALL
SELECT osm_id, street_name, NULL, municipality_osm_id, 'street', ST_GeomFromText(wkt, 4326)::geography FROM s_st;

INSERT INTO geo.addresses (street_name, house_number, locality_id, municipality_id, granularity, geom, osm_id, source_code)
SELECT a.street_name, a.house_number,
       (SELECT l.id FROM geo.localities l WHERE ST_DWithin(l.centroid, a.geom, 3000)
         ORDER BY l.centroid <-> a.geom LIMIT 1),
       m.id, a.granularity, a.geom, a.osm_id, {quote(src['code'])}
  FROM s_addr a LEFT JOIN mmap m ON m.osm_id = a.municipality_osm_id
ON CONFLICT (osm_id) WHERE osm_id IS NOT NULL DO UPDATE SET street_name = EXCLUDED.street_name,
  house_number = EXCLUDED.house_number, locality_id = EXCLUDED.locality_id,
  municipality_id = EXCLUDED.municipality_id, granularity = EXCLUDED.granularity, geom = EXCLUDED.geom;
DELETE FROM geo.addresses ad WHERE ad.source_code = {quote(src['code'])} AND NOT EXISTS
  (SELECT 1 FROM s_addr s WHERE s.osm_id = ad.osm_id);

-- Nomenclatura antigua/alternativa: solo añade, nunca toca alias administrados.
INSERT INTO geo.street_aliases (alias, street_name, municipality_id)
SELECT DISTINCT ON (s.alias, s.street_name, m.id) s.alias, s.street_name, m.id
  FROM s_sa s LEFT JOIN mmap m ON m.osm_id = s.municipality_osm_id
 WHERE s.alias IS NOT NULL AND s.street_name IS NOT NULL
ON CONFLICT (alias_norm, street_norm, coalesce(municipality_id, 0)) DO NOTHING;

INSERT INTO geo.points_of_interest (name, category, municipality_id, geom, osm_id, source_code)
SELECT s.name, s.category, m.id, ST_GeomFromText(s.wkt, 4326)::geography, s.osm_id, {quote(src['code'])}
  FROM s_poi s LEFT JOIN mmap m ON m.osm_id = s.municipality_osm_id
ON CONFLICT (osm_id) DO UPDATE SET name = EXCLUDED.name, category = EXCLUDED.category,
  municipality_id = EXCLUDED.municipality_id, geom = EXCLUDED.geom;
DELETE FROM geo.points_of_interest p WHERE p.source_code = {quote(src['code'])} AND NOT EXISTS
  (SELECT 1 FROM s_poi s WHERE s.osm_id = p.osm_id);

INSERT INTO audit.audit_logs (action, entity_type, entity_id, success, details)
VALUES ('geo.catalog_load', 'data_source', {quote(src['code'])}, true,
        json_build_object('sha256', {quote(src['sha256'])}, 'timestamp', {quote(src.get('timestamp') or '')},
          'municipalities', (SELECT count(*) FROM s_mun), 'addresses', (SELECT count(*) FROM s_addr),
          'pois', (SELECT count(*) FROM s_poi))::jsonb);
COMMIT;
ANALYZE geo.municipalities; ANALYZE geo.localities; ANALYZE geo.addresses; ANALYZE geo.points_of_interest;
"""]

out.write_text(parts[0], encoding="utf-8")
rows = sum(
    sum(1 for _ in open(pkg / f, encoding="utf-8")) - 1
    for f, _ in FILES.values()
)
print(f"SQL generado: {out} ({out.stat().st_size / 1e6:.1f} MB, {rows} filas)")
