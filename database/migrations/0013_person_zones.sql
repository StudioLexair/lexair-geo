-- Campos organizativos de la persona: CDR y zona de defensa.
-- Se usan en el importador del libro y en la edición manual de fichas.
ALTER TABLE directory.persons ADD COLUMN IF NOT EXISTS cdr text
  CHECK (cdr IS NULL OR length(cdr) <= 120);
ALTER TABLE directory.persons ADD COLUMN IF NOT EXISTS defense_zone text
  CHECK (defense_zone IS NULL OR length(defense_zone) <= 120);
