-- LEXAIR GEO · 0006 · Rol de aplicación con privilegios mínimos.
-- El instalador crea un usuario LOGIN (lexair_api_login) miembro de lexair_api
-- con contraseña generada localmente. El API nunca usa el superusuario.

DO $$
BEGIN
  IF NOT EXISTS (SELECT 1 FROM pg_roles WHERE rolname = 'lexair_api') THEN
    CREATE ROLE lexair_api NOLOGIN;
  END IF;
END
$$;

GRANT USAGE ON SCHEMA identity, directory, geo, catalog, security, audit TO lexair_api;

GRANT SELECT ON ALL TABLES IN SCHEMA security, catalog, geo, directory, identity TO lexair_api;
GRANT INSERT, UPDATE ON identity.users TO lexair_api;
GRANT INSERT, UPDATE ON security.sessions TO lexair_api;
GRANT INSERT, UPDATE ON directory.persons, directory.import_jobs TO lexair_api;
GRANT INSERT, UPDATE, DELETE ON directory.person_memberships TO lexair_api;
GRANT INSERT, UPDATE, DELETE ON geo.person_locations TO lexair_api;
GRANT INSERT, UPDATE, DELETE ON geo.addresses, geo.street_aliases, geo.points_of_interest TO lexair_api;
GRANT UPDATE ON catalog.system_settings TO lexair_api;
-- Auditoría: solo inserción y lectura.
GRANT SELECT, INSERT ON audit.audit_logs TO lexair_api;
GRANT USAGE ON ALL SEQUENCES IN SCHEMA identity, directory, geo, audit, security TO lexair_api;
GRANT EXECUTE ON ALL FUNCTIONS IN SCHEMA catalog TO lexair_api;
