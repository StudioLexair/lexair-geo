-- LEXAIR GEO · 0005 · Auditoría append-only, configuración e importaciones

CREATE TABLE IF NOT EXISTS audit.audit_logs (
  id             bigint GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
  occurred_at    timestamptz NOT NULL DEFAULT now(),
  actor_user_id  uuid REFERENCES identity.users(id) ON DELETE SET NULL,
  actor_username text,
  action         text NOT NULL CHECK (action ~ '^[a-z_]+\.[a-z_.]+$'),
  entity_type    text NOT NULL,
  entity_id      text,
  success        boolean NOT NULL DEFAULT true,
  ip             inet,
  -- Nunca contiene contraseñas ni coordenadas: solo nombres de campos/metadatos.
  details        jsonb NOT NULL DEFAULT '{}'::jsonb
);
CREATE INDEX IF NOT EXISTS audit_time_idx ON audit.audit_logs (occurred_at DESC);
CREATE INDEX IF NOT EXISTS audit_actor_idx ON audit.audit_logs (actor_user_id, occurred_at DESC);
CREATE INDEX IF NOT EXISTS audit_entity_idx ON audit.audit_logs (entity_type, entity_id);

CREATE OR REPLACE FUNCTION audit.forbid_mutation()
RETURNS trigger LANGUAGE plpgsql AS $$
BEGIN
  RAISE EXCEPTION 'audit.audit_logs es de solo inserción';
END;
$$;
DROP TRIGGER IF EXISTS audit_logs_append_only ON audit.audit_logs;
CREATE TRIGGER audit_logs_append_only BEFORE UPDATE OR DELETE ON audit.audit_logs
  FOR EACH ROW EXECUTE FUNCTION audit.forbid_mutation();

CREATE TABLE IF NOT EXISTS catalog.system_settings (
  key         text PRIMARY KEY CHECK (key ~ '^[a-z][a-z0-9_.]{2,63}$'),
  value       jsonb NOT NULL,
  description text NOT NULL,
  updated_at  timestamptz NOT NULL DEFAULT now(),
  updated_by  uuid REFERENCES identity.users(id)
);

INSERT INTO catalog.system_settings (key, value, description) VALUES
  ('proximity.radii_m', '[100,250,500,1000,2000,5000]', 'Radios predefinidos (metros)'),
  ('proximity.max_custom_radius_m', '10000', 'Radio personalizado máximo autorizado (metros)'),
  ('proximity.max_results', '500', 'Máximo de resultados por consulta de proximidad'),
  ('map.default_center', '{"lat": 22.4067, "lon": -79.9653}',
     'Centro inicial del mapa (Santa Clara, coordenada de referencia)'),
  ('map.default_zoom', '10', 'Zoom inicial'),
  ('map.max_points', '2000', 'Máximo de puntos individuales en una vista'),
  ('privacy.retention_days_inactive', '1825', 'Días de retención tras desactivación'),
  ('security.session_hours', '10', 'Duración de sesión en horas'),
  ('security.max_failed_logins', '5', 'Intentos fallidos antes de bloqueo temporal')
ON CONFLICT (key) DO NOTHING;

CREATE TABLE IF NOT EXISTS directory.import_jobs (
  id          uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  kind        text NOT NULL CHECK (kind IN ('persons_csv')),
  filename    text NOT NULL CHECK (length(filename) BETWEEN 1 AND 255),
  target_group text NOT NULL CHECK (target_group IN ('A','B')),
  status      text NOT NULL DEFAULT 'running'
              CHECK (status IN ('running','completed','completed_with_errors','failed')),
  dry_run     boolean NOT NULL DEFAULT false,
  total_rows  integer NOT NULL DEFAULT 0 CHECK (total_rows >= 0),
  ok_rows     integer NOT NULL DEFAULT 0 CHECK (ok_rows >= 0),
  error_rows  integer NOT NULL DEFAULT 0 CHECK (error_rows >= 0),
  errors      jsonb NOT NULL DEFAULT '[]'::jsonb,
  created_by  uuid REFERENCES identity.users(id),
  created_at  timestamptz NOT NULL DEFAULT now(),
  finished_at timestamptz
);
CREATE INDEX IF NOT EXISTS import_jobs_time_idx ON directory.import_jobs (created_at DESC);
