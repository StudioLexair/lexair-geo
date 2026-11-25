import type { FastifyInstance } from 'fastify';
import { z } from 'zod';
import { withTransaction } from '../../db/pool.js';
import { assertCoordinate } from '../../lib/geo.js';
import { notFound } from '../../lib/errors.js';
import { guard, requireUser } from '../../plugins/auth.js';
import { writeAudit } from '../audit/audit-writer.js';
import { geocode } from './repo.js';

const SearchQuery = z.object({
  q: z.string().trim().min(2).max(160),
  municipalityId: z.coerce.number().int().positive().optional(),
  limit: z.coerce.number().int().min(1).max(25).default(10),
});
const ReverseQuery = z.object({ lat: z.coerce.number(), lon: z.coerce.number() });
const AddressBody = z.object({
  streetName: z.string().trim().min(1).max(200),
  houseNumber: z.string().trim().max(20).nullish(),
  municipalityId: z.number().int().positive().nullish(),
  localityId: z.number().int().positive().nullish(),
  lat: z.number(),
  lon: z.number(),
});
const AliasBody = z.object({
  alias: z.string().trim().min(1).max(200),
  streetName: z.string().trim().min(1).max(200),
  municipalityId: z.number().int().positive().nullish(),
});
const IdParams = z.object({ id: z.coerce.number().int().positive() });

