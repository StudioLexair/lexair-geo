import type { FastifyReply, FastifyRequest, preHandlerAsyncHookHandler } from 'fastify';
import { forbidden, unauthorized } from '../lib/errors.js';
import type { AppContext, AuthUser, GroupCode } from '../types.js';

type SessionRow = {
  id: string;
  username: string;
  display_name: string;
  must_change_password: boolean;
  role: string;
  rank: number;
  perms: string[];
};

const CACHE_MS = 5_000;
const cache = new Map<string, { user: AuthUser; at: number }>();

export function invalidateSession(sessionId: string): void {
  cache.delete(sessionId);
}
export function invalidateAllSessions(): void {
  cache.clear();
}

export async function loadSessionUser(ctx: AppContext, sessionId: string): Promise<AuthUser | null> {
  const hit = cache.get(sessionId);
  if (hit && Date.now() - hit.at < CACHE_MS) return hit.user;
  const { rows } = await ctx.db.query<SessionRow>(
    `SELECT u.id, u.username, u.display_name, u.must_change_password, r.code AS role, r.rank,
            ARRAY(SELECT rp.permission_code FROM security.role_permissions rp
                  WHERE rp.role_id = r.id) AS perms
       FROM security.sessions s
       JOIN identity.users u ON u.id = s.user_id
       JOIN security.roles r ON r.id = u.role_id
      WHERE s.id = $1 AND s.revoked_at IS NULL AND s.expires_at > now() AND u.is_active`,
    [sessionId],
  );
  const row = rows[0];
  if (!row) {
    cache.delete(sessionId);
    return null;
  }
  const user: AuthUser = {
    id: row.id,
    username: row.username,
    displayName: row.display_name,
    role: row.role,
    rank: row.rank,
    permissions: new Set(row.perms),
    mustChangePassword: row.must_change_password,
    sessionId,
  };
  if (cache.size > 2000) cache.clear();
  cache.set(sessionId, { user, at: Date.now() });
  return user;
}

/** Autentica (JWT + sesión viva). Bloquea si debe cambiar la contraseña. */
export function authenticate(opts: { allowPasswordChange?: boolean } = {}): preHandlerAsyncHookHandler {
  return async function (this: unknown, req: FastifyRequest, _reply: FastifyReply) {
    let payload: { sid: string; sub: string };
    try {
      payload = await req.jwtVerify<{ sid: string; sub: string }>();
    } catch {
      throw unauthorized('Sesión no válida o caducada');
    }
    const user = await loadSessionUser(req.server.ctx, payload.sid);
    if (!user || user.id !== payload.sub) throw unauthorized('Sesión no válida o caducada');
    if (user.mustChangePassword && !opts.allowPasswordChange) {
      throw forbidden('Debe cambiar su contraseña antes de continuar');
    }
    req.auth = user;
  };
}

export function requireUser(req: FastifyRequest): AuthUser {
  if (!req.auth) throw unauthorized();
  return req.auth;
}

export function hasPermission(user: AuthUser, perm: string): boolean {
  return user.permissions.has(perm);
}

/** preHandler: autenticación + todos los permisos indicados. */
export function guard(...perms: string[]): preHandlerAsyncHookHandler[] {
  const check: preHandlerAsyncHookHandler = async (req) => {
    const user = requireUser(req);
    for (const p of perms) if (!user.permissions.has(p)) throw forbidden(`Requiere permiso ${p}`);
  };
  return [authenticate(), check];
}

/** Grupos que el usuario puede consultar, intersectados con los pedidos. */
export function allowedGroups(ctx: AppContext, user: AuthUser, requested?: GroupCode[]): number[] {
  const allowed = ctx.groups.filter((g) => user.permissions.has(g.readPermission));
  const filtered = requested ? allowed.filter((g) => requested.includes(g.code)) : allowed;
  if (requested && filtered.length < requested.length) {
    throw forbidden('No tiene permiso para consultar alguno de los grupos solicitados');
  }
  if (filtered.length === 0) throw forbidden('No tiene permiso para consultar ningún grupo');
  return filtered.map((g) => g.id);
}

/** Las personas de visibilidad restringida solo las ven rangos administrativos. */
export function canSeeRestricted(user: AuthUser): boolean {
  return user.rank >= 80;
}
