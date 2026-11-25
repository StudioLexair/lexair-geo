import type { FastifyInstance } from 'fastify';
import { z } from 'zod';
import { buildPage, offsetOf, PaginationQuery } from '../../lib/pagination.js';
import { guard } from '../../plugins/auth.js';

const AuditQuery = PaginationQuery.extend({
  action: z.string().regex(/^[a-z_.]{2,60}$/).optional(),
  actor: z.string().regex(/^[a-z0-9._-]{1,40}$/).optional(),
  entityType: z.string().regex(/^[a-z_]{2,40}$/).optional(),
  entityId: z.string().max(80).optional(),
  from: z.iso.datetime({ offset: true }).optional(),
  to: z.iso.datetime({ offset: true }).optional(),
  success: z.enum(['true', 'false']).optional(),
});

export async function auditRoutes(app: FastifyInstance): Promise<void> {
  const { ctx } = app;

  app.get('/audit', { preHandler: guard('audit.read') }, async (req) => {
    const q = AuditQuery.parse(req.query);
    const where: string[] = ['true'];
    const params: unknown[] = [];
    const add = (sql: string, v: unknown) => {
      params.push(v);
      where.push(sql.replace('?', `$${params.length}`));
    };
    if (q.action) add('action LIKE ?', `${q.action}%`);
    if (q.actor) add('actor_username = ?', q.actor);
    if (q.entityType) add('entity_type = ?', q.entityType);
    if (q.entityId) add('entity_id = ?', q.entityId);
    if (q.from) add('occurred_at >= ?', q.from);
    if (q.to) add('occurred_at < ?', q.to);
    if (q.success) add('success = ?', q.success === 'true');
    const whereSql = where.join(' AND ');
    const count = await ctx.db.query<{ n: number }>(
      `SELECT count(*)::int AS n FROM (SELECT 1 FROM audit.audit_logs WHERE ${whereSql} LIMIT 10000) t`,
      params,
    );
    params.push(q.pageSize, offsetOf(q));
    const { rows } = await ctx.db.query(
      `SELECT id, occurred_at AS "occurredAt", actor_username AS actor, action,
              entity_type AS "entityType", entity_id AS "entityId", success, host(ip) AS ip, details
         FROM audit.audit_logs WHERE ${whereSql}
        ORDER BY occurred_at DESC, id DESC
        LIMIT $${params.length - 1} OFFSET $${params.length}`,
      params,
    );
    return buildPage(rows, q, count.rows[0]?.n ?? 0, 10000);
  });
}
