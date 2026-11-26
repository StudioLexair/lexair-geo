-- Búsqueda potente: clave fonética para nombres en español (b/v, c/s/z,
-- ll/y, j/y, h muda, qu→k…). Iguala nombres escritos «de oído».
CREATE OR REPLACE FUNCTION catalog.fonema(t text) RETURNS text
  LANGUAGE sql IMMUTABLE PARALLEL SAFE AS $fn$
  SELECT regexp_replace(
           regexp_replace(
             replace(replace(replace(replace(replace(replace(replace(replace(replace(replace(replace(replace(replace(coalesce(catalog.normalize_text(t), ''), 'll', 'y'), 'qu', 'k'), 'ce', 'se'), 'ci', 'se'), 'ge', 'je'), 'gi', 'je'), 'v', 'b'), 'z', 's'), 'j', 'y'), 'h', ''), 'w', 'b'), 'x', 'ks'), 'c', 'k'),
             '[^a-z]', '', 'g'),
           '(.)\1+', '\1', 'g')
$fn$;

ALTER TABLE directory.persons ADD COLUMN IF NOT EXISTS full_name_fonema text
  GENERATED ALWAYS AS (catalog.fonema(given_names || ' ' || family_names)) STORED;
CREATE INDEX IF NOT EXISTS persons_fonema_idx ON directory.persons (full_name_fonema);

-- El personal también se busca por fonema.
ALTER TABLE directory.personnel ADD COLUMN IF NOT EXISTS full_name_fonema text
  GENERATED ALWAYS AS (catalog.fonema(full_name)) STORED;
CREATE INDEX IF NOT EXISTS personnel_fonema_idx ON directory.personnel (full_name_fonema);
