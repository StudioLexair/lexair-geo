import type { FastifyInstance } from 'fastify';
import { z } from 'zod';
import { withTransaction } from '../../db/pool.js';
import { badRequest, forbidden, notFound } from '../../lib/errors.js';
import { assertCoordinate, parseBBox } from '../../lib/geo.js';
import { normalizeText } from '../../lib/text.js';
import { PaginationQuery } from '../../lib/pagination.js';
import { guard, requireUser } from '../../plugins/auth.js';
import { writeAudit } from '../audit/audit-writer.js';

const IdParams = z.object({ id: z.uuid() });
const phone = z.string().trim().regex(/^[0-9 +()-]{5,25}$/).nullish();

/**
 * Personal de la fuerza (militares y colaboradores). Cada ficha puede llevar
 * residencia (punto) para responder «¿quién vive cerca de este preso?» y un
 * área asignada (zona dibujada en el mapa).
 */
const UpsertPersonnelBase = z.object({
  code: z.string().trim().toUpperCase().regex(/^[A-Z0-9][A-Z0-9-]{2,31}$/).nullish(),
  fullName: z.string().trim().min(3).max(160),
  rank: z.string().trim().max(80).nullish(),
  unit: z.string().trim().max(160).nullish(),
  phone,
  phoneAlt: phone,
  addressText: z.string().trim().max(300).nullish(),
  municipalityId: z.number().int().positive().nullish(),
  zoneId: z.uuid().nullish(),
  roleNote: z.string().trim().max(200).nullish(),
  isActive: z.boolean().optional(),
});
/** Alta completa: exige algún dato de contexto. En PATCH se valida parcial. */
export const UpsertPersonnel = UpsertPersonnelBase.refine(
  (o) => (o.addressText != null || o.municipalityId != null || o.rank != null || o.unit != null),
  'Indique al menos grado, unidad o dirección de residencia');

const PersonnelLocation = z.object({
  lat: z.number(),
  lon: z.number(),
  addressText: z.string().trim().max(300).nullish(),
  municipalityId: z.number().int().positive().nullish(),
});

const PersonnelQuery = PaginationQuery.extend({
  q: z.string().trim().max(120).optional(),
  zoneId: z.uuid().optional(),
  bbox: z.string().max(120).optional(),
  status: z.enum(['active', 'inactive', 'all']).default('active'),
});

export type PersonnelRow = {
  id: string; code: string | null; full_name: string; rank: string | null; unit: string | null;
  phone: string | null; phone_alt: string | null; address_text: string | null;
  municipality_id: number | null; municipality: string | null;
  zone_id: string | null; zone_name: string | null; role_note: string | null;
  geom: string | null; lat: number | null; lon: number | null;
  is_active: boolean; is_synthetic: boolean; data_source: string; external_ref: string | null;
  distance_m?: number | null;
  total?: number;
  created_at: Date; updated_at: Date;
};

const PERSONNEL_SELECT = `
  SELECT pe.id, pe.code, pe.full_name, pe.rank, pe.unit, pe.phone, pe.phone_alt, pe.address_text,
         pe.municipality_id, mu.name AS municipality, pe.zone_id, z.name AS zone_name,
         pe.role_note, pe.is_active, pe.is_synthetic, pe.data_source, pe.external_ref,
         ST_Y(pe.geom::geometry) AS lat, ST_X(pe.geom::geometry) AS lon,
         pe.created_at, pe.updated_at
    FROM directory.personnel pe
    LEFT JOIN geo.municipalities mu ON mu.id = pe.municipality_id
    LEFT JOIN geo.zones z ON z.id = pe.zone_id`;

export function personnelDto(r: PersonnelRow, exact: boolean) {
  const hasPoint = r.lat != null && r.lon != null;
  return {
    id: r.id,
    code: r.code,
    fullName: r.full_name,
    rank: r.rank,
    unit: r.unit,
    phone: r.phone,
    phoneAlt: r.phone_alt,
    addressText: exact ? r.address_text : null,
    municipalityId: r.municipality_id,
    municipality: r.municipality,
    zone: r.zone_id != null ? { id: r.zone_id, name: r.zone_name } : null,
    roleNote: r.role_note,
    isActive: r.is_active,
    isSynthetic: r.is_synthetic,
    dataSource: r.data_source,
    location: hasPoint
      ? { lat: exact ? r.lat : null, lon: exact ? r.lon : null, exact }
      : null,
    createdAt: r.created_at.toISOString(),
    updatedAt: r.updated_at.toISOString(),
  };
}

