-- LEXAIR GEO · Construcción del catálogo geográfico de Villa Clara.
-- Se ejecuta en la MÁQUINA DE PREPARACIÓN sobre la base importada con
-- osm2pgsql_lexair.lua (nunca en el servidor de producción).
-- Requiere: tabla vc_boundary (relación OSM r1923804) y tablas osm_*.
-- Produce tablas cat_* que export_geo_catalog.sh vuelca a CSV.
-- Fuente: © OpenStreetMap contributors, ODbL 1.0. No se inventa ningún dato:
-- todo procede de objetos OSM con su identificador.
\set ON_ERROR_STOP on
BEGIN;
CREATE EXTENSION IF NOT EXISTS unaccent;

CREATE OR REPLACE FUNCTION pg_temp.slug(t text) RETURNS text LANGUAGE sql IMMUTABLE AS $$
  SELECT trim(both '-' from regexp_replace(lower(unaccent(t)), '[^a-z0-9]+', '-', 'g'))
$$;

-- 1. Municipios: admin_level=6 contenidos en la provincia (>= 90 % de su área).
DROP TABLE IF EXISTS cat_municipalities;
CREATE TABLE cat_municipalities AS
SELECT a.relation_id AS osm_id, a.name, pg_temp.slug(a.name) AS code,
       ST_Multi(ST_MakeValid(a.geom))::geometry(MultiPolygon, 4326) AS boundary
  FROM osm_admin a, vc_boundary b
 WHERE a.admin_level = 6 AND a.name IS NOT NULL
   AND ST_Intersects(a.geom, b.geom)
   AND ST_Area(ST_Intersection(a.geom, b.geom)::geography) >= 0.9 * ST_Area(a.geom::geography);
CREATE INDEX ON cat_municipalities USING gist (boundary);

DO $$ BEGIN
  IF (SELECT count(*) FROM cat_municipalities) = 0 THEN
    RAISE EXCEPTION 'No se encontraron municipios admin_level=6 dentro de la provincia';
  END IF;
END $$;

-- 2. Localidades (place=*) dentro de algún municipio de Villa Clara.
DROP TABLE IF EXISTS cat_localities;
CREATE TABLE cat_localities AS
SELECT 'n' || p.node_id AS osm_id, p.name,
       CASE WHEN p.place IN ('city','town','village','hamlet','suburb','neighbourhood','quarter','locality')
            THEN p.place ELSE 'other' END AS kind,
       m.osm_id AS municipality_osm_id, p.geom
  FROM osm_places p JOIN cat_municipalities m ON ST_Contains(m.boundary, p.geom)
 WHERE p.name IS NOT NULL AND p.place NOT IN ('island', 'islet');

-- 3. Viviendas con número (addr:housenumber + addr:street).
DROP TABLE IF EXISTS cat_dwellings;
CREATE TABLE cat_dwellings AS
SELECT a.osm_type || a.osm_id AS osm_id, a.street AS street_name, a.housenumber AS house_number,
       m.osm_id AS municipality_osm_id, a.geom
  FROM osm_addresses a JOIN cat_municipalities m ON ST_Contains(m.boundary, a.geom)
 WHERE a.street IS NOT NULL AND a.housenumber IS NOT NULL AND length(a.housenumber) <= 20;

