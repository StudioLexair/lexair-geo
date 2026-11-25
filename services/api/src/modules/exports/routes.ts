import type { FastifyInstance } from 'fastify';
import { z } from 'zod';
import { GroupsParam } from '../../lib/pagination.js';
import { guard, requireUser } from '../../plugins/auth.js';
import { writeAudit } from '../audit/audit-writer.js';
import { PERSON_JOINS, PERSON_SELECT, PERSON_VISIBLE, type PersonRow } from '../persons/dto.js';
import { visibilityFor } from '../persons/routes.js';

const ExportQuery = z.object({
  groups: GroupsParam.optional(),
  municipalityId: z.coerce.number().int().positive().optional(),
  includeInactive: z.enum(['true', 'false']).default('false'),
});
const MAX_EXPORT = 50_000;

export function csvCell(v: unknown): string {
  if (v === null || v === undefined) return '';
  let s = String(v);
  // Neutraliza inyección de fórmulas al abrir el CSV en hojas de cálculo.
  if (/^[=+\-@\t\r]/.test(s)) s = `'${s}`;
  return /[",\n\r;]/.test(s) ? `"${s.replace(/"/g, '""')}"` : s;
}

export async function exportRoutes(app: FastifyInstance): Promise<void> {
  const { ctx } = app;

  app.get('/exports/persons.csv', { preHandler: guard('persons.read', 'exports.run') }, async (req, reply) => {
    const q = ExportQuery.parse(req.query);
    const user = requireUser(req);
    const v = visibilityFor(ctx, req, q.groups);
    const exact = user.permissions.has('locations.exact.read');
    const params: unknown[] = [v.groupIds, v.restricted, MAX_EXPORT];
    let extra = q.includeInactive === 'true' ? '' : ' AND p.is_active';
    if (q.municipalityId) {
      params.push(q.municipalityId);
      extra += ` AND l.municipality_id = $${params.length}`;
    }
    const { rows } = await ctx.db.query<PersonRow>(
      `${PERSON_SELECT} ${PERSON_JOINS} WHERE ${PERSON_VISIBLE} ${extra} ORDER BY p.code LIMIT $3`, params,
    );
    const header = ['code', 'given_names', 'family_names', 'groups', 'active', 'municipality', 'locality',
      'precision_level', 'validation_status', ...(exact ? ['lat', 'lon', 'address_text', 'phone'] : [])];
    const lines = [header.join(',')];
    for (const r of rows) {
      const base = [r.code, r.given_names, r.family_names, r.groups.join('|'), r.is_active, r.municipality,
        r.locality, r.precision_level, r.validation_status];
      const more = exact ? [r.lat?.toFixed(6), r.lon?.toFixed(6), r.address_text, r.phone] : [];
      lines.push([...base, ...more].map(csvCell).join(','));
    }
    await writeAudit(ctx.db, req, { action: 'export.persons', entityType: 'export',
      details: { rows: rows.length, groups: q.groups ?? 'allowed', withExactLocation: exact } });
    reply.header('Content-Type', 'text/csv; charset=utf-8');
    reply.header('Content-Disposition', `attachment; filename="lexair_personas_${Date.now()}.csv"`);
    return `\uFEFF${lines.join('\r\n')}\r\n`;
  });
}
