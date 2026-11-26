-- LEXAIR GEO · 0011 · Operación de pases: zonas dibujables, internos, pases,
-- personal de la fuerza y conectores Oracle 11g.
--
-- Modelo:
--  * geo.zone_categories  catálogo configurable de categorías de zona.
--  * geo.zones            áreas dibujadas en el mapa (círculo, rectángulo o
--                         polígono) con etiqueta, estilo y categoría.
--  * geo.zone_members     personas asignadas a una zona (manual o por geometría).
--  * directory.inmates    ficha de interno (preso) ligada a una persona.
--  * directory.pass_types catálogo configurable de tipos de pase.
--  * directory.passes     pase concedido a un interno, con zona autorizada.
--  * directory.personnel  personal de la fuerza: grado, unidad, teléfonos y
--                         residencia (punto) para consultas de proximidad.
--  * directory.oracle_connectors / oracle_runs
--                         extracción desde Oracle 11g hacia este esquema.

-- ---------------------------------------------------------------------------
-- Permisos nuevos
-- ---------------------------------------------------------------------------
INSERT INTO security.permissions (code, description) VALUES
  ('zones.read',       'Ver zonas y áreas dibujadas en el mapa'),
  ('zones.write',      'Crear, editar y eliminar zonas'),
  ('zones.assign',     'Asignar personas a zonas y recalcular por geometría'),
  ('personnel.read',   'Consultar personal de la fuerza (grado, unidad, teléfonos)'),
  ('personnel.write',  'Registrar y modificar personal de la fuerza'),
  ('passes.read',      'Consultar internos y pases'),
  ('passes.write',     'Conceder, modificar y cerrar pases'),
  ('oracle.sync',      'Gestionar conectores y sincronizaciones con Oracle')
ON CONFLICT (code) DO UPDATE SET description = EXCLUDED.description;

WITH grants(role_code, perm) AS (
  SELECT 'superadmin', code FROM security.permissions
    WHERE code IN ('zones.read','zones.write','zones.assign','personnel.read',
                   'personnel.write','passes.read','passes.write','oracle.sync')
  UNION ALL
  SELECT 'admin', code FROM security.permissions
    WHERE code IN ('zones.read','zones.write','zones.assign','personnel.read',
                   'personnel.write','passes.read','passes.write','oracle.sync')
  UNION ALL
  SELECT 'operator', unnest(ARRAY['zones.read','zones.write','zones.assign',
    'personnel.read','personnel.write','passes.read','passes.write'])
  UNION ALL
  SELECT 'consultant', unnest(ARRAY['zones.read','personnel.read','passes.read'])
  UNION ALL
  SELECT 'readonly', unnest(ARRAY['zones.read'])
)
INSERT INTO security.role_permissions (role_id, permission_code)
SELECT r.id, g.perm FROM grants g JOIN security.roles r ON r.code = g.role_code
ON CONFLICT DO NOTHING;

-- ---------------------------------------------------------------------------
-- Zonas: categorías y zonas dibujadas
-- ---------------------------------------------------------------------------
CREATE TABLE IF NOT EXISTS geo.zone_categories (
  id          smallint GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
  name        text NOT NULL CHECK (length(btrim(name)) BETWEEN 1 AND 80),
  description text NOT NULL DEFAULT '',
  color_hex   text NOT NULL DEFAULT '#0F6C81' CHECK (color_hex ~ '^#[0-9A-Fa-f]{6}$'),
  icon        text NOT NULL DEFAULT 'label' CHECK (length(icon) BETWEEN 1 AND 60),
  sort_order  integer NOT NULL DEFAULT 0,
  is_active   boolean NOT NULL DEFAULT true
);
CREATE INDEX IF NOT EXISTS zone_categories_order_idx ON geo.zone_categories (sort_order, id);

INSERT INTO geo.zone_categories (name, description, color_hex, icon, sort_order) VALUES
  ('Área de residencia autorizada', 'Zona dentro de la cual el interno debe permanecer durante el pase', '#2E7D32', 'home', 1),
  ('Zona de vigilancia', 'Área bajo observación de la fuerza', '#C62828', 'visibility', 2),
  ('Punto de control', 'Checkpoint o puesto fijo de control', '#EF8F00', 'control_camera', 3),
  ('Anotación', 'Etiqueta o referencia escrita sobre el mapa', '#6A1B9A', 'edit_note', 4)
