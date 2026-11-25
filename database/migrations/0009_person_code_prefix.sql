-- LEXAIR GEO · 0009 · Búsqueda por prefijo de código de persona ("SYN-00012…").
-- text_pattern_ops permite LIKE 'prefijo%' con índice sea cual sea la intercalación.
CREATE INDEX IF NOT EXISTS persons_code_prefix_idx ON directory.persons (code text_pattern_ops);
