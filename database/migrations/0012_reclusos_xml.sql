-- El libro de reclusos en pase (SpreadsheetML del registro penitenciario)
-- se importa como un tipo propio de trabajo.
ALTER TABLE directory.import_jobs DROP CONSTRAINT import_jobs_kind_check;
ALTER TABLE directory.import_jobs
  ADD CONSTRAINT import_jobs_kind_check
  CHECK (kind IN ('persons_csv', 'reclusos_xml'));
