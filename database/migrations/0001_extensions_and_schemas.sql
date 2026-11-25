-- LEXAIR GEO · 0001 · Extensiones, esquemas y funciones de normalización
-- Todas las sentencias son idempotentes en la medida de lo posible; el runner
-- registra cada migración en public.schema_migrations con su SHA-256.

CREATE EXTENSION IF NOT EXISTS postgis;
CREATE EXTENSION IF NOT EXISTS pg_trgm;
CREATE EXTENSION IF NOT EXISTS unaccent;

CREATE SCHEMA IF NOT EXISTS identity;
CREATE SCHEMA IF NOT EXISTS directory;
CREATE SCHEMA IF NOT EXISTS geo;
CREATE SCHEMA IF NOT EXISTS catalog;
CREATE SCHEMA IF NOT EXISTS security;
CREATE SCHEMA IF NOT EXISTS audit;

-- unaccent() es STABLE; para poder usarla en columnas generadas e índices se
-- envuelve fijando explícitamente el diccionario (patrón documentado en PG).
CREATE OR REPLACE FUNCTION catalog.normalize_text(input text)
RETURNS text
LANGUAGE sql
IMMUTABLE
PARALLEL SAFE
AS $$
  SELECT btrim(
    regexp_replace(
      regexp_replace(
        lower(public.unaccent('public.unaccent'::regdictionary, coalesce(input, ''))),
        '[^a-z0-9#/-]+', ' ', 'g'
      ),
      '\s+', ' ', 'g'
    )
  )
$$;

COMMENT ON FUNCTION catalog.normalize_text(text) IS
  'Minúsculas, sin tildes, sin signos; base de toda búsqueda textual local.';

-- Marca de tiempo automática para columnas updated_at.
CREATE OR REPLACE FUNCTION catalog.touch_updated_at()
RETURNS trigger
LANGUAGE plpgsql
AS $$
BEGIN
  NEW.updated_at := now();
  RETURN NEW;
END;
$$;
