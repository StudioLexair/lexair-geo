import type { FastifyInstance } from 'fastify';
import { z } from 'zod';
import { badRequest, unauthorized } from '../../lib/errors.js';
import { authenticate, invalidateSession, requireUser } from '../../plugins/auth.js';
import { writeAudit } from '../audit/audit-writer.js';
import { burnVerifyTime, checkPasswordPolicy, hashPassword, verifyPassword } from './password.js';

const LoginBody = z.object({
  username: z.string().trim().toLowerCase().min(3).max(40),
  password: z.string().min(1).max(128),
  clientKind: z.enum(['windows', 'web', 'legacy_web', 'api', 'unknown']).default('unknown'),
});

const ChangePasswordBody = z.object({
  currentPassword: z.string().min(1).max(128),
  newPassword: z.string().min(1).max(128),
});

type UserRow = {
  id: string;
  username: string;
  password_hash: string;
  is_active: boolean;
  failed_attempts: number;
  locked: boolean;
  must_change_password: boolean;
};

export async function authRoutes(app: FastifyInstance): Promise<void> {
  const { ctx } = app;

  app.post('/auth/login', {
    config: { rateLimit: { max: ctx.cfg.loginRateLimitPerMinute, timeWindow: '1 minute' } },
  }, async (req) => {
    const body = LoginBody.parse(req.body);
    const { rows } = await ctx.db.query<UserRow>(
      `SELECT id, username, password_hash, is_active, failed_attempts, must_change_password,
              (locked_until IS NOT NULL AND locked_until > now()) AS locked
         FROM identity.users WHERE lower(username) = $1`,
      [body.username],
    );
    const user = rows[0];
    const fail = async (reason: string) => {
      await writeAudit(ctx.db, req, {
        action: 'auth.login_failed', entityType: 'user', entityId: user?.id ?? null,
        success: false, details: { username: body.username, reason },
      });
      return unauthorized('Usuario o contraseña incorrectos');
    };
    if (!user) {
      await burnVerifyTime(body.password);
      throw await fail('unknown_user');
    }
    if (!user.is_active) throw await fail('inactive');
    if (user.locked) throw await fail('locked');
    if (!(await verifyPassword(user.password_hash, body.password))) {
      const maxFailed = await ctx.settings.number('security.max_failed_logins', 5);
      await ctx.db.query(
        `UPDATE identity.users SET failed_attempts = failed_attempts + 1,
           locked_until = CASE WHEN failed_attempts + 1 >= $2 THEN now() + interval '15 minutes'
                               ELSE locked_until END
         WHERE id = $1`,
        [user.id, maxFailed],
      );
      throw await fail('bad_password');
    }
    const hours = await ctx.settings.number('security.session_hours', 10);
    const session = await ctx.db.query<{ id: string; expires_at: Date }>(
      `INSERT INTO security.sessions (user_id, expires_at, client_kind, ip)
       VALUES ($1, now() + make_interval(hours => $2), $3, $4::inet) RETURNING id, expires_at`,
      [user.id, hours, body.clientKind, req.ip],
    );
    const s = session.rows[0]!;
    await ctx.db.query(
      'UPDATE identity.users SET failed_attempts = 0, locked_until = NULL, last_login_at = now() WHERE id = $1',
      [user.id],
    );
    await writeAudit(ctx.db, req, {
      action: 'auth.login', entityType: 'user', entityId: user.id,
      details: { username: user.username, clientKind: body.clientKind },
    });
    const token = app.jwt.sign({ sid: s.id, sub: user.id }, { expiresIn: `${hours}h` });
    return {
      token,
      expiresAt: s.expires_at.toISOString(),
      mustChangePassword: user.must_change_password,
    };
  });

  app.get('/auth/me', { preHandler: authenticate({ allowPasswordChange: true }) }, async (req) => {
    const u = requireUser(req);
    return {
      id: u.id,
      username: u.username,
      displayName: u.displayName,
      role: u.role,
      rank: u.rank,
      permissions: [...u.permissions].sort(),
      mustChangePassword: u.mustChangePassword,
      groups: ctx.groups
        .filter((g) => u.permissions.has(g.readPermission))
        .map((g) => ({ code: g.code, name: g.name, colorHex: g.colorHex })),
    };
  });

  app.post('/auth/logout', { preHandler: authenticate({ allowPasswordChange: true }) }, async (req) => {
    const u = requireUser(req);
    await ctx.db.query('UPDATE security.sessions SET revoked_at = now() WHERE id = $1', [u.sessionId]);
    invalidateSession(u.sessionId);
    await writeAudit(ctx.db, req, { action: 'auth.logout', entityType: 'user', entityId: u.id });
    return { ok: true };
  });

  app.post('/auth/change-password', {
    preHandler: authenticate({ allowPasswordChange: true }),
    config: { rateLimit: { max: 10, timeWindow: '1 minute' } },
  }, async (req) => {
    const u = requireUser(req);
    const body = ChangePasswordBody.parse(req.body);
    const { rows } = await ctx.db.query<{ password_hash: string }>(
      'SELECT password_hash FROM identity.users WHERE id = $1', [u.id],
    );
    if (!rows[0] || !(await verifyPassword(rows[0].password_hash, body.currentPassword))) {
      throw unauthorized('Contraseña actual incorrecta');
    }
    const policy = checkPasswordPolicy(body.newPassword, u.username);
    if (!policy.ok) throw badRequest(policy.reason);
    if (body.newPassword === body.currentPassword) throw badRequest('La nueva contraseña debe ser distinta');
    const hashed = await hashPassword(body.newPassword);
    await ctx.db.query(
      'UPDATE identity.users SET password_hash = $2, must_change_password = false WHERE id = $1',
      [u.id, hashed],
    );
    // Revoca el resto de sesiones del usuario.
    await ctx.db.query(
      'UPDATE security.sessions SET revoked_at = now() WHERE user_id = $1 AND id <> $2 AND revoked_at IS NULL',
      [u.id, u.sessionId],
    );
    invalidateSession(u.sessionId);
    await writeAudit(ctx.db, req, { action: 'auth.password_changed', entityType: 'user', entityId: u.id });
    return { ok: true };
  });
}