export async function personnelRoutes(app: FastifyInstance): Promise<void> {
  const { ctx } = app;

  app.get('/personnel', { preHandler: guard('personnel.read') }, async (req) => {
    const q = PersonnelQuery.parse(req.query);
    const user = requireUser(req);
    const exact = user.permissions.has('locations.exact.read');
    const params: unknown[] = [];
    const where: string[] = [];
    if (q.status !== 'all') where.push(`pe.is_active = $${params.push(q.status === 'active')}`);
    if (q.zoneId) { params.push(q.zoneId); where.push(`pe.zone_id = $${params.length}`); }
    if (q.bbox) {
      const b = parseBBox(q.bbox);
      params.push(b.west, b.south, b.east, b.north);
      const i = params.length - 3;
      where.push(`pe.geom && ST_MakeEnvelope($${i}, $${i + 1}, $${i + 2}, $${i + 3}, 4326)`);
    }
    const term = q.q?.trim();
    if (term) {
      const norm = normalizeText(term);
      params.push(term.toUpperCase(), `%${norm}%`);
      const [c, l] = [params.length - 1, params.length];
      where.push(`(pe.full_name_norm LIKE $${l} OR pe.code = $${c} OR pe.phone LIKE $${l} OR pe.unit ILIKE $${l})`);
    }
    const whereSql = where.length ? `WHERE ${where.join(' AND ')}` : '';
    params.push(q.pageSize, (q.page - 1) * q.pageSize);
    const { rows } = await ctx.db.query<PersonnelRow>(
      `SELECT x.id, x.code, x.full_name, x.rank, x.unit, x.phone, x.phone_alt, x.address_text,
              x.municipality_id, x.municipality, x.zone_id, x.zone_name, x.role_note,
              x.is_active, x.is_synthetic, x.data_source, x.external_ref,
              x.lat, x.lon, x.created_at, x.updated_at, x.total
         FROM (SELECT pe.id, pe.code, pe.full_name, pe.rank, pe.unit, pe.phone, pe.phone_alt,
                      pe.address_text, pe.municipality_id, mu.name AS municipality,
                      pe.zone_id, z.name AS zone_name, pe.role_note, pe.is_active,
                      pe.is_synthetic, pe.data_source, pe.external_ref,
                      ST_Y(pe.geom::geometry) AS lat, ST_X(pe.geom::geometry) AS lon,
                      pe.created_at, pe.updated_at, count(*) OVER () AS total
                 FROM directory.personnel pe
                 LEFT JOIN geo.municipalities mu ON mu.id = pe.municipality_id
                 LEFT JOIN geo.zones z ON z.id = pe.zone_id
                 ${whereSql}
                ORDER BY pe.full_name LIMIT $${params.length - 1} OFFSET $${params.length}) x`,
      params,
    );
    const total = rows[0]?.total ?? (q.page - 1) * q.pageSize + rows.length;
    return {
      items: rows.map((r) => personnelDto(r, exact)),
      page: q.page, pageSize: q.pageSize, total: Math.min(total, 10000),
      totalIsCapped: total > 10000,
    };
  });

  app.get('/personnel/near', { preHandler: guard('personnel.read') }, async (req) => {
    const q = z.object({
      lat: z.coerce.number(), lon: z.coerce.number(),
      radius: z.coerce.number().int().min(10).max(200000).optional(),
      zoneId: z.uuid().optional(),
    }).parse(req.query);
    assertCoordinate(q.lat, q.lon, await ctx.settings.allowedBBox());
    const user = requireUser(req);
    const exact = user.permissions.has('locations.exact.read');
    const radius = q.radius ?? await ctx.settings.number('personnel.near_radius_m', 5000);
    const max = await ctx.settings.number('personnel.max_results', 50);
    const { rows } = await ctx.db.query<PersonnelRow>(
      `SELECT id.id, id.code, id.full_name, id.rank, id.unit, id.phone, id.phone_alt,
              id.address_text, id.municipality_id, mu.name AS municipality,
              id.zone_id, z.name AS zone_name, id.role_note, id.is_active, id.is_synthetic,
              id.data_source, id.created_at, id.updated_at,
              ST_Y(id.geom::geometry) AS lat, ST_X(id.geom::geometry) AS lon,
              round(ST_Distance(id.geom, pt.g))::int AS distance_m
         FROM (SELECT ST_SetSRID(ST_MakePoint($1, $2), 4326)::geography AS g) pt,
              directory.personnel id
         LEFT JOIN geo.municipalities mu ON mu.id = id.municipality_id
         LEFT JOIN geo.zones z ON z.id = id.zone_id
        WHERE id.is_active AND id.geom IS NOT NULL AND ST_DWithin(id.geom, pt.g, $3::int)
        ORDER BY id.geom <-> pt.g
        LIMIT $4`,
      [q.lon, q.lat, radius, max],
    );
    return { items: rows.map((r) => ({ ...personnelDto(r, exact), distanceM: r.distance_m })), radiusM: radius };
  });

  app.get('/personnel/:id', { preHandler: guard('personnel.read') }, async (req) => {
    const { id } = IdParams.parse(req.params);
    const { rows } = await ctx.db.query<PersonnelRow>(`${PERSONNEL_SELECT} WHERE pe.id = $1`, [id]);
    if (!rows[0]) throw notFound('Personal no encontrado');
    return personnelDto(rows[0]!, requireUser(req).permissions.has('locations.exact.read'));
  });

  app.post('/personnel', { preHandler: guard('personnel.write') }, async (req, reply) => {
    const user = requireUser(req);
    const b = UpsertPersonnel.parse(req.body);
    const allowed = await ctx.settings.allowedBBox();
    const dup = b.code
      ? await ctx.db.query('SELECT 1 FROM directory.personnel WHERE code = $1', [b.code])
      : { rowCount: 0 };
    if ((dup.rowCount ?? 0) > 0) throw badRequest('Ya existe personal con ese código');
    const id = await withTransaction(ctx.db, async (c) => {
      const { rows } = await c.query<{ id: string }>(
        `INSERT INTO directory.personnel (code, full_name, rank, unit, phone, phone_alt, address_text,
           municipality_id, zone_id, role_note, data_source, created_by)
         VALUES ($1,$2,$3,$4,$5,$6,$7,$8,$9,$10,'manual',$11) RETURNING id`,
        [b.code ?? null, b.fullName, b.rank ?? null, b.unit ?? null, b.phone ?? null,
          b.phoneAlt ?? null, b.addressText ?? null, b.municipalityId ?? null,
          b.zoneId ?? null, b.roleNote ?? null, user.id],
      );
      await writeAudit(c, req, { action: 'personnel.create', entityType: 'personnel',
        entityId: rows[0]!.id, details: { fullName: b.fullName } });
      return rows[0]!.id;
    });
    reply.code(201);
    const { rows } = await ctx.db.query<PersonnelRow>(`${PERSONNEL_SELECT} WHERE pe.id = $1`, [id]);
    return personnelDto(rows[0]!, user.permissions.has('locations.exact.read'));
  });

  app.patch('/personnel/:id', { preHandler: guard('personnel.write') }, async (req) => {
    const { id } = IdParams.parse(req.params);
    const b = UpsertPersonnelBase.partial()
      .refine((o) => Object.keys(o).length > 0, 'Sin cambios').parse(req.body);
    const user = requireUser(req);
    const map: Record<string, string> = {
      code: 'code', fullName: 'full_name', rank: 'rank', unit: 'unit', phone: 'phone',
      phoneAlt: 'phone_alt', addressText: 'address_text', municipalityId: 'municipality_id',
      zoneId: 'zone_id', roleNote: 'role_note', isActive: 'is_active',
    };
    const sets: string[] = [];
    const params: unknown[] = [id];
    for (const [k, val] of Object.entries(b)) {
      const col = map[k];
      if (!col) continue;
      params.push(val ?? (col === 'is_active' ? false : null));
      sets.push(`${col} = $${params.length}`);
    }
    await withTransaction(ctx.db, async (c) => {
      const res = await c.query(`UPDATE directory.personnel SET ${sets.join(', ')} WHERE id = $1`, params);
      if ((res.rowCount ?? 0) === 0) throw notFound('Personal no encontrado');
      await writeAudit(c, req, { action: 'personnel.update', entityType: 'personnel', entityId: id,
        details: { fields: Object.keys(b) } });
    });
    const { rows } = await ctx.db.query<PersonnelRow>(`${PERSONNEL_SELECT} WHERE pe.id = $1`, [id]);
    return personnelDto(rows[0]!, user.permissions.has('locations.exact.read'));
  });

  app.delete('/personnel/:id', { preHandler: guard('personnel.write') }, async (req) => {
    const { id } = IdParams.parse(req.params);
    await withTransaction(ctx.db, async (c) => {
      const res = await c.query('DELETE FROM directory.personnel WHERE id = $1', [id]);
      if ((res.rowCount ?? 0) === 0) throw notFound('Personal no encontrado');
      await writeAudit(c, req, { action: 'personnel.delete', entityType: 'personnel', entityId: id });
    });
    return { ok: true };
  });

  /**
   * Personal de la fuerza que vive cerca de una persona (por ejemplo, un
   * interno en pase): «¿quién tiene la residencia cerca de este preso?».
   */
  app.get('/persons/:id/nearby-personnel', { preHandler: guard('personnel.read') }, async (req) => {
    const { id } = IdParams.parse(req.params);
    const q = z.object({ radius: z.coerce.number().int().min(10).max(200000).optional() })
      .parse(req.query);
    const user = requireUser(req);
    const exact = user.permissions.has('locations.exact.read');
    const radius = q.radius ?? await ctx.settings.number('personnel.near_radius_m', 5000);
    const max = await ctx.settings.number('personnel.max_results', 50);
    const { rows } = await ctx.db.query<PersonnelRow>(
      `SELECT pe.id, pe.code, pe.full_name, pe.rank, pe.unit, pe.phone, pe.phone_alt,
              pe.address_text, pe.municipality_id, mu.name AS municipality,
              pe.zone_id, z.name AS zone_name, pe.role_note, pe.is_active, pe.is_synthetic,
              pe.data_source, pe.created_at, pe.updated_at,
              ST_Y(pe.geom::geometry) AS lat, ST_X(pe.geom::geometry) AS lon,
              round(ST_Distance(pe.geom, l.geom))::int AS distance_m
         FROM geo.person_locations l, directory.personnel pe
         LEFT JOIN geo.municipalities mu ON mu.id = pe.municipality_id
         LEFT JOIN geo.zones z ON z.id = pe.zone_id
        WHERE l.person_id = $1 AND pe.is_active AND pe.geom IS NOT NULL
          AND ST_DWithin(pe.geom, l.geom, $2::int)
        ORDER BY pe.geom <-> l.geom
        LIMIT $3`,
      [id, radius, max],
    );
    return { items: rows.map((r) => ({ ...personnelDto(r, exact), distanceM: r.distance_m })), radiusM: radius };
  });

  /** Residencia del personal (punto fijo, misma política que personas). */
  app.put('/personnel/:id/location', { preHandler: guard('personnel.write') }, async (req) => {
    const { id } = IdParams.parse(req.params);
    const b = PersonnelLocation.parse(req.body);
    assertCoordinate(b.lat, b.lon, await ctx.settings.allowedBBox());
    await withTransaction(ctx.db, async (c) => {
      const res = await c.query(
        `UPDATE directory.personnel
            SET geom = ST_SetSRID(ST_MakePoint($2, $1), 4326)::geography,
                address_text = COALESCE($3, address_text),
                municipality_id = COALESCE($4, municipality_id,
                  (SELECT m.id FROM geo.municipalities m WHERE m.boundary IS NOT NULL
                     AND ST_Contains(m.boundary, ST_SetSRID(ST_MakePoint($2, $1), 4326)) LIMIT 1))
          WHERE id = $5`,
        [b.lat, b.lon, b.addressText ?? null, b.municipalityId ?? null, id],
      );
      if ((res.rowCount ?? 0) === 0) throw notFound('Personal no encontrado');
      await writeAudit(c, req, { action: 'personnel.location_set', entityType: 'personnel', entityId: id });
    });
    const { rows } = await ctx.db.query<PersonnelRow>(`${PERSONNEL_SELECT} WHERE pe.id = $1`, [id]);
    return personnelDto(rows[0]!, requireUser(req).permissions.has('locations.exact.read'));
  });
}