ON CONFLICT DO NOTHING;

-- La geometría de la zona es SIEMPRE un polígono (el círculo se materializa
-- con ST_Buffer); las vértices originales se guardan en jsonb para que el
-- cliente las represente fielmente (círculo: centro + radio).
CREATE TABLE IF NOT EXISTS geo.zones (
  id           uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  name         text NOT NULL CHECK (length(btrim(name)) BETWEEN 1 AND 120),
  description  text CHECK (description IS NULL OR length(description) <= 2000),
  kind         text NOT NULL CHECK (kind IN ('circle','rectangle','polygon')),
  geom         geography(Polygon, 4326) NOT NULL,
  vertices     jsonb NOT NULL,
  center_lat   double precision,
  center_lon   double precision,
  radius_m     integer CHECK (radius_m IS NULL OR radius_m BETWEEN 5 AND 100000),
  label_text   text CHECK (label_text IS NULL OR length(label_text) <= 200),
  show_label   boolean NOT NULL DEFAULT true,
  category_id  smallint REFERENCES geo.zone_categories(id) ON DELETE SET NULL,
  color_hex    text CHECK (color_hex IS NULL OR color_hex ~ '^#[0-9A-Fa-f]{6}$'),
  fill_opacity numeric(3,2) NOT NULL DEFAULT 0.15 CHECK (fill_opacity BETWEEN 0 AND 1),
  stroke_width numeric(4,1) NOT NULL DEFAULT 2.0 CHECK (stroke_width BETWEEN 0.5 AND 10),
  is_active    boolean NOT NULL DEFAULT true,
  is_synthetic boolean NOT NULL DEFAULT false,
  data_source  text NOT NULL DEFAULT 'map_drawing' CHECK (length(data_source) BETWEEN 2 AND 120),
  created_by   uuid REFERENCES identity.users(id),
  updated_by   uuid REFERENCES identity.users(id),
  created_at   timestamptz NOT NULL DEFAULT now(),
  updated_at   timestamptz NOT NULL DEFAULT now(),
  CONSTRAINT circle_fields CHECK (
    kind <> 'circle' OR (center_lat IS NOT NULL AND center_lon IS NOT NULL AND radius_m IS NOT NULL)),
  CONSTRAINT polygon_needs_vertices CHECK (
    kind <> 'polygon' OR jsonb_typeof(vertices) = 'array' AND jsonb_array_length(vertices) >= 3),
  CONSTRAINT rectangle_needs_vertices CHECK (
    kind <> 'rectangle' OR jsonb_typeof(vertices) = 'array' AND jsonb_array_length(vertices) = 4),
  CONSTRAINT zone_in_cuba CHECK (
    ST_XMin(geom::geometry) BETWEEN -85.2 AND -74.0 AND
    ST_XMax(geom::geometry) BETWEEN -85.2 AND -74.0 AND
    ST_YMin(geom::geometry) BETWEEN 19.5 AND 23.6 AND
    ST_YMax(geom::geometry) BETWEEN 19.5 AND 23.6),
  CONSTRAINT zone_valid CHECK (ST_IsValid(geom::geometry))
);
CREATE INDEX IF NOT EXISTS zones_geom_gix ON geo.zones USING gist (geom);
CREATE INDEX IF NOT EXISTS zones_active_idx ON geo.zones (is_active);
CREATE INDEX IF NOT EXISTS zones_category_idx ON geo.zones (category_id);
CREATE INDEX IF NOT EXISTS zones_name_trgm ON geo.zones USING gin (name gin_trgm_ops);

DROP TRIGGER IF EXISTS zones_touch ON geo.zones;
CREATE TRIGGER zones_touch BEFORE UPDATE ON geo.zones
  FOR EACH ROW EXECUTE FUNCTION catalog.touch_updated_at();

COMMENT ON TABLE geo.zones IS
  'Áreas dibujadas sobre el mapa (círculo, rectángulo, polígono) con etiqueta y estilo.';

