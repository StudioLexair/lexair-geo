-- LEXAIR GEO · 0007 · Permisos que faltaban al rol lexair_api.
-- Detectados al ejecutar las pruebas de integración con un rol de privilegios
-- mínimos (antes se usaba el propietario y ocultaba el problema):
--  * Estado del servidor lee la última migración aplicada.
--  * El superadministrador redefine los permisos de un rol.
--  * La configuración se guarda con INSERT ... ON CONFLICT (claves nuevas).
GRANT SELECT ON public.schema_migrations TO lexair_api;
GRANT INSERT, DELETE ON security.role_permissions TO lexair_api;
GRANT INSERT ON catalog.system_settings TO lexair_api;
