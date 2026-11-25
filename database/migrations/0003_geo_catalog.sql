-- LEXAIR GEO · 0003 · Catálogo geográfico local (municipios, localidades,
-- direcciones, alias de calles y puntos de interés).
-- Los datos reales proceden de OpenStreetMap (ODbL) mediante scripts/maps.
-- Nada en esta migración inserta geografía: no se inventan límites ni calles.

CREATE TABLE IF NOT EXISTS geo.data_sources (
  code         text PRIMARY KEY CHECK (code ~ '^[a-z0-9_]{2,40}$'),
  name         text NOT NULL,
  license      text NOT NULL,
  attribution  text NOT NULL,
  extract_date timestamptz,
  sha256       text CHECK (sha256 IS NULL OR sha256 ~ '^[0-9a-f]{64}$'),
  is_synthetic boolean NOT NULL DEFAULT false,
  imported_at  timestamptz NOT NULL DEFAULT now()
);

CREATE TABLE IF NOT EXISTS geo.municipalities (
  id          integer GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
  code        text NOT NULL UNIQUE CHECK (code ~ '^[a-z0-9_-]{2,60}$'),
  name        text NOT NULL,
  province    text NOT NULL DEFAULT 'Villa Clara',
  osm_id      bigint UNIQUE,
  boundary    geometry(MultiPolygon, 4326),
  source_code text NOT NULL REFERENCES geo.data_sources(code),
  name_norm   text GENERATED ALWAYS AS (catalog.normalize_text(name)) STORED
);
CREATE INDEX IF NOT EXISTS municipalities_boundary_gix ON geo.municipalities USING gist (boundary);
CREATE INDEX IF NOT EXISTS municipalities_name_trgm ON geo.municipalities USING gin (name_norm gin_trgm_ops);

CREATE TABLE IF NOT EXISTS geo.localities (
  id              integer GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
  municipality_id integer REFERENCES geo.municipalities(id) ON DELETE SET NULL,
  name            text NOT NULL CHECK (length(name) BETWEEN 1 AND 160),
  kind            text NOT NULL CHECK (kind IN ('city','town','village','hamlet',
                    'suburb','neighbourhood','reparto','quarter','locality','other')),
  centroid        geography(Point, 4326) NOT NULL,
  osm_id          text UNIQUE,
  source_code     text NOT NULL REFERENCES geo.data_sources(code),
  name_norm       text GENERATED ALWAYS AS (catalog.normalize_text(name)) STORED
);
CREATE INDEX IF NOT EXISTS localities_centroid_gix ON geo.localities USING gist (centroid);
CREATE INDEX IF NOT EXISTS localities_name_trgm ON geo.localities USING gin (name_norm gin_trgm_ops);

-- addresses: tramos de calle (granularity = street), viviendas con número
-- (granularity = dwelling) y direcciones creadas por administración.
CREATE TABLE IF NOT EXISTS geo.addresses (
  id              bigint GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
  street_name     text NOT NULL CHECK (length(street_name) BETWEEN 1 AND 200),
  house_number    text CHECK (house_number IS NULL OR length(house_number) <= 20),
  locality_id     integer REFERENCES geo.localities(id) ON DELETE SET NULL,
  municipality_id integer REFERENCES geo.municipalities(id) ON DELETE SET NULL,
  granularity     text NOT NULL CHECK (granularity IN ('dwelling','street')),
  geom            geography(Point, 4326) NOT NULL,
  osm_id          text,
  source_code     text NOT NULL REFERENCES geo.data_sources(code),
  created_at      timestamptz NOT NULL DEFAULT now(),
  search_norm     text GENERATED ALWAYS AS
                    (catalog.normalize_text(street_name || ' ' || coalesce(house_number, ''))) STORED,
  CHECK (granularity = 'street' OR house_number IS NOT NULL)
);
CREATE INDEX IF NOT EXISTS addresses_geom_gix ON geo.addresses USING gist (geom);
CREATE INDEX IF NOT EXISTS addresses_search_trgm ON geo.addresses USING gin (search_norm gin_trgm_ops);
CREATE INDEX IF NOT EXISTS addresses_muni_idx ON geo.addresses (municipality_id);
CREATE UNIQUE INDEX IF NOT EXISTS addresses_osm_uq ON geo.addresses (osm_id) WHERE osm_id IS NOT NULL;

CREATE TABLE IF NOT EXISTS geo.street_aliases (
  id              integer GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
  alias           text NOT NULL CHECK (length(alias) BETWEEN 1 AND 200),
  street_name     text NOT NULL CHECK (length(street_name) BETWEEN 1 AND 200),
  municipality_id integer REFERENCES geo.municipalities(id) ON DELETE CASCADE,
  created_by      uuid REFERENCES identity.users(id),
  created_at      timestamptz NOT NULL DEFAULT now(),
  alias_norm      text GENERATED ALWAYS AS (catalog.normalize_text(alias)) STORED,
  street_norm     text GENERATED ALWAYS AS (catalog.normalize_text(street_name)) STORED
);
CREATE UNIQUE INDEX IF NOT EXISTS street_aliases_uq
  ON geo.street_aliases (alias_norm, street_norm, coalesce(municipality_id, 0));
CREATE INDEX IF NOT EXISTS street_aliases_trgm ON geo.street_aliases USING gin (alias_norm gin_trgm_ops);

CREATE TABLE IF NOT EXISTS geo.points_of_interest (
  id              bigint GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
  name            text NOT NULL CHECK (length(name) BETWEEN 1 AND 200),
  category        text NOT NULL CHECK (length(category) BETWEEN 1 AND 60),
  municipality_id integer REFERENCES geo.municipalities(id) ON DELETE SET NULL,
  geom            geography(Point, 4326) NOT NULL,
  osm_id          text UNIQUE,
  source_code     text NOT NULL REFERENCES geo.data_sources(code),
  name_norm       text GENERATED ALWAYS AS (catalog.normalize_text(name)) STORED
);
CREATE INDEX IF NOT EXISTS poi_geom_gix ON geo.points_of_interest USING gist (geom);
CREATE INDEX IF NOT EXISTS poi_name_trgm ON geo.points_of_interest USING gin (name_norm gin_trgm_ops);

-- Fuente para datos introducidos por la administración local.
INSERT INTO geo.data_sources (code, name, license, attribution, is_synthetic)
VALUES ('admin_local', 'Correcciones administrativas locales', 'Interno',
        'Studio Lexair / administración local', false)
ON CONFLICT (code) DO NOTHING;
