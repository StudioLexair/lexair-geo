import { randomBytes } from 'node:crypto';
import path from 'node:path';
import type { FastifyInstance } from 'fastify';
import pg from 'pg';
import { buildApp } from '../../src/app.js';
import { loadConfig } from '../../src/config.js';
import { createPool, type Db } from '../../src/db/pool.js';
import { runMigrations } from '../../src/db/migrator.js';
import { hashPassword } from '../../src/modules/auth/password.js';

export const integrationEnabled = process.env.LEXAIR_INTEGRATION === '1' && Boolean(process.env.TEST_DATABASE_URL);

export const PASSWORD = 'Prueba-Integracion-2026!';
export const ROLES = ['superadmin', 'admin', 'operator', 'consultant', 'readonly'] as const;

/**
 * `db`: conexión con privilegios de propietario SOLO para preparar datos de
 * prueba. La aplicación usa `apiDb`, conectada como un rol LOGIN miembro de
 * `lexair_api` (privilegios mínimos, igual que en producción), de modo que
 * cualquier GRANT que falte hace fallar las pruebas.
 */
export type Harness = { app: FastifyInstance; db: Db; apiDb: Db; tokens: Record<string, string> };

/** Base de datos de pruebas: migraciones reales + usuarios por rol. */
export async function setupHarness(): Promise<Harness> {
  const url = process.env.TEST_DATABASE_URL!;
  const admin = new pg.Client({ connectionString: url });
  await admin.connect();
  await runMigrations(admin, path.resolve(import.meta.dirname, '../../../../database/migrations'));
  await admin.query(`TRUNCATE directory.person_memberships, geo.person_locations, directory.persons,
    directory.import_jobs, security.sessions, geo.addresses, geo.street_aliases, geo.points_of_interest,
    geo.localities CASCADE`);
  await admin.query("DELETE FROM geo.municipalities WHERE source_code = 'test_fixture'");
  await admin.query('ALTER TABLE audit.audit_logs DISABLE TRIGGER audit_logs_append_only');
  await admin.query('TRUNCATE audit.audit_logs');
  await admin.query('ALTER TABLE audit.audit_logs ENABLE TRIGGER audit_logs_append_only');
  await admin.query('UPDATE catalog.system_settings SET updated_by = NULL');
  await admin.query(`UPDATE catalog.system_settings SET value = '500' WHERE key = 'proximity.max_results'`);
  await admin.query("DELETE FROM identity.users WHERE username LIKE 't\\_%'");
  await admin.query("DELETE FROM catalog.system_settings WHERE key = 'geo.allowed_bbox'");
  const hashed = await hashPassword(PASSWORD);
  for (const role of ROLES) {
    await admin.query(
      `INSERT INTO identity.users (username, display_name, password_hash, role_id, must_change_password)
       SELECT $1, $2, $3, id, false FROM security.roles WHERE code = $4`,
      [`t_${role}`, `Prueba ${role}`, hashed, role],
    );
  }
  const apiPassword = randomBytes(18).toString('base64url');
  await admin.query(`DO $$ BEGIN
      IF NOT EXISTS (SELECT 1 FROM pg_roles WHERE rolname = 'lexair_api_test') THEN
        CREATE ROLE lexair_api_test LOGIN NOSUPERUSER NOCREATEDB NOCREATEROLE;
      END IF; END $$`);
  await admin.query(`ALTER ROLE lexair_api_test PASSWORD '${apiPassword}'`);
  await admin.query('GRANT lexair_api TO lexair_api_test');
  await admin.end();
  const apiUrl = new URL(url);
  apiUrl.username = 'lexair_api_test';
  apiUrl.password = apiPassword;
  const fixtureCfg = loadConfig({ NODE_ENV: 'test', DATABASE_URL: url, JWT_SECRET: 'x'.repeat(48) });
  const db = createPool(fixtureCfg);
  const cfg = loadConfig({ NODE_ENV: 'test', DATABASE_URL: apiUrl.toString(), JWT_SECRET: 'x'.repeat(48),
    MAP_MANIFEST_PATH: path.resolve(import.meta.dirname, '../fixtures/manifest.json'), TILE_SERVICE_URL: 'http://127.0.0.1:9',
    BACKUP_DIR: path.resolve(import.meta.dirname, '../fixtures'), RATE_LIMIT_PER_MINUTE: '100000',
    LOGIN_RATE_LIMIT_PER_MINUTE: '100000' });
  const apiDb = createPool(cfg);
  const app = await buildApp(cfg, apiDb);
  const tokens: Record<string, string> = {};
  for (const role of ROLES) tokens[role] = await login(app, `t_${role}`, PASSWORD);
  return { app, db, apiDb, tokens };
}

export async function login(app: FastifyInstance, username: string, password: string): Promise<string> {
  const res = await app.inject({ method: 'POST', url: '/api/v1/auth/login', payload: { username, password } });
  if (res.statusCode !== 200) throw new Error(`login ${username}: ${res.statusCode} ${res.body}`);
  return res.json().token as string;
}

export async function teardown(h: Harness | undefined): Promise<void> {
  if (!h) return;
  await h.app.close();
  await h.apiDb.end();
  await h.db.end();
}

export function auth(token: string) {
  return { authorization: `Bearer ${token}` };
}

/** Punto de referencia SINTÉTICO para pruebas (no representa a nadie). */
export const ORIGIN = { lat: 22.4, lon: -79.95 };

/** Desplaza un punto `meters` hacia el norte (≈110,736 m por grado a 22.4° N). */
export function north(meters: number) {
  return { lat: ORIGIN.lat + meters / 110_736, lon: ORIGIN.lon };
}