-- 4. Tramos de calle con nombre. Las vías homónimas de un municipio se
--    separan en grupos a menos de 250 m entre sí (p. ej. «Martí» en
--    distintos pueblos) y cada grupo se representa con un punto SOBRE la
--    propia vía (no un centroide en el vacío).
DROP TABLE IF EXISTS cat_streets;
CREATE TABLE cat_streets AS
WITH r AS (
  SELECT r.way_id, r.name, m.osm_id AS municipality_osm_id, r.geom
    FROM osm_roads r JOIN cat_municipalities m ON ST_Intersects(m.boundary, ST_PointOnSurface(r.geom))
   WHERE r.name IS NOT NULL AND length(r.name) <= 200
), c AS (
  SELECT r.*, ST_ClusterDBSCAN(ST_Transform(geom, 3857), eps => 250 / cos(radians(22.4)), minpoints => 1)
           OVER (PARTITION BY name, municipality_osm_id) AS grp
    FROM r
), g AS (
  SELECT name, municipality_osm_id, grp, ST_Collect(geom) AS geom, min(way_id) AS first_way, count(*) AS ways
    FROM c GROUP BY name, municipality_osm_id, grp
)
SELECT 'wg' || first_way AS osm_id, name AS street_name, municipality_osm_id, ways,
       ST_ClosestPoint(geom, ST_Centroid(geom))::geometry(Point, 4326) AS geom
  FROM g;

-- 4b. Alias de nomenclatura antigua/alternativa de las vías: direcciones
--     «por nombre» anteriores a la numeración actual (letras/números).
--     Cada alias apunta al nombre OSM vigente del tramo y hereda su punto.
DROP TABLE IF EXISTS cat_street_aliases;
CREATE TABLE cat_street_aliases AS
WITH src AS (
  SELECT r.way_id, r.name AS street_name, m.osm_id AS municipality_osm_id, r.geom,
         a AS alias
    FROM osm_roads r
    JOIN cat_municipalities m
      ON ST_Intersects(m.boundary, ST_PointOnSurface(r.geom))
   CROSS JOIN LATERAL unnest(ARRAY[
         (SELECT (x) FROM unnest(string_to_array(coalesce(r.old_name, ''), ';')) AS t(x)
           WHERE btrim(x) <> '' LIMIT 1),
         (SELECT (x) FROM unnest(string_to_array(coalesce(r.alt_name, ''), ';')) AS t(x)
           WHERE btrim(x) <> '' LIMIT 1)]) AS a
   WHERE r.name IS NOT NULL AND r.old_name IS NOT NULL OR r.name IS NOT NULL AND r.alt_name IS NOT NULL
), c AS (
  SELECT s.*, ST_ClusterDBSCAN(ST_Transform(geom, 3857), eps => 250 / cos(radians(22.4)), minpoints => 1)
           OVER (PARTITION BY street_name, municipality_osm_id, alias) AS grp
    FROM src s
), g AS (
  SELECT min(way_id) AS first_way, alias, street_name, municipality_osm_id, grp,
         ST_ClosestPoint(ST_Collect(geom), ST_Centroid(ST_Collect(geom)))::geometry(Point,4326) AS geom
    FROM c GROUP BY alias, street_name, municipality_osm_id, grp
)
SELECT 'wg' || first_way AS osm_id, btrim(alias) AS alias, street_name, municipality_osm_id, geom
  FROM g
 WHERE btrim(alias) <> '' AND btrim(alias) <> street_name;
CREATE INDEX ON cat_street_aliases USING gist (geom);

-- 5. Puntos de interés con nombre.
DROP TABLE IF EXISTS cat_pois;
CREATE TABLE cat_pois AS
SELECT p.osm_type || p.osm_id AS osm_id, p.name, left(p.category, 60) AS category,
       m.osm_id AS municipality_osm_id,
       CASE WHEN GeometryType(p.geom) = 'POINT' THEN p.geom ELSE ST_PointOnSurface(p.geom) END AS geom
  FROM osm_pois p JOIN cat_municipalities m ON ST_Intersects(m.boundary, ST_PointOnSurface(p.geom))
 WHERE p.name IS NOT NULL AND length(p.name) <= 200 AND p.category IS NOT NULL;

COMMIT;

SELECT 'municipalities' AS t, count(*) FROM cat_municipalities
UNION ALL SELECT 'localities', count(*) FROM cat_localities
UNION ALL SELECT 'dwellings', count(*) FROM cat_dwellings
UNION ALL SELECT 'streets', count(*) FROM cat_streets
UNION ALL SELECT 'pois', count(*) FROM cat_pois;
