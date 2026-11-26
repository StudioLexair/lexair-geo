import type { FastifyInstance, FastifyRequest } from 'fastify';
import { z } from 'zod';
import { withTransaction } from '../../db/pool.js';
import { forbidden, notFound } from '../../lib/errors.js';
import { buildPage } from '../../lib/pagination.js';
import { allowedGroups, canSeeRestricted, guard, requireUser } from '../../plugins/auth.js';
import type { AppContext, GroupCode } from '../../types.js';
import { writeAudit } from '../audit/audit-writer.js';
import { upsertLocation } from '../locations/location-service.js';
import { toPersonDto } from './dto.js';
import { COUNT_CAP, findPersonById, searchPersons, setMemberships, type Visibility } from './repo.js';
import { CreatePersonBody, SearchPersonsQuery, SetGroupsBody, UpdatePersonBody } from './schemas.js';

const IdParams = z.object({ id: z.uuid() });

export function visibilityFor(ctx: AppContext, req: FastifyRequest, groups?: GroupCode[]): Visibility {
  const user = requireUser(req);
  return { groupIds: allowedGroups(ctx, user, groups), restricted: canSeeRestricted(user) };
}

function groupIdsFor(ctx: AppContext, codes: GroupCode[]): number[] {
  return ctx.groups.filter((g) => codes.includes(g.code)).map((g) => g.id);
}

const FIELD_MAP: Record<string, string> = {
  givenNames: 'given_names', familyNames: 'family_names', phone: 'phone', notes: 'notes',
  cdr: 'cdr', defenseZone: 'defense_zone',
  visibility: 'visibility', consentStatus: 'consent_status', dataSource: 'data_source',
  retentionUntil: 'retention_until',
};

export async function personRoutes(app: FastifyInstance): Promise<void> {
  const { ctx } = app;

  app.get('/persons', { preHandler: guard('persons.read') }, async (req) => {
    const q = SearchPersonsQuery.parse(req.query);
    const v = visibilityFor(ctx, req, q.groups);
    const { rows, total } = await searchPersons(ctx.db, q, v);
    const user = requireUser(req);
    return buildPage(rows.map((r) => toPersonDto(r, user)), q, total, COUNT_CAP);
  });

  app.get('/persons/:id', { preHandler: guard('persons.read') }, async (req) => {
    const { id } = IdParams.parse(req.params);
    const row = await findPersonById(ctx.db, id, visibilityFor(ctx, req));
    if (!row) throw notFound('Persona no encontrada o sin permiso');
    return toPersonDto(row, requireUser(req));
  });

  app.post('/persons', { preHandler: guard('persons.write') }, async (req, reply) => {
    const user = requireUser(req);
    const body = CreatePersonBody.parse(req.body);
    allowedGroups(ctx, user, body.groups); // solo grupos que puede consultar
    if (body.location && !user.permissions.has('locations.write')) {
      throw forbidden('Requiere permiso locations.write para registrar ubicación');
    }
    const allowedBBox = await ctx.settings.allowedBBox();
    const id = await withTransaction(ctx.db, async (c) => {
      const { rows } = await c.query<{ id: string }>(
        `INSERT INTO directory.persons (code, given_names, family_names, phone, notes, visibility,
           consent_status, consent_recorded_at, data_source, retention_until, created_by)
         VALUES ($1,$2,$3,$4,$5,$6,$7, CASE WHEN $7 = 'granted' THEN now() END, $8, $9, $10)
         RETURNING id`,
        [body.code, body.givenNames, body.familyNames, body.phone ?? null, body.notes ?? null,
          body.visibility, body.consentStatus, body.dataSource, body.retentionUntil ?? null, user.id],
      );
      const pid = rows[0]!.id;
      await setMemberships(c, pid, groupIdsFor(ctx, body.groups), user.id);
      if (body.location) await upsertLocation(c, pid, body.location, user.id, allowedBBox);
      await writeAudit(c, req, {
        action: 'person.create', entityType: 'person', entityId: pid,
        details: { code: body.code, groups: body.groups, withLocation: Boolean(body.location) },
      });
      return pid;
    });
    const row = await findPersonById(ctx.db, id, visibilityFor(ctx, req));
    reply.code(201);
    return toPersonDto(row!, user);
  });

  app.patch('/persons/:id', { preHandler: guard('persons.write') }, async (req) => {
    const { id } = IdParams.parse(req.params);
    const body = UpdatePersonBody.parse(req.body);
    const v = visibilityFor(ctx, req);
    if (!(await findPersonById(ctx.db, id, v))) throw notFound('Persona no encontrada o sin permiso');
    const sets: string[] = [];
    const params: unknown[] = [id];
    for (const [k, val] of Object.entries(body)) {
      const col = FIELD_MAP[k];
      if (!col) continue;
      params.push(val ?? null);
      sets.push(`${col} = $${params.length}`);
      if (k === 'consentStatus' && val === 'granted') sets.push('consent_recorded_at = now()');
    }
    await withTransaction(ctx.db, async (c) => {
      await c.query(`UPDATE directory.persons SET ${sets.join(', ')} WHERE id = $1`, params);
      await writeAudit(c, req, {
        action: 'person.update', entityType: 'person', entityId: id, details: { fields: Object.keys(body) },
      });
    });
    return toPersonDto((await findPersonById(ctx.db, id, v))!, requireUser(req));
  });

  for (const [path, active] of [['deactivate', false], ['reactivate', true]] as const) {
    app.post(`/persons/:id/${path}`, { preHandler: guard('persons.write') }, async (req) => {
      const { id } = IdParams.parse(req.params);
      const user = requireUser(req);
      const v = visibilityFor(ctx, req);
      if (!(await findPersonById(ctx.db, id, v))) throw notFound('Persona no encontrada o sin permiso');
      await withTransaction(ctx.db, async (c) => {
        await c.query(
          `UPDATE directory.persons SET is_active = $2,
             deactivated_at = CASE WHEN $2 THEN NULL ELSE now() END,
             deactivated_by = CASE WHEN $2 THEN NULL ELSE $3::uuid END
           WHERE id = $1`,
          [id, active, user.id],
        );
        await writeAudit(c, req, { action: `person.${path}`, entityType: 'person', entityId: id });
      });
      return toPersonDto((await findPersonById(ctx.db, id, v))!, user);
    });
  }

  app.put('/persons/:id/groups', { preHandler: guard('groups.manage') }, async (req) => {
    const { id } = IdParams.parse(req.params);
    const body = SetGroupsBody.parse(req.body);
    const user = requireUser(req);
    const v = visibilityFor(ctx, req);
    if (!(await findPersonById(ctx.db, id, v))) throw notFound('Persona no encontrada o sin permiso');
    await withTransaction(ctx.db, async (c) => {
      await setMemberships(c, id, groupIdsFor(ctx, body.groups), user.id);
      await writeAudit(c, req, {
        action: 'person.groups_set', entityType: 'person', entityId: id, details: { groups: body.groups },
      });
    });
    return toPersonDto((await findPersonById(ctx.db, id, v))!, user);
  });
}