-- Personas asignadas a una zona: manual (elegidas por el operador) o por
-- geometría (recalculadas con la ubicación fija dentro del polígono).
CREATE TABLE IF NOT EXISTS geo.zone_members (
  zone_id    uuid NOT NULL REFERENCES geo.zones(id) ON DELETE CASCADE,
  person_id  uuid NOT NULL REFERENCES directory.persons(id) ON DELETE CASCADE,
  source     text NOT NULL DEFAULT 'manual' CHECK (source IN ('manual','geometry','import')),
  added_by   uuid REFERENCES identity.users(id),
  added_at   timestamptz NOT NULL DEFAULT now(),
  PRIMARY KEY (zone_id, person_id)
);
CREATE INDEX IF NOT EXISTS zone_members_person_idx ON geo.zone_members (person_id);

-- ---------------------------------------------------------------------------
-- Internos (presos) y pases
-- ---------------------------------------------------------------------------
CREATE TABLE IF NOT EXISTS directory.inmates (
  person_id   uuid PRIMARY KEY REFERENCES directory.persons(id) ON DELETE CASCADE,
  intern_code text UNIQUE CHECK (intern_code ~ '^[A-Z0-9][A-Z0-9/-]{2,31}$'),
  facility    text CHECK (facility IS NULL OR length(facility) <= 160),
  status      text CHECK (status IS NULL OR length(btrim(status)) BETWEEN 1 AND 60),
  risk_level  text CHECK (risk_level IS NULL OR length(btrim(risk_level)) BETWEEN 1 AND 40),
  cell_ref    text CHECK (cell_ref IS NULL OR length(cell_ref) <= 60),
  notes       text CHECK (notes IS NULL OR length(notes) <= 2000),
  is_active   boolean NOT NULL DEFAULT true,
  data_source text NOT NULL DEFAULT 'manual' CHECK (length(data_source) BETWEEN 2 AND 120),
  created_by  uuid REFERENCES identity.users(id),
  created_at  timestamptz NOT NULL DEFAULT now(),
  updated_at  timestamptz NOT NULL DEFAULT now()
);
CREATE INDEX IF NOT EXISTS inmates_facility_idx ON directory.inmates (facility);
CREATE INDEX IF NOT EXISTS inmates_active_idx ON directory.inmates (is_active);

DROP TRIGGER IF EXISTS inmates_touch ON directory.inmates;
CREATE TRIGGER inmates_touch BEFORE UPDATE ON directory.inmates
  FOR EACH ROW EXECUTE FUNCTION catalog.touch_updated_at();

CREATE TABLE IF NOT EXISTS directory.pass_types (
  id           smallint GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
  code         text NOT NULL UNIQUE CHECK (code ~ '^[a-z0-9_-]{2,40}$'),
  name         text NOT NULL CHECK (length(btrim(name)) BETWEEN 1 AND 80),
  description  text NOT NULL DEFAULT '',
  default_days integer NOT NULL DEFAULT 7 CHECK (default_days BETWEEN 1 AND 3650),
  color_hex    text NOT NULL DEFAULT '#1565C0' CHECK (color_hex ~ '^#[0-9A-Fa-f]{6}$'),
  is_active    boolean NOT NULL DEFAULT true
);

INSERT INTO directory.pass_types (code, name, description, default_days, color_hex) VALUES
  ('pase_ordinario', 'Pase ordinario', 'Salida ordinaria regulada por el régimen penitenciario', 7, '#1565C0'),
  ('pase_extraordinario', 'Pase extraordinario', 'Salida autorizada por motivo excepcional (salud, duelo, trabajo)', 3, '#6A1B9A'),
  ('libertad_condicional', 'Libertad condicional', 'Régimen de libertad condicional con ubicación fija', 30, '#2E7D32')
ON CONFLICT (code) DO UPDATE SET name = EXCLUDED.name, description = EXCLUDED.description,
  default_days = EXCLUDED.default_days, color_hex = EXCLUDED.color_hex;

