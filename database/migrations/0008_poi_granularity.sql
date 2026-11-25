-- LEXAIR GEO · 0008 · Granularidad «poi» para ubicaciones fijadas en un punto de interés.
-- El geocodificador devuelve resultados de tipo POI (escuela, policlínico…); al
-- guardarlos como ubicación no deben degradarse a «unknown».
ALTER TABLE geo.person_locations DROP CONSTRAINT IF EXISTS person_locations_address_granularity_check;
ALTER TABLE geo.person_locations ADD CONSTRAINT person_locations_address_granularity_check
  CHECK (address_granularity IN ('dwelling','poi','street','locality','municipality','unknown'));
