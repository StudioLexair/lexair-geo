-- Fotografía de la persona (una por persona, máx. 3 MB, jpeg/png/webp).
-- Va en la propia base para que las copias de seguridad la incluyan.
CREATE TABLE IF NOT EXISTS directory.person_photos (
  person_id  uuid PRIMARY KEY REFERENCES directory.persons(id) ON DELETE CASCADE,
  mime       text NOT NULL CHECK (mime IN ('image/jpeg','image/png','image/webp')),
  bytes      bytea NOT NULL CHECK (octet_length(bytes) BETWEEN 64 AND 3145728),
  sha256     char(64) NOT NULL,
  updated_at timestamptz NOT NULL DEFAULT now(),
  updated_by uuid REFERENCES identity.users(id)
);
GRANT SELECT, INSERT, UPDATE, DELETE ON directory.person_photos TO lexair_api;