-- El estado NO se almacena: se calcula por fecha (scheduled/active/expired) y
-- por las marcas de cierre (returned/cancelled). Así no hace falta un cron.
CREATE TABLE IF NOT EXISTS directory.passes (
  id                uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  person_id         uuid NOT NULL REFERENCES directory.persons(id) ON DELETE CASCADE,
  intern_id         uuid NOT NULL REFERENCES directory.inmates(person_id) ON DELETE CASCADE,
  pass_type_id      smallint REFERENCES directory.pass_types(id) ON DELETE SET NULL,
  facility          text CHECK (facility IS NULL OR length(facility) <= 160),
  starts_at         timestamptz NOT NULL,
  ends_at           timestamptz NOT NULL CHECK (ends_at > starts_at),
  returned_at       timestamptz,
  cancelled_at      timestamptz,
  authorized_zone_id uuid REFERENCES geo.zones(id) ON DELETE SET NULL,
  authorized_address text CHECK (authorized_address IS NULL OR length(authorized_address) <= 300),
  notes             text CHECK (notes IS NULL OR length(notes) <= 2000),
  external_ref      text UNIQUE CHECK (external_ref IS NULL OR length(external_ref) <= 80),
  data_source       text NOT NULL DEFAULT 'manual' CHECK (length(data_source) BETWEEN 2 AND 120),
  created_by        uuid REFERENCES identity.users(id),
  created_at        timestamptz NOT NULL DEFAULT now(),
  updated_at        timestamptz NOT NULL DEFAULT now(),
  -- Un pase devuelto o cancelado no puede reabrirse cambiando fechas.
  CONSTRAINT closed_consistency CHECK (
    (returned_at IS NULL OR cancelled_at IS NULL)
    AND (returned_at IS NULL OR returned_at >= starts_at)
    AND (cancelled_at IS NULL OR cancelled_at >= starts_at))
);
CREATE INDEX IF NOT EXISTS passes_person_idx ON directory.passes (person_id);
CREATE INDEX IF NOT EXISTS passes_window_idx ON directory.passes (starts_at, ends_at)
  WHERE returned_at IS NULL AND cancelled_at IS NULL;
CREATE INDEX IF NOT EXISTS passes_zone_idx ON directory.passes (authorized_zone_id);

DROP TRIGGER IF EXISTS passes_touch ON directory.passes;
CREATE TRIGGER passes_touch BEFORE UPDATE ON directory.passes
  FOR EACH ROW EXECUTE FUNCTION catalog.touch_updated_at();

COMMENT ON FUNCTION catalog.touch_updated_at() IS 'Mantiene updated_at en cada UPDATE (definida en 0001).';

-- ---------------------------------------------------------------------------
-- Personal de la fuerza (militares): residencia con punto, teléfonos y área
-- asignada. La proximidad «¿quién vive cerca de este preso?» usa ST_DWithin.
-- ---------------------------------------------------------------------------
CREATE TABLE IF NOT EXISTS directory.personnel (
  id               uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  code             text UNIQUE CHECK (code IS NULL OR code ~ '^[A-Z0-9][A-Z0-9-]{2,31}$'),
  full_name        text NOT NULL CHECK (length(btrim(full_name)) BETWEEN 3 AND 160),
  full_name_norm   text GENERATED ALWAYS AS (catalog.normalize_text(full_name)) STORED,
  rank             text CHECK (rank IS NULL OR length(btrim(rank)) BETWEEN 1 AND 80),
  unit             text CHECK (unit IS NULL OR length(btrim(unit)) <= 160),
  phone            text CHECK (phone IS NULL OR phone ~ '^[0-9 +()-]{5,25}$'),
  phone_alt        text CHECK (phone_alt IS NULL OR phone_alt ~ '^[0-9 +()-]{5,25}$'),
  address_text     text CHECK (address_text IS NULL OR length(address_text) <= 300),
  geom             geography(Point, 4326),
  municipality_id  integer REFERENCES geo.municipalities(id) ON DELETE SET NULL,
  zone_id          uuid REFERENCES geo.zones(id) ON DELETE SET NULL,
  role_note        text CHECK (role_note IS NULL OR length(role_note) <= 200),
  is_active        boolean NOT NULL DEFAULT true,
  is_synthetic     boolean NOT NULL DEFAULT false,
  data_source      text NOT NULL DEFAULT 'manual' CHECK (length(data_source) BETWEEN 2 AND 120),
  external_ref     text UNIQUE CHECK (external_ref IS NULL OR length(external_ref) <= 80),
  created_by       uuid REFERENCES identity.users(id),
  created_at       timestamptz NOT NULL DEFAULT now(),
  updated_at       timestamptz NOT NULL DEFAULT now(),
  CONSTRAINT personnel_in_cuba CHECK (
    geom IS NULL OR (ST_X(geom::geometry) BETWEEN -85.2 AND -74.0
                     AND ST_Y(geom::geometry) BETWEEN 19.5 AND 23.6))
);
CREATE INDEX IF NOT EXISTS personnel_geom_gix ON directory.personnel USING gist (geom);
CREATE INDEX IF NOT EXISTS personnel_name_trgm ON directory.personnel USING gin (full_name_norm gin_trgm_ops);
CREATE INDEX IF NOT EXISTS personnel_zone_idx ON directory.personnel (zone_id);
CREATE INDEX IF NOT EXISTS personnel_muni_idx ON directory.personnel (municipality_id);