export async function geocodingRoutes(app: FastifyInstance): Promise<void> {
  const { ctx } = app;
  const read = guard('persons.read');
  const manage = guard('geocoding.manage');

  app.get('/geocoding/search', { preHandler: read }, async (req) => {
    const q = SearchQuery.parse(req.query);
    const items = await geocode(ctx.db, q.q, { municipalityId: q.municipalityId, limit: q.limit });
    return { query: q.q, items, found: items.length > 0 };
  });

  app.get('/geocoding/reverse', { preHandler: read }, async (req) => {
    const q = ReverseQuery.parse(req.query);
    assertCoordinate(q.lat, q.lon, await ctx.settings.allowedBBox());
    const { rows } = await ctx.db.query(
      `WITH pt AS (SELECT ST_SetSRID(ST_MakePoint($2, $1), 4326) AS g)
       SELECT
         (SELECT json_build_object('id', m.id, 'name', m.name) FROM geo.municipalities m, pt
           WHERE m.boundary IS NOT NULL AND ST_Contains(m.boundary, pt.g) LIMIT 1) AS municipality,
         (SELECT json_build_object('id', l.id, 'name', l.name, 'kind', l.kind,
                 'distanceM', round(ST_Distance(l.centroid, pt.g::geography)))
            FROM geo.localities l, pt WHERE ST_DWithin(l.centroid, pt.g::geography, 3000)
           ORDER BY l.centroid <-> pt.g::geography LIMIT 1) AS locality,
         (SELECT json_build_object('id', a.id, 'label', a.street_name || coalesce(' #' || a.house_number, ''),
                 'granularity', a.granularity, 'distanceM', round(ST_Distance(a.geom, pt.g::geography)))
            FROM geo.addresses a, pt WHERE ST_DWithin(a.geom, pt.g::geography, 300)
           ORDER BY a.geom <-> pt.g::geography LIMIT 1) AS nearest_address`,
      [q.lat, q.lon],
    );
    const r = rows[0] ?? {};
    return {
      lat: q.lat, lon: q.lon,
      municipality: r.municipality ?? null,
      locality: r.locality ?? null,
      nearestAddress: r.nearest_address ?? null,
    };
  });

  app.get('/geocoding/municipalities', { preHandler: read }, async () => {
    const { rows } = await ctx.db.query(
      `SELECT m.id, m.code, m.name, m.province, m.osm_id AS "osmId", ds.attribution AS source,
              ds.is_synthetic AS "isSynthetic",
              CASE WHEN m.boundary IS NULL THEN NULL ELSE
                json_build_array(ST_XMin(m.boundary), ST_YMin(m.boundary), ST_XMax(m.boundary), ST_YMax(m.boundary))
              END AS bbox,
              (SELECT count(*)::int FROM geo.localities l WHERE l.municipality_id = m.id) AS localities
         FROM geo.municipalities m JOIN geo.data_sources ds ON ds.code = m.source_code
        ORDER BY m.name`,
    );
    return { items: rows };
  });

  app.get('/geocoding/aliases', { preHandler: read }, async () => {
    const { rows } = await ctx.db.query(
      `SELECT id, alias, street_name AS "streetName", municipality_id AS "municipalityId", created_at AS "createdAt"
         FROM geo.street_aliases ORDER BY alias LIMIT 1000`,
    );
    return { items: rows };
  });

  app.post('/geocoding/aliases', { preHandler: manage }, async (req, reply) => {
    const b = AliasBody.parse(req.body);
    const id = await withTransaction(ctx.db, async (c) => {
      const { rows } = await c.query<{ id: number }>(
        `INSERT INTO geo.street_aliases (alias, street_name, municipality_id, created_by)
         VALUES ($1, $2, $3, $4) RETURNING id`,
        [b.alias, b.streetName, b.municipalityId ?? null, requireUser(req).id],
      );
      await writeAudit(c, req, { action: 'geocoding.alias_create', entityType: 'street_alias',
        entityId: String(rows[0]!.id), details: { alias: b.alias, streetName: b.streetName } });
      return rows[0]!.id;
    });
    reply.code(201);
    return { id };
  });

  app.delete('/geocoding/aliases/:id', { preHandler: manage }, async (req) => {
    const { id } = IdParams.parse(req.params);
    await withTransaction(ctx.db, async (c) => {
      const r = await c.query('DELETE FROM geo.street_aliases WHERE id = $1', [id]);
      if (!r.rowCount) throw notFound();
      await writeAudit(c, req, { action: 'geocoding.alias_delete', entityType: 'street_alias', entityId: String(id) });
    });
    return { ok: true };
  });

  /** Direcciones dadas de alta localmente por administradores (no OSM). */
  app.get('/geocoding/addresses', { preHandler: manage }, async () => {
    const { rows } = await ctx.db.query(
      `SELECT a.id, a.street_name AS "streetName", a.house_number AS "houseNumber", a.granularity,
              a.municipality_id AS "municipalityId", m.name AS municipality,
              ST_Y(a.geom::geometry) AS lat, ST_X(a.geom::geometry) AS lon
         FROM geo.addresses a LEFT JOIN geo.municipalities m ON m.id = a.municipality_id
        WHERE a.source_code = 'admin_local'
        ORDER BY a.street_name, a.house_number NULLS FIRST LIMIT 1000`,
    );
    return { items: rows };
  });

  app.post('/geocoding/addresses', { preHandler: manage }, async (req, reply) => {
    const b = AddressBody.parse(req.body);
    assertCoordinate(b.lat, b.lon, await ctx.settings.allowedBBox());
    const id = await withTransaction(ctx.db, async (c) => {
      const { rows } = await c.query<{ id: number }>(
        `INSERT INTO geo.addresses (street_name, house_number, municipality_id, locality_id,
           granularity, geom, source_code)
         VALUES ($1, $2, $3, $4, $5, ST_SetSRID(ST_MakePoint($7, $6), 4326)::geography, 'admin_local')
         RETURNING id`,
        [b.streetName, b.houseNumber ?? null, b.municipalityId ?? null, b.localityId ?? null,
          b.houseNumber ? 'dwelling' : 'street', b.lat, b.lon],
      );
      await writeAudit(c, req, { action: 'geocoding.address_create', entityType: 'address',
        entityId: String(rows[0]!.id), details: { streetName: b.streetName } });
      return rows[0]!.id;
    });
    reply.code(201);
    return { id };
  });

  app.delete('/geocoding/addresses/:id', { preHandler: manage }, async (req) => {
    const { id } = IdParams.parse(req.params);
    await withTransaction(ctx.db, async (c) => {
      const r = await c.query("DELETE FROM geo.addresses WHERE id = $1 AND source_code = 'admin_local'", [id]);
      if (!r.rowCount) throw notFound('Solo se eliminan direcciones creadas localmente');
      await writeAudit(c, req, { action: 'geocoding.address_delete', entityType: 'address', entityId: String(id) });
    });
    return { ok: true };
  });
}
