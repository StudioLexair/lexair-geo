import type { FastifyInstance } from 'fastify';
import { z } from 'zod';
import { withTransaction } from '../../db/pool.js';
import { badRequest, forbidden, notFound } from '../../lib/errors.js';
import { guard, invalidateAllSessions, requireUser } from '../../plugins/auth.js';
import type { AuthUser } from '../../types.js';
import { writeAudit } from '../audit/audit-writer.js';
import { checkPasswordPolicy, generateTemporaryPassword, hashPassword } from '../auth/password.js';

const CreateUser = z.object({
  username: z.string().trim().toLowerCase().regex(/^[a-z0-9._-]{3,40}$/),
  displayName: z.string().trim().min(1).max(120),
  role: z.string().regex(/^[a-z_]{3,32}$/),
  password: z.string().max(128).optional(),
});
const UpdateUser = z.object({
  displayName: z.string().trim().min(1).max(120).optional(),
  role: z.string().regex(/^[a-z_]{3,32}$/).optional(),
  isActive: z.boolean().optional(),
});
const IdParams = z.object({ id: z.uuid() });

type RoleRow = { id: number; rank: number };

/** Un administrador solo gestiona usuarios y roles de rango inferior al suyo. */
async function roleFor(app: FastifyInstance, actor: AuthUser, code: string): Promise<RoleRow> {
  const { rows } = await app.ctx.db.query<RoleRow>('SELECT id, rank FROM security.roles WHERE code = $1', [code]);
  const role = rows[0];
  if (!role) throw badRequest('Rol inexistente');
  if (role.rank >= actor.rank && actor.role !== 'superadmin') {
    throw forbidden('No puede asignar un rol igual o superior al suyo');
  }
  return role;
}

async function assertTargetManageable(app: FastifyInstance, actor: AuthUser, id: string): Promise<void> {
  const { rows } = await app.ctx.db.query<{ rank: number }>(
    'SELECT r.rank FROM identity.users u JOIN security.roles r ON r.id = u.role_id WHERE u.id = $1', [id],
  );
  if (!rows[0]) throw notFound('Usuario no encontrado');
  if (rows[0].rank >= actor.rank && actor.role !== 'superadmin') {
    throw forbidden('No puede gestionar usuarios de rango igual o superior');
  }
}

export async function userRoutes(app: FastifyInstance): Promise<void> {
  const { ctx } = app;
  const manage = guard('users.manage');

  app.get('/users', { preHandler: manage }, async () => {
    const { rows } = await ctx.db.query(
      `SELECT u.id, u.username, u.display_name AS "displayName", r.code AS role, r.name AS "roleName",
              u.is_active AS "isActive", u.must_change_password AS "mustChangePassword",
              u.last_login_at AS "lastLoginAt", u.created_at AS "createdAt",
              (u.locked_until IS NOT NULL AND u.locked_until > now()) AS locked
         FROM identity.users u JOIN security.roles r ON r.id = u.role_id
        ORDER BY u.username`,
    );
    return { items: rows };
  });

  app.post('/users', { preHandler: manage }, async (req, reply) => {
    const actor = requireUser(req);
    const b = CreateUser.parse(req.body);
    const role = await roleFor(app, actor, b.role);
    const temporary = b.password ? null : generateTemporaryPassword();
    const password = b.password ?? temporary!;
    if (b.password) {
      const pol = checkPasswordPolicy(b.password, b.username);
      if (!pol.ok) throw badRequest(pol.reason);
    }
    const hashed = await hashPassword(password);
    const id = await withTransaction(ctx.db, async (c) => {
      const { rows } = await c.query<{ id: string }>(
        `INSERT INTO identity.users (username, display_name, password_hash, role_id, must_change_password, created_by)
         VALUES ($1, $2, $3, $4, true, $5) RETURNING id`,
        [b.username, b.displayName, hashed, role.id, actor.id],
      );
      await writeAudit(c, req, { action: 'user.create', entityType: 'user', entityId: rows[0]!.id,
        details: { username: b.username, role: b.role } });
      return rows[0]!.id;
    });
    reply.code(201);
    // La contraseña temporal se devuelve UNA vez; nunca se registra.
    return { id, temporaryPassword: temporary };
  });

  app.patch('/users/:id', { preHandler: manage }, async (req) => {
    const actor = requireUser(req);
    const { id } = IdParams.parse(req.params);
    const b = UpdateUser.parse(req.body);
    if (id === actor.id && (b.role || b.isActive === false)) {
      throw badRequest('No puede cambiar su propio rol ni desactivarse');
    }
    await assertTargetManageable(app, actor, id);
    const roleId = b.role ? (await roleFor(app, actor, b.role)).id : null;
    await withTransaction(ctx.db, async (c) => {
      await c.query(
        `UPDATE identity.users SET display_name = COALESCE($2, display_name),
           role_id = COALESCE($3, role_id), is_active = COALESCE($4, is_active)
         WHERE id = $1`,
        [id, b.displayName ?? null, roleId, b.isActive ?? null],
      );
      if (b.isActive === false || b.role) {
        await c.query('UPDATE security.sessions SET revoked_at = now() WHERE user_id = $1 AND revoked_at IS NULL', [id]);
      }
      await writeAudit(c, req, { action: 'user.update', entityType: 'user', entityId: id,
        details: { fields: Object.keys(b), role: b.role ?? null } });
    });
    invalidateAllSessions();
    return { ok: true };
  });

  app.post('/users/:id/reset-password', { preHandler: manage }, async (req) => {
    const actor = requireUser(req);
    const { id } = IdParams.parse(req.params);
    await assertTargetManageable(app, actor, id);
    const temporary = generateTemporaryPassword();
    const hashed = await hashPassword(temporary);
    await withTransaction(ctx.db, async (c) => {
      await c.query(
        `UPDATE identity.users SET password_hash = $2, must_change_password = true,
           failed_attempts = 0, locked_until = NULL WHERE id = $1`, [id, hashed],
      );
      await c.query('UPDATE security.sessions SET revoked_at = now() WHERE user_id = $1 AND revoked_at IS NULL', [id]);
      await writeAudit(c, req, { action: 'user.password_reset', entityType: 'user', entityId: id });
    });
    invalidateAllSessions();
    return { temporaryPassword: temporary };
  });
}