DROP TRIGGER IF EXISTS personnel_touch ON directory.personnel;
CREATE TRIGGER personnel_touch BEFORE UPDATE ON directory.personnel
  FOR EACH ROW EXECUTE FUNCTION catalog.touch_updated_at();

-- ---------------------------------------------------------------------------
-- Conectores Oracle 11g: configuración de extracción y bitácora de corridas.
-- La contraseña se guarda CIFRADA (AES-256-GCM con clave del servidor); el
-- API nunca la devuelve al cliente.
-- ---------------------------------------------------------------------------
CREATE TABLE IF NOT EXISTS directory.oracle_connectors (
  id            uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  name          text NOT NULL UNIQUE CHECK (length(btrim(name)) BETWEEN 2 AND 120),
  host          text NOT NULL CHECK (length(host) BETWEEN 1 AND 255),
  port          integer NOT NULL DEFAULT 1521 CHECK (port BETWEEN 1 AND 65535),
  service_kind  text NOT NULL DEFAULT 'service' CHECK (service_kind IN ('service','sid')),
  service_name  text NOT NULL CHECK (length(btrim(service_name)) BETWEEN 1 AND 64),
  username      text NOT NULL CHECK (length(btrim(username)) BETWEEN 1 AND 64),
  password_cipher text NOT NULL CHECK (length(password_cipher) BETWEEN 16 AND 4096),
  thick_mode    boolean NOT NULL DEFAULT false,
  connect_extra jsonb NOT NULL DEFAULT '{}'::jsonb,
  mappings      jsonb NOT NULL DEFAULT '[]'::jsonb,
  enabled       boolean NOT NULL DEFAULT true,
  last_run_at   timestamptz,
  last_status   text CHECK (last_status IS NULL OR last_status IN ('ok','error','partial')),
  created_by    uuid REFERENCES identity.users(id),
  created_at    timestamptz NOT NULL DEFAULT now(),
  updated_at    timestamptz NOT NULL DEFAULT now()
);

DROP TRIGGER IF EXISTS oracle_connectors_touch ON directory.oracle_connectors;
CREATE TRIGGER oracle_connectors_touch BEFORE UPDATE ON directory.oracle_connectors
  FOR EACH ROW EXECUTE FUNCTION catalog.touch_updated_at();

CREATE TABLE IF NOT EXISTS directory.oracle_runs (
  id            uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  connector_id  uuid NOT NULL REFERENCES directory.oracle_connectors(id) ON DELETE CASCADE,
  started_at    timestamptz NOT NULL DEFAULT now(),
  finished_at   timestamptz,
  dry_run       boolean NOT NULL DEFAULT false,
  status        text NOT NULL DEFAULT 'running' CHECK (status IN ('running','ok','partial','error')),
  persons_upserted  integer NOT NULL DEFAULT 0,
  inmates_upserted  integer NOT NULL DEFAULT 0,
  personnel_upserted integer NOT NULL DEFAULT 0,
  passes_upserted   integer NOT NULL DEFAULT 0,
  rows_read     integer NOT NULL DEFAULT 0,
  rows_skipped  integer NOT NULL DEFAULT 0,
  error_text    text,
  triggered_by  uuid REFERENCES identity.users(id)
);
CREATE INDEX IF NOT EXISTS oracle_runs_connector_idx ON directory.oracle_runs (connector_id, started_at DESC);

