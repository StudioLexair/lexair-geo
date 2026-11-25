import type { FastifyInstance } from 'fastify';
import { z } from 'zod';
import { badRequest, notFound } from '../../lib/errors.js';
import { maskDistance, resolveRadius } from '../../lib/geo.js';
import { buildPage, offsetOf } from '../../lib/pagination.js';
import { guard, requireUser } from '../../plugins/auth.js';
import { writeAudit } from '../audit/audit-writer.js';
import { PERSON_JOINS, PERSON_SELECT, PERSON_VISIBLE, toPersonDto, type PersonRow } from '../persons/dto.js';
import { findPersonById } from '../persons/repo.js';
import { visibilityFor } from '../persons/routes.js';
import { NearbyQuery } from '../persons/schemas.js';

const IdParams = z.object({ id: z.uuid() });

export async function searchRoutes(app: FastifyInstance): Promise<void> {
  const { ctx } = app;

  app.get('/proximity/radii', { preHandler: guard('proximity.query') }, async (req) => {
    const user = requireUser(req);
    return {
      presets: await ctx.settings.numberList('proximity.radii_m', [100, 250, 500, 1000, 2000, 5000]),
      customAllowed: user.permissions.has('proximity.custom'),
      maxCustom: await ctx.settings.number('proximity.max_custom_radius_m', 10000),
    };
  });

  /**
   * Personas alrededor de otra persona. ST_DWithin sobre geography usa el
   * índice GiST y calcula distancias geodésicas reales en metros.
   */
  app.get('/persons/:id/nearby', { preHandler: guard('persons.read', 'proximity.query') }, async (req) => {
    const { id } = IdParams.parse(req.params);
    const q = NearbyQuery.parse(req.query);
    const user = requireUser(req);
    const radius = resolveRadius(q.radius, {
      presets: await ctx.settings.numberList('proximity.radii_m', [100, 250, 500, 1000, 2000, 5000]),
      maxCustom: await ctx.settings.number('proximity.max_custom_radius_m', 10000),
      canCustom: user.permissions.has('proximity.custom'),
    });
    const maxResults = await ctx.settings.number('proximity.max_results', 500);
    if (offsetOf(q) >= maxResults) throw badRequest(`Máximo ${maxResults} resultados por consulta`);
    const v = visibilityFor(ctx, req, q.groups);
    const origin = await findPersonById(ctx.db, id, visibilityFor(ctx, req));
    if (!origin) throw notFound('Persona no encontrada o sin permiso');
    if (!origin.precision_level) throw badRequest('La persona seleccionada no tiene ubicación registrada');

    const limit = Math.min(q.pageSize, maxResults - offsetOf(q));
    // Búsqueda KNN ordenada por el índice GiST (operador <->): lee como máximo
    // maxResults + 1 personas visibles en orden de distancia, sea cual sea la
    // densidad (en el centro de Santa Clara hay >50 000 personas en 5 km).
    // Las que quedan dentro del radio son un prefijo de ese orden, así que la
    // misma consulta da la página y el total (limitado a maxResults).
    // Distancia esférica (error < 0,5 % frente al elipsoide).
    const { rows } = await ctx.db.query<PersonRow & { total: number }>(
      `WITH near AS MATERIALIZED (
         SELECT l.person_id, ST_Distance(l.geom, o.g, false) AS d
           FROM geo.person_locations l
           JOIN directory.persons p ON p.id = l.person_id
          CROSS JOIN (SELECT geom AS g FROM geo.person_locations WHERE person_id = $3) o
          WHERE l.person_id <> $3 AND p.is_active AND ${PERSON_VISIBLE}
          ORDER BY l.geom <-> (SELECT geom FROM geo.person_locations WHERE person_id = $3)
          LIMIT $7
       ), inside AS (SELECT person_id, d FROM near WHERE d <= $4),
       page AS (SELECT person_id, d FROM inside ORDER BY d, person_id LIMIT $5 OFFSET $6)
       ${PERSON_SELECT}, page.d AS distance_m, (SELECT count(*)::int FROM inside) AS total
       ${PERSON_JOINS}
       JOIN page ON page.person_id = p.id
       ORDER BY page.d, p.id`,
      [v.groupIds, v.restricted, id, radius, limit, offsetOf(q), maxResults + 1],
    );
    let total = rows[0]?.total;
    if (total === undefined) {
      // Página vacía (desplazamiento mayor que el total): contar igualmente.
      const c = await ctx.db.query<{ n: number }>(
        `SELECT count(*)::int AS n FROM (
           SELECT ST_Distance(l.geom, o.g, false) AS d
             FROM geo.person_locations l
             JOIN directory.persons p ON p.id = l.person_id
            CROSS JOIN (SELECT geom AS g FROM geo.person_locations WHERE person_id = $3) o
            WHERE l.person_id <> $3 AND p.is_active AND ${PERSON_VISIBLE}
            ORDER BY l.geom <-> (SELECT geom FROM geo.person_locations WHERE person_id = $3)
            LIMIT $5) t WHERE d <= $4`,
        [v.groupIds, v.restricted, id, radius, maxResults + 1],
      );
      total = c.rows[0]?.n ?? 0;
    }
    const count = { rows: [{ n: Math.min(total, maxResults) }] };
    const exact = user.permissions.has('locations.exact.read');
    await writeAudit(ctx.db, req, {
      action: 'proximity.query', entityType: 'person', entityId: id,
      details: { radius, groups: q.groups ?? 'allowed', results: count.rows[0]?.n ?? 0 },
    });
    const items = rows.map((r) => ({
      ...toPersonDto(r, user),
      distanceM: maskDistance(r.distance_m ?? 0, exact),
    }));
    return {
      origin: toPersonDto(origin, user),
      radiusM: radius,
      distancesRounded: !exact,
      ...buildPage(items, q, count.rows[0]?.n ?? 0, maxResults),
    };
  });
}
