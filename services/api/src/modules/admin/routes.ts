import type { FastifyInstance } from 'fastify';
import { z } from 'zod';
import { withTransaction } from '../../db/pool.js';
import { badRequest, forbidden, notFound } from '../../lib/errors.js';
import { guard, invalidateAllSessions, requireUser } from '../../plugins/auth.js';
import { writeAudit } from '../audit/audit-writer.js';
import { serverStatus } from './status.js';

const SettingBody = z.object({ value: z.unknown() });
const KeyParams = z.object({ key: z.string().regex(/^[a-z][a-z0-9_.]{2,63}$/) });
const RolePermsBody = z.object({ permissions: z.array(z.string().regex(/^[a-z][a-z0-9_.]{2,63}$/)).max(64) });
const RoleParams = z.object({ code: z.string().regex(/^[a-z_]{3,32}$/) });

/** Validadores por clave para no aceptar configuraciones absurdas. */
const SETTING_VALIDATORS: Record<string, z.ZodType> = {
  'proximity.radii_m': z.array(z.number().int().min(10).max(50000)).min(1).max(12),
  'proximity.max_custom_radius_m': z.number().int().min(100).max(50000),
  'proximity.max_results': z.number().int().min(10).max(5000),
  'map.default_center': z.object({ lat: z.number().min(19.5).max(23.6), lon: z.number().min(-85.2).max(-74) }),
  'map.default_zoom': z.number().int().min(5).max(18),
  'map.max_points': z.number().int().min(100).max(10000),
  'privacy.retention_days_inactive': z.number().int().min(30).max(36500),
  'security.session_hours': z.number().int().min(1).max(24),
  'security.max_failed_logins': z.number().int().min(3).max(20),
  'geo.allowed_bbox': z.object({ west: z.number(), south: z.number(), east: z.number(), north: z.number() }),
  // Operación de pases (0011): todo editable desde la administración.
  'personnel.near_radius_m': z.number().int().min(100).max(200000),
  'personnel.max_results': z.number().int().min(5).max(500),
  'passes.default_days': z.number().int().min(1).max(365),
  'passes.max_active_per_person': z.number().int().min(1).max(20),
  'passes.marker_icon': z.object({
    icon: z.string().trim().min(1).max(60),
    colorHex: z.string().regex(/^#[0-9A-Fa-f]{6}$/),
    size: z.number().int().min(10).max(64),
  }),
  'personnel.marker_icon': z.object({
    icon: z.string().trim().min(1).max(60),
    colorHex: z.string().regex(/^#[0-9A-Fa-f]{6}$/),
    size: z.number().int().min(10).max(64),
  }),
  'zones.palette': z.array(z.string().regex(/^#[0-9A-Fa-f]{6}$/)).min(1).max(24),
  'zones.max_radius_m': z.number().int().min(100).max(200000),
  'zones.max_results': z.number().int().min(10).max(20000),
  'inmate.statuses': z.array(z.string().trim().min(1).max(60)).max(24),
  'inmate.risk_levels': z.array(z.string().trim().min(1).max(40)).max(24),
  'oracle.row_cap': z.number().int().min(100).max(500000),
  'oracle.timeout_ms': z.number().int().min(1000).max(300000),
};

export async function adminRoutes(app: FastifyInstance): Promise<void> {
  const { ctx } = app;

  app.get('/admin/dashboard', { preHandler: guard('system.status') }, async () => {
    const { rows } = await ctx.db.query(`SELECT
      (SELECT count(*)::int FROM directory.persons) AS persons_total,
      (SELECT count(*)::int FROM directory.persons WHERE is_active) AS persons_active,
      (SELECT count(*)::int FROM directory.persons WHERE is_synthetic) AS persons_synthetic,
      (SELECT json_object_agg(g.code, (SELECT count(*) FROM directory.person_memberships m WHERE m.group_id = g.id))
         FROM directory.person_groups g) AS by_group,
      (SELECT count(*)::int FROM geo.person_locations) AS locations_total,
      (SELECT coalesce(json_object_agg(precision_level, n), '{}') FROM
         (SELECT precision_level, count(*) n FROM geo.person_locations GROUP BY 1) t) AS by_precision,
      (SELECT coalesce(json_object_agg(validation_status, n), '{}') FROM
         (SELECT validation_status, count(*) n FROM geo.person_locations GROUP BY 1) t) AS by_validation,
      (SELECT count(*)::int FROM identity.users WHERE is_active) AS users_active,
      (SELECT count(*)::int FROM geo.addresses) AS addresses,
      (SELECT count(*)::int FROM geo.municipalities) AS municipalities,
      (SELECT count(*)::int FROM geo.points_of_interest) AS pois,
      (SELECT count(*)::int FROM directory.import_jobs WHERE created_at > now() - interval '7 days') AS imports_7d,
      (SELECT count(*)::int FROM geo.zones WHERE is_active) AS zones_active,
      (SELECT count(*)::int FROM directory.inmates WHERE is_active) AS inmates_active,
      (SELECT count(*)::int FROM directory.passes WHERE returned_at IS NULL AND cancelled_at IS NULL
         AND now() >= starts_at AND now() <= ends_at) AS passes_active,
      (SELECT count(*)::int FROM directory.personnel WHERE is_active) AS personnel_active,
      (SELECT count(*)::int FROM directory.oracle_connectors WHERE enabled) AS oracle_connectors`);
    return rows[0];
  });

  app.get('/admin/status', { preHandler: guard('system.status') }, async () => serverStatus(ctx));

  app.get('/admin/settings', { preHandler: guard('settings.manage') }, async () => {
    const { rows } = await ctx.db.query(
      `SELECT key, value, description, updated_at AS "updatedAt" FROM catalog.system_settings ORDER BY key`,
    );
    return { items: rows };
  });

  app.put('/admin/settings/:key', { preHandler: guard('settings.manage') }, async (req) => {
    const { key } = KeyParams.parse(req.params);
    const validator = SETTING_VALIDATORS[key];
    if (!validator) throw badRequest('Clave de configuración no editable');
    const value = validator.parse(SettingBody.parse(req.body).value);
    await withTransaction(ctx.db, async (c) => {
      await c.query(
        `INSERT INTO catalog.system_settings (key, value, description, updated_at, updated_by)
         VALUES ($1, $2::jsonb, $1, now(), $3)
         ON CONFLICT (key) DO UPDATE SET value = EXCLUDED.value, updated_at = now(), updated_by = EXCLUDED.updated_by`,
        [key, JSON.stringify(value), requireUser(req).id],
      );
      await writeAudit(c, req, { action: 'settings.update', entityType: 'setting', entityId: key });
    });
    ctx.settings.invalidate();
    return { key, value };
  });

  app.get('/admin/roles', { preHandler: guard('users.manage') }, async () => {
    const { rows } = await ctx.db.query(
      `SELECT r.code, r.name, r.rank, r.description,
              ARRAY(SELECT permission_code FROM security.role_permissions rp WHERE rp.role_id = r.id
                    ORDER BY 1) AS permissions,
              (SELECT count(*)::int FROM identity.users u WHERE u.role_id = r.id) AS users
         FROM security.roles r ORDER BY r.rank DESC`,
    );
    const perms = await ctx.db.query('SELECT code, description FROM security.permissions ORDER BY code');
    return { roles: rows, permissions: perms.rows };
  });

  app.put('/admin/roles/:code/permissions', { preHandler: guard('users.manage') }, async (req) => {
    const actor = requireUser(req);
    if (actor.role !== 'superadmin') throw forbidden('Solo el superadministrador modifica roles');
    const { code } = RoleParams.parse(req.params);
    if (code === 'superadmin') throw badRequest('El rol superadministrador no se modifica');
    const { permissions } = RolePermsBody.parse(req.body);
    await withTransaction(ctx.db, async (c) => {
      const role = await c.query<{ id: number }>('SELECT id FROM security.roles WHERE code = $1', [code]);
      if (!role.rows[0]) throw notFound('Rol inexistente');
      const id = role.rows[0].id;
      await c.query('DELETE FROM security.role_permissions WHERE role_id = $1', [id]);
      await c.query(
        `INSERT INTO security.role_permissions (role_id, permission_code)
         SELECT $1, p FROM unnest($2::text[]) AS p`, [id, permissions],
      );
      await writeAudit(c, req, { action: 'role.permissions_set', entityType: 'role', entityId: code,
        details: { permissions } });
    });
    invalidateAllSessions();
    return { ok: true };
  });

  app.get('/groups', { preHandler: guard('persons.read') }, async (req) => {
    const user = requireUser(req);
    const visible = ctx.groups.filter((g) => user.permissions.has(g.readPermission));
    const { rows } = await ctx.db.query<{ group_id: number; n: number }>(
      `SELECT group_id, count(*)::int AS n FROM directory.person_memberships m
         JOIN directory.persons p ON p.id = m.person_id AND p.is_active
        WHERE group_id = ANY($1::smallint[]) GROUP BY group_id`, [visible.map((g) => g.id)],
    );
    const counts = new Map(rows.map((r) => [r.group_id, r.n]));
    return { items: visible.map((g) => ({ code: g.code, name: g.name, colorHex: g.colorHex,
      activeMembers: counts.get(g.id) ?? 0 })) };
  });
}
