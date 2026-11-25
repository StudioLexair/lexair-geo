-- LEXAIR GEO · 0010 · Agregados precalculados para el mapa (zoom 6–16).
--
-- Motivo (medido): agrupar 500 000 ubicaciones en cada petición a escala
-- provincial costaba segundos por consulta y provocaba tiempos de espera con 30
-- usuarios. Se precalculan recuentos por celda de rejilla y por combinación de
-- pertenencia (bit 1 = Grupo A, bit 2 = Grupo B) y visibilidad (bit 4 =
-- restringida), de modo que el filtrado por permisos sigue siendo exacto.
-- Celda del nivel z: 90 / 2^z grados (= 360 / 2^z / 4, ≈ 64 px en pantalla).
-- En zoom ≥ 15 los niveles 15–16 sirven además como cota superior barata para
-- decidir entre puntos individuales (consulta en vivo) y agrupaciones.

CREATE MATERIALIZED VIEW IF NOT EXISTS geo.map_cluster_cells AS
WITH mem AS (
  SELECT m.person_id, bit_or(CASE g.code WHEN 'A' THEN 1 WHEN 'B' THEN 2 ELSE 0 END)::int AS gm
    FROM directory.person_memberships m
    JOIN directory.person_groups g ON g.id = m.group_id
   GROUP BY m.person_id
), base AS (
  SELECT ST_X(l.geom::geometry) AS lon, ST_Y(l.geom::geometry) AS lat,
         (mem.gm | CASE WHEN p.visibility = 'normal' THEN 0 ELSE 4 END)::smallint AS flags
    FROM geo.person_locations l
    JOIN directory.persons p ON p.id = l.person_id
    JOIN mem ON mem.person_id = p.id
   WHERE p.is_active
)
SELECT z::smallint AS level,
       floor(b.lon / (90.0 / 2 ^ z))::int AS cx,
       floor(b.lat / (90.0 / 2 ^ z))::int AS cy,
       b.flags,
       count(*)::int AS n,
       sum(b.lat) AS sum_lat,
       sum(b.lon) AS sum_lon
  FROM base b
 CROSS JOIN generate_series(6, 16) z
 GROUP BY 1, 2, 3, 4
WITH DATA;

-- Índice único: requisito de REFRESH ... CONCURRENTLY (lecturas sin bloqueo).
CREATE UNIQUE INDEX IF NOT EXISTS map_cluster_cells_uq ON geo.map_cluster_cells (level, cx, cy, flags);

-- Estado de frescura: cambios marcados por triggers de sentencia (baratos incluso
-- en importaciones masivas) y momento del último refresco.
CREATE TABLE IF NOT EXISTS geo.map_cluster_state (
  id           boolean PRIMARY KEY DEFAULT true CHECK (id),
  changed_at   timestamptz NOT NULL DEFAULT now(),
  refreshed_at timestamptz NOT NULL DEFAULT now(),
  refresh_ms   integer
);
INSERT INTO geo.map_cluster_state (id) VALUES (true) ON CONFLICT DO NOTHING;

CREATE OR REPLACE FUNCTION geo.mark_map_clusters_changed() RETURNS trigger
LANGUAGE plpgsql SECURITY DEFINER SET search_path = pg_catalog, geo AS $$
BEGIN
  UPDATE geo.map_cluster_state SET changed_at = clock_timestamp() WHERE id;
  RETURN NULL;
END $$;

DROP TRIGGER IF EXISTS map_clusters_changed ON geo.person_locations;
CREATE TRIGGER map_clusters_changed AFTER INSERT OR UPDATE OR DELETE OR TRUNCATE ON geo.person_locations
  FOR EACH STATEMENT EXECUTE FUNCTION geo.mark_map_clusters_changed();
DROP TRIGGER IF EXISTS map_clusters_changed ON directory.persons;
CREATE TRIGGER map_clusters_changed AFTER INSERT OR UPDATE OR DELETE OR TRUNCATE ON directory.persons
  FOR EACH STATEMENT EXECUTE FUNCTION geo.mark_map_clusters_changed();
DROP TRIGGER IF EXISTS map_clusters_changed ON directory.person_memberships;
CREATE TRIGGER map_clusters_changed AFTER INSERT OR UPDATE OR DELETE OR TRUNCATE ON directory.person_memberships
  FOR EACH STATEMENT EXECUTE FUNCTION geo.mark_map_clusters_changed();

-- Refresco con exclusión mutua (bloqueo consultivo): devuelve false si otro
-- proceso ya está refrescando o si no hay cambios.
CREATE OR REPLACE FUNCTION geo.refresh_map_clusters(force boolean DEFAULT false) RETURNS boolean
LANGUAGE plpgsql SECURITY DEFINER SET search_path = pg_catalog, geo AS $$
DECLARE
  t0 timestamptz := clock_timestamp();
  pending boolean;
BEGIN
  IF NOT pg_try_advisory_xact_lock(hashtext('lexair.map_cluster_cells')) THEN
    RETURN false;
  END IF;
  SELECT changed_at > refreshed_at INTO pending FROM geo.map_cluster_state WHERE id;
  IF NOT force AND NOT coalesce(pending, true) THEN
    RETURN false;
  END IF;
  REFRESH MATERIALIZED VIEW CONCURRENTLY geo.map_cluster_cells;
  UPDATE geo.map_cluster_state
     SET refreshed_at = t0, refresh_ms = (extract(epoch FROM clock_timestamp() - t0) * 1000)::int
   WHERE id;
  RETURN true;
END $$;

REVOKE ALL ON FUNCTION geo.refresh_map_clusters(boolean) FROM PUBLIC;
GRANT EXECUTE ON FUNCTION geo.refresh_map_clusters(boolean) TO lexair_api;
GRANT SELECT ON geo.map_cluster_cells, geo.map_cluster_state TO lexair_api;

INSERT INTO catalog.system_settings (key, value, description) VALUES
  ('map.cluster_refresh_s', '60',
   'Segundos entre comprobaciones para refrescar los agregados del mapa (0 = desactivado; mínimo efectivo 10)')
ON CONFLICT (key) DO NOTHING;
