-- LEXAIR GEO · 0004 · Personas, grupos, membresías y ubicación fija

CREATE TABLE IF NOT EXISTS directory.persons (
  id                  uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  code                text NOT NULL UNIQUE CHECK (code ~ '^[A-Z0-9][A-Z0-9-]{2,31}$'),
  given_names         text NOT NULL CHECK (length(btrim(given_names)) BETWEEN 1 AND 120),
  family_names        text NOT NULL CHECK (length(btrim(family_names)) BETWEEN 1 AND 120),
  phone               text CHECK (phone IS NULL OR phone ~ '^[0-9 +()-]{5,25}$'),
  notes               text CHECK (notes IS NULL OR length(notes) <= 2000),
  is_active           boolean NOT NULL DEFAULT true,
  is_synthetic        boolean NOT NULL DEFAULT false,
  visibility          text NOT NULL DEFAULT 'normal' CHECK (visibility IN ('normal','restricted')),
  consent_status      text NOT NULL DEFAULT 'pending'
                      CHECK (consent_status IN ('granted','not_required','pending','revoked')),
  consent_recorded_at timestamptz,
  data_source         text NOT NULL CHECK (length(data_source) BETWEEN 2 AND 120),
  retention_until     date,
  created_at          timestamptz NOT NULL DEFAULT now(),
  updated_at          timestamptz NOT NULL DEFAULT now(),
  created_by          uuid REFERENCES identity.users(id),
  deactivated_at      timestamptz,
  deactivated_by      uuid REFERENCES identity.users(id),
  full_name_norm      text GENERATED ALWAYS AS
                        (catalog.normalize_text(given_names || ' ' || family_names)) STORED,
  CHECK (is_active OR deactivated_at IS NOT NULL),
  CHECK (consent_status <> 'granted' OR consent_recorded_at IS NOT NULL)
);
CREATE INDEX IF NOT EXISTS persons_name_trgm ON directory.persons USING gin (full_name_norm gin_trgm_ops);
CREATE INDEX IF NOT EXISTS persons_active_idx ON directory.persons (is_active);
CREATE INDEX IF NOT EXISTS persons_order_idx ON directory.persons (family_names, given_names, id);

DROP TRIGGER IF EXISTS persons_touch ON directory.persons;
CREATE TRIGGER persons_touch BEFORE UPDATE ON directory.persons
  FOR EACH ROW EXECUTE FUNCTION catalog.touch_updated_at();

CREATE TABLE IF NOT EXISTS directory.person_groups (
  id              smallint PRIMARY KEY,
  code            text NOT NULL UNIQUE CHECK (code IN ('A','B')),
  name            text NOT NULL,
  description     text NOT NULL,
  read_permission text NOT NULL REFERENCES security.permissions(code),
  color_hex       text NOT NULL CHECK (color_hex ~ '^#[0-9A-F]{6}$')
);

INSERT INTO directory.person_groups (id, code, name, description, read_permission, color_hex) VALUES
  (1, 'A', 'Grupo A', 'Directorio incorporado mediante administración o importación', 'groups.a.read', '#1565C0'),
  (2, 'B', 'Grupo B', 'Registros propios de la aplicación', 'groups.b.read', '#C62828')
ON CONFLICT (id) DO UPDATE SET name = EXCLUDED.name, description = EXCLUDED.description,
  read_permission = EXCLUDED.read_permission, color_hex = EXCLUDED.color_hex;

-- Una identidad, varias membresías: nunca se duplica la persona.
CREATE TABLE IF NOT EXISTS directory.person_memberships (
  person_id uuid NOT NULL REFERENCES directory.persons(id) ON DELETE CASCADE,
  group_id  smallint NOT NULL REFERENCES directory.person_groups(id),
  source    text NOT NULL DEFAULT 'manual' CHECK (source IN ('manual','import','migration')),
  joined_at timestamptz NOT NULL DEFAULT now(),
  added_by  uuid REFERENCES identity.users(id),
  PRIMARY KEY (person_id, group_id)
);
CREATE INDEX IF NOT EXISTS memberships_group_idx ON directory.person_memberships (group_id, person_id);

-- Ubicación FIJA: una fila por persona, sin historial de trayectorias.
CREATE TABLE IF NOT EXISTS geo.person_locations (
  person_id          uuid PRIMARY KEY REFERENCES directory.persons(id) ON DELETE CASCADE,
  geom               geography(Point, 4326) NOT NULL,
  srid               integer NOT NULL DEFAULT 4326 CHECK (srid = 4326),
  address_text       text CHECK (address_text IS NULL OR length(address_text) <= 300),
  municipality_id    integer REFERENCES geo.municipalities(id) ON DELETE SET NULL,
  locality_id        integer REFERENCES geo.localities(id) ON DELETE SET NULL,
  coord_source       text NOT NULL CHECK (coord_source IN ('manual_coordinates','map_pick',
                       'geocoded_address','gps_once','admin_correction','synthetic')),
  precision_level    text NOT NULL DEFAULT 'unverified' CHECK (precision_level IN
                       ('exact_verified','high','approximate','general_area','unverified')),
  address_granularity text NOT NULL DEFAULT 'unknown' CHECK (address_granularity IN
                       ('dwelling','street','locality','municipality','unknown')),
  validation_status  text NOT NULL DEFAULT 'pending'
                       CHECK (validation_status IN ('pending','validated','rejected')),
  geocode_confidence numeric(4,3) CHECK (geocode_confidence BETWEEN 0 AND 1),
  updated_at         timestamptz NOT NULL DEFAULT now(),
  updated_by         uuid REFERENCES identity.users(id),
  verified_at        timestamptz,
  verified_by        uuid REFERENCES identity.users(id),
  address_norm       text GENERATED ALWAYS AS (catalog.normalize_text(address_text)) STORED,
  -- Envolvente amplia de Cuba: rechaza coordenadas imposibles o invertidas.
  CONSTRAINT person_locations_in_cuba CHECK (
    ST_X(geom::geometry) BETWEEN -85.2 AND -74.0 AND ST_Y(geom::geometry) BETWEEN 19.5 AND 23.6),
  CONSTRAINT exact_requires_verification CHECK (
    precision_level <> 'exact_verified' OR (validation_status = 'validated' AND verified_by IS NOT NULL)),
  CONSTRAINT verified_consistency CHECK (
    validation_status <> 'validated' OR verified_at IS NOT NULL)
);
CREATE INDEX IF NOT EXISTS person_locations_geom_gix ON geo.person_locations USING gist (geom);
CREATE INDEX IF NOT EXISTS person_locations_muni_idx ON geo.person_locations (municipality_id);
CREATE INDEX IF NOT EXISTS person_locations_addr_trgm
  ON geo.person_locations USING gin (address_norm gin_trgm_ops);
