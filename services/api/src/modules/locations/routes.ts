import type { FastifyInstance } from 'fastify';
import { z } from 'zod';
import { withTransaction } from '../../db/pool.js';
import { notFound } from '../../lib/errors.js';
import { guard, requireUser } from '../../plugins/auth.js';
import { writeAudit } from '../audit/audit-writer.js';
import { toPersonDto } from '../persons/dto.js';
import { findPersonById } from '../persons/repo.js';
import { visibilityFor } from '../persons/routes.js';
import { LocationInput, VerifyBody } from '../persons/schemas.js';
import { upsertLocation, verifyLocation } from './location-service.js';

const IdParams = z.object({ id: z.uuid() });

export async function locationRoutes(app: FastifyInstance): Promise<void> {
  const { ctx } = app;

  app.put('/persons/:id/location', { preHandler: guard('locations.write') }, async (req) => {
    const { id } = IdParams.parse(req.params);
    const body = LocationInput.parse(req.body);
    const user = requireUser(req);
    const v = visibilityFor(ctx, req);
    if (!(await findPersonById(ctx.db, id, v))) throw notFound('Persona no encontrada o sin permiso');
    const allowed = await ctx.settings.allowedBBox();
    await withTransaction(ctx.db, async (c) => {
      await upsertLocation(c, id, body, user.id, allowed);
      await writeAudit(c, req, {
        action: 'location.set', entityType: 'person', entityId: id,
        details: {
          coordSource: body.coordSource, precisionLevel: body.precisionLevel,
          addressGranularity: body.addressGranularity,
        },
      });
    });
    return toPersonDto((await findPersonById(ctx.db, id, v))!, user);
  });

  app.post('/persons/:id/location/verify', { preHandler: guard('locations.verify') }, async (req) => {
    const { id } = IdParams.parse(req.params);
    const body = VerifyBody.parse(req.body ?? {});
    const user = requireUser(req);
    const v = visibilityFor(ctx, req);
    if (!(await findPersonById(ctx.db, id, v))) throw notFound('Persona no encontrada o sin permiso');
    await withTransaction(ctx.db, async (c) => {
      const ok = await verifyLocation(c, id, user.id, body.status, body.precisionLevel);
      if (!ok) throw notFound('La persona no tiene ubicación registrada');
      await writeAudit(c, req, {
        action: 'location.verify', entityType: 'person', entityId: id,
        details: { status: body.status, precisionLevel: body.precisionLevel },
      });
    });
    return toPersonDto((await findPersonById(ctx.db, id, v))!, user);
  });

  app.delete('/persons/:id/location', { preHandler: guard('locations.write') }, async (req) => {
    const { id } = IdParams.parse(req.params);
    const v = visibilityFor(ctx, req);
    if (!(await findPersonById(ctx.db, id, v))) throw notFound('Persona no encontrada o sin permiso');
    await withTransaction(ctx.db, async (c) => {
      await c.query('DELETE FROM geo.person_locations WHERE person_id = $1', [id]);
      await writeAudit(c, req, { action: 'location.delete', entityType: 'person', entityId: id });
    });
    return { ok: true };
  });
}
