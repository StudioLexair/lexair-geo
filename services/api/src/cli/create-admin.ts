import { parseArgs } from 'node:util';
import pg from 'pg';
import { checkPasswordPolicy, generateTemporaryPassword, hashPassword } from '../modules/auth/password.js';

/**
 * Creación segura del primer administrador. No existen contraseñas por
 * defecto: se genera una temporal aleatoria (mostrada UNA vez) o se lee de
 * LEXAIR_ADMIN_PASSWORD. El usuario deberá cambiarla en el primer acceso.
 * Idempotente: si el usuario existe no se modifica (salvo --reset).
 */
async function main(): Promise<void> {
  const { values } = parseArgs({ options: {
    username: { type: 'string', default: 'admin' },
    'display-name': { type: 'string', default: 'Superadministrador' },
    role: { type: 'string', default: 'superadmin' },
    reset: { type: 'boolean', default: false },
  } });
  const url = process.env.DATABASE_URL;
  if (!url) throw new Error('Defina DATABASE_URL');
  const username = values.username!.toLowerCase();
  const provided = process.env.LEXAIR_ADMIN_PASSWORD;
  if (provided) {
    const pol = checkPasswordPolicy(provided, username);
    if (!pol.ok) throw new Error(`LEXAIR_ADMIN_PASSWORD no cumple la política: ${pol.reason}`);
  }
  const password = provided ?? generateTemporaryPassword();
  const client = new pg.Client({ connectionString: url });
  await client.connect();
  try {
    const exists = await client.query('SELECT id FROM identity.users WHERE lower(username) = $1', [username]);
    if (exists.rowCount && !values.reset) {
      console.log(JSON.stringify({ created: false, username, message: 'El usuario ya existe; sin cambios' }));
      return;
    }
    const role = await client.query<{ id: number }>('SELECT id FROM security.roles WHERE code = $1', [values.role]);
    if (!role.rows[0]) throw new Error(`Rol inexistente: ${values.role}`);
    const hashed = await hashPassword(password);
    await client.query(
      `INSERT INTO identity.users (username, display_name, password_hash, role_id, must_change_password)
       VALUES ($1, $2, $3, $4, true)
       ON CONFLICT ((lower(username))) DO UPDATE SET password_hash = EXCLUDED.password_hash,
         must_change_password = true, failed_attempts = 0, locked_until = NULL, is_active = true`,
      [username, values['display-name'], hashed, role.rows[0].id],
    );
    const isReset = Boolean(values.reset && exists.rowCount);
    if (isReset) {
      // Recuperación de acceso: se invalidan las sesiones abiertas de ese usuario.
      await client.query(
        `UPDATE security.sessions SET revoked_at = now()
          WHERE revoked_at IS NULL AND user_id = (SELECT id FROM identity.users WHERE lower(username) = $1)`,
        [username],
      );
    }
    await client.query(
      `INSERT INTO audit.audit_logs (actor_username, action, entity_type, entity_id, details)
       VALUES ('installer', $1, 'user', $2, '{}'::jsonb)`,
      [isReset ? 'user.password_reset' : 'user.create', username],
    );
    // En un restablecimiento el rol existente no se modifica.
    console.log(JSON.stringify({ created: !isReset, reset: isReset, username,
      ...(isReset ? {} : { role: values.role }), mustChangePassword: true, sessionsRevoked: isReset,
      temporaryPassword: provided ? '(proporcionada por variable de entorno)' : password }));
  } finally {
    await client.end();
  }
}

main().catch((err) => {
  console.error(err instanceof Error ? err.message : err);
  process.exit(1);
});