-- ---------------------------------------------------------------------------
-- Configuración inicial (todo editable desde Administración › Configuración)
-- ---------------------------------------------------------------------------
INSERT INTO catalog.system_settings (key, value, description) VALUES
  ('personnel.near_radius_m', '5000',
   'Radio por defecto para buscar personal de la fuerza cercano a un punto o preso (m)')
ON CONFLICT (key) DO NOTHING;

INSERT INTO catalog.system_settings (key, value, description) VALUES
  ('personnel.max_results', '50',
   'Máximo de resultados en consultas de personal cercano')
ON CONFLICT (key) DO NOTHING;

INSERT INTO catalog.system_settings (key, value, description) VALUES
  ('passes.default_days', '7', 'Duración por defecto de un pase nuevo (días)')
ON CONFLICT (key) DO NOTHING;

INSERT INTO catalog.system_settings (key, value, description) VALUES
  ('passes.max_active_per_person', '1',
   'Máximo de pases activos simultáneos por interno')
ON CONFLICT (key) DO NOTHING;

INSERT INTO catalog.system_settings (key, value, description) VALUES
  ('passes.marker_icon', '{"icon":"local_police","colorHex":"#C62828","size":30}',
   'Marcador de interno en pase activo: icono, color y tamaño')
ON CONFLICT (key) DO NOTHING;

INSERT INTO catalog.system_settings (key, value, description) VALUES
  ('personnel.marker_icon', '{"icon":"shield","colorHex":"#0F6C81","size":28}',
   'Marcador de personal de la fuerza: icono, color y tamaño')
ON CONFLICT (key) DO NOTHING;

INSERT INTO catalog.system_settings (key, value, description) VALUES
  ('zones.palette', '["#1565C0","#C62828","#2E7D32","#EF8F00","#6A1B9A","#0F6C81","#37474F","#AD1457"]',
   'Paleta de colores para zonas nuevas')
ON CONFLICT (key) DO NOTHING;

INSERT INTO catalog.system_settings (key, value, description) VALUES
  ('zones.max_radius_m', '100000',
   'Radio máximo permitido al dibujar un círculo (m)')
ON CONFLICT (key) DO NOTHING;

INSERT INTO catalog.system_settings (key, value, description) VALUES
  ('zones.max_results', '2000',
   'Máximo de personas listadas dentro de una zona')
ON CONFLICT (key) DO NOTHING;

INSERT INTO catalog.system_settings (key, value, description) VALUES
  ('inmate.statuses', '["Internado","En pase","Excarcelado","Libertad condicional"]',
   'Estados posibles de un interno (lista configurable)')
ON CONFLICT (key) DO NOTHING;

INSERT INTO catalog.system_settings (key, value, description) VALUES
  ('inmate.risk_levels', '["Bajo","Medio","Alto","Máximo"]',
   'Niveles de riesgo de un interno (lista configurable)')
ON CONFLICT (key) DO NOTHING;

INSERT INTO catalog.system_settings (key, value, description) VALUES
  ('oracle.row_cap', '20000',
   'Máximo de filas leídas por tabla en cada corrida de sincronización Oracle')
ON CONFLICT (key) DO NOTHING;

INSERT INTO catalog.system_settings (key, value, description) VALUES
  ('oracle.timeout_ms', '30000',
   'Tiempo máximo de espera de cada consulta Oracle (ms)')
ON CONFLICT (key) DO NOTHING;

-- ---------------------------------------------------------------------------
-- Privilegios del rol de aplicación (lexair_api)
-- ---------------------------------------------------------------------------
GRANT SELECT, INSERT, UPDATE, DELETE ON geo.zone_categories, geo.zones, geo.zone_members,
  directory.inmates, directory.pass_types, directory.passes, directory.personnel,
  directory.oracle_connectors, directory.oracle_runs TO lexair_api;
GRANT USAGE ON ALL SEQUENCES IN SCHEMA directory, geo TO lexair_api;
