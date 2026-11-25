import type { FastifyInstance } from 'fastify';
import { z } from 'zod';
import { withTransaction } from '../../db/pool.js';
import { badRequest, forbidden, notFound } from '../../lib/errors.js';
import { normalizeText } from '../../lib/text.js';
import { allowedGroups, guard, requireUser } from '../../plugins/auth.js';
import { writeAudit } from '../audit/audit-writer.js';
import { importRows } from './import-service.js';
import { validateCsv } from './csv-validation.js';

const ImportQuery = z.object({
  group: z.enum(['A', 'B']),
  dryRun: z.enum(['true', 'false']).default('true'),
  filename: z.string().trim().min(1).max(255).default('import.csv'),
});
const IdParams = z.object({ id: z.uuid() });

export async function importRoutes(app: FastifyInstance): Promise<void> {
  const { ctx } = app;

  app.post('/imports/persons', {
    preHandler: guard('imports.run', 'persons.write'),
    bodyLimit: 20 * 1024 * 1024,
  }, async (req, reply) => {
    const user = requireUser(req);
    const q = ImportQuery.parse(req.query);
    if (typeof req.body !== 'string') throw badRequest('Envíe el CSV con Content-Type text/csv');
    const [groupId] = allowedGroups(ctx, user, [q.group]);
    const dryRun = q.dryRun === 'true';
    const munis = await ctx.db.query<{ id: number; name: string }>('SELECT id, name FROM geo.municipalities');
    const muniMap = new Map(munis.rows.map((m) => [normalizeText(m.name), m.id]));
    const outcome = validateCsv(req.body, muniMap, await ctx.settings.allowedBBox());
    const hasCoords = outcome.rows.some((r) => r.lat !== null);
    if (hasCoords && !user.permissions.has('locations.write')) {
      throw forbidden('El fichero contiene coordenadas y requiere permiso locations.write');
    }
    let okRows = outcome.rows.length;
    if (!dryRun && outcome.rows.length > 0) {
      okRows = await importRows(ctx.db, outcome.rows, groupId!, user.id);
    }
    const status = outcome.errors.length === 0 ? 'completed'
      : okRows > 0 ? 'completed_with_errors' : 'failed';
    const job = await withTransaction(ctx.db, async (c) => {
      const { rows } = await c.query<{ id: string }>(
        `INSERT INTO directory.import_jobs (kind, filename, target_group, status, dry_run, total_rows,
           ok_rows, error_rows, errors, created_by, finished_at)
         VALUES ('persons_csv', $1, $2, $3, $4, $5, $6, $7, $8::jsonb, $9, now()) RETURNING id`,
        [q.filename, q.group, status, dryRun, outcome.total, okRows, outcome.errors.length,
          JSON.stringify(outcome.errors.slice(0, 500)), user.id],
      );
      await writeAudit(c, req, { action: dryRun ? 'import.validate' : 'import.run', entityType: 'import_job',
        entityId: rows[0]!.id, details: { group: q.group, total: outcome.total, ok: okRows,
          errors: outcome.errors.length, filename: q.filename } });
      return rows[0]!.id;
    });
    reply.code(dryRun ? 200 : 201);
    return { jobId: job, dryRun, status, totalRows: outcome.total, okRows,
      errorRows: outcome.errors.length, errors: outcome.errors.slice(0, 100) };
  });

  app.get('/imports', { preHandler: guard('imports.run') }, async () => {
    const { rows } = await ctx.db.query(
      `SELECT j.id, j.kind, j.filename, j.target_group AS "targetGroup", j.status, j.dry_run AS "dryRun",
              j.total_rows AS "totalRows", j.ok_rows AS "okRows", j.error_rows AS "errorRows",
              j.created_at AS "createdAt", j.finished_at AS "finishedAt", u.username AS "createdBy"
         FROM directory.import_jobs j LEFT JOIN identity.users u ON u.id = j.created_by
        ORDER BY j.created_at DESC LIMIT 200`,
    );
    return { items: rows };
  });

  app.get('/imports/:id', { preHandler: guard('imports.run') }, async (req) => {
    const { id } = IdParams.parse(req.params);
    const { rows } = await ctx.db.query(
      `SELECT id, filename, target_group AS "targetGroup", status, dry_run AS "dryRun",
              total_rows AS "totalRows", ok_rows AS "okRows", error_rows AS "errorRows", errors,
              created_at AS "createdAt"
         FROM directory.import_jobs WHERE id = $1`, [id],
    );
    if (!rows[0]) throw notFound('Importación no encontrada');
    return rows[0];
  });
}
