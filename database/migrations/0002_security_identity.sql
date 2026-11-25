-- LEXAIR GEO · 0002 · Roles, permisos, usuarios y sesiones

CREATE TABLE IF NOT EXISTS security.permissions (
  code        text PRIMARY KEY CHECK (code ~ '^[a-z][a-z0-9_.]{2,63}$'),
  description text NOT NULL
);

CREATE TABLE IF NOT EXISTS security.roles (
  id          smallint GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
  code        text NOT NULL UNIQUE CHECK (code ~ '^[a-z_]{3,32}$'),
  name        text NOT NULL,
  rank        smallint NOT NULL CHECK (rank BETWEEN 1 AND 100),
  description text NOT NULL DEFAULT ''
);

CREATE TABLE IF NOT EXISTS security.role_permissions (
  role_id         smallint NOT NULL REFERENCES security.roles(id) ON DELETE CASCADE,
  permission_code text NOT NULL REFERENCES security.permissions(code) ON DELETE CASCADE,
  PRIMARY KEY (role_id, permission_code)
);

CREATE TABLE IF NOT EXISTS identity.users (
  id                   uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  username             text NOT NULL CHECK (username ~ '^[a-z0-9._-]{3,40}$'),
  display_name         text NOT NULL CHECK (length(display_name) BETWEEN 1 AND 120),
  password_hash        text NOT NULL CHECK (password_hash LIKE '$argon2id$%'),
  role_id              smallint NOT NULL REFERENCES security.roles(id),
  is_active            boolean NOT NULL DEFAULT true,
  must_change_password boolean NOT NULL DEFAULT true,
  failed_attempts      integer NOT NULL DEFAULT 0 CHECK (failed_attempts >= 0),
  locked_until         timestamptz,
  last_login_at        timestamptz,
  created_at           timestamptz NOT NULL DEFAULT now(),
  updated_at           timestamptz NOT NULL DEFAULT now(),
  created_by           uuid REFERENCES identity.users(id)
);
CREATE UNIQUE INDEX IF NOT EXISTS users_username_uq ON identity.users (lower(username));

DROP TRIGGER IF EXISTS users_touch ON identity.users;
CREATE TRIGGER users_touch BEFORE UPDATE ON identity.users
  FOR EACH ROW EXECUTE FUNCTION catalog.touch_updated_at();

-- Sesiones revocables: el JWT solo transporta el id de sesión.
CREATE TABLE IF NOT EXISTS security.sessions (
  id          uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  user_id     uuid NOT NULL REFERENCES identity.users(id) ON DELETE CASCADE,
  created_at  timestamptz NOT NULL DEFAULT now(),
  expires_at  timestamptz NOT NULL,
  revoked_at  timestamptz,
  client_kind text NOT NULL DEFAULT 'unknown'
              CHECK (client_kind IN ('windows', 'web', 'legacy_web', 'api', 'unknown')),
  ip          inet,
  CHECK (expires_at > created_at)
);
CREATE INDEX IF NOT EXISTS sessions_user_idx ON security.sessions (user_id) WHERE revoked_at IS NULL;

-- Catálogo de permisos ---------------------------------------------------
INSERT INTO security.permissions (code, description) VALUES
  ('persons.read',          'Consultar personas'),
  ('persons.write',         'Crear, editar y desactivar personas'),
  ('groups.a.read',         'Consultar Grupo A (directorio importado)'),
  ('groups.b.read',         'Consultar Grupo B (registros propios)'),
  ('groups.manage',         'Gestionar membresías de grupos'),
  ('locations.exact.read',  'Ver coordenadas y direcciones exactas'),
  ('locations.write',       'Registrar y modificar coordenadas'),
  ('locations.verify',      'Verificar ubicaciones'),
  ('proximity.query',       'Consultar personas cercanas'),
  ('proximity.custom',      'Usar radio de proximidad personalizado'),
  ('geocoding.manage',      'Gestionar direcciones, alias y municipios'),
  ('imports.run',           'Importar registros CSV'),
  ('exports.run',           'Exportar información autorizada'),
  ('users.manage',          'Administrar usuarios'),
  ('audit.read',            'Consultar auditoría'),
  ('settings.manage',       'Modificar configuración del sistema'),
  ('system.status',         'Consultar estado del servidor y cartografía')
ON CONFLICT (code) DO UPDATE SET description = EXCLUDED.description;

INSERT INTO security.roles (code, name, rank, description) VALUES
  ('superadmin', 'Superadministrador', 100, 'Control total del sistema'),
  ('admin',      'Administrador',       80, 'Administración diaria; no gestiona superadministradores'),
  ('operator',   'Operador',            60, 'Registro y corrección de personas y ubicaciones'),
  ('consultant', 'Consultor',           40, 'Consultas y proximidad sin coordenadas exactas'),
  ('readonly',   'Solo lectura',        20, 'Consulta básica de personas')
ON CONFLICT (code) DO UPDATE SET name = EXCLUDED.name, rank = EXCLUDED.rank,
  description = EXCLUDED.description;

WITH grants(role_code, perm) AS (
  SELECT 'superadmin', code FROM security.permissions
  UNION ALL SELECT 'admin', code FROM security.permissions
  UNION ALL SELECT 'operator', unnest(ARRAY['persons.read','persons.write','groups.a.read',
    'groups.b.read','locations.exact.read','locations.write','proximity.query','system.status'])
  UNION ALL SELECT 'consultant', unnest(ARRAY['persons.read','groups.a.read','groups.b.read',
    'proximity.query','system.status'])
  UNION ALL SELECT 'readonly', unnest(ARRAY['persons.read','groups.a.read'])
)
INSERT INTO security.role_permissions (role_id, permission_code)
SELECT r.id, g.perm FROM grants g JOIN security.roles r ON r.code = g.role_code
ON CONFLICT DO NOTHING;
