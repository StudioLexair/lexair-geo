import type { FastifyInstance } from 'fastify';
import { z } from 'zod';
import { withTransaction } from '../../db/pool.js';
import { badRequest, forbidden, notFound } from '../../lib/errors.js';
import { assertCoordinate } from '../../lib/geo.js';
import { PaginationQuery } from '../../lib/pagination.js';
import { guard, requireUser } from '../../plugins/auth.js';
import { writeAudit } from '../audit/audit-writer.js';

const IdParams = z.object({ id: z.uuid() });

/**
 * Geometría de una zona. El círculo llega como centro + radio; el rectángulo
 * como dos esquinas opuestas; el polígono como anillo abierto (el servidor lo
 * cierra). Todo se materializa como POLYGON en PostGIS para poder preguntar
 * «¿qué zonas contienen este punto?» y «¿qué personas viven dentro?» con índice.
 */
const Vertex = z.object({ lat: z.number(), lon: z.number() });
const ZoneGeometry = z.discriminatedUnion('kind', [
  z.object({ kind: z.literal('circle'), lat: z.number(), lon: z.number(), radiusM: z.number().int().min(5).max(100000) }),
  z.object({
    kind: z.literal('rectangle'),
    north: z.number(), south: z.number(), east: z.number(), west: z.number(),
  }),
  z.object({ kind: z.literal('polygon'), vertices: z.array(Vertex).min(3).max(2000) }),
]);
export type ZoneGeometry = z.infer<typeof ZoneGeometry>;

const CreateZone = z.object({
  name: z.string().trim().min(1).max(120),
  description: z.string().trim().max(2000).nullish(),
  geometry: ZoneGeometry,
  labelText: z.string().trim().max(200).nullish(),
  showLabel: z.boolean().default(true),
  categoryId: z.number().int().positive().nullish(),
  colorHex: z.string().regex(/^#[0-9A-Fa-f]{6}$/).nullish(),
  fillOpacity: z.number().min(0).max(1).default(0.15),
  strokeWidth: z.number().min(0.5).max(10).default(2),
  isActive: z.boolean().default(true),
});

const UpdateZone = CreateZone.omit({ geometry: true }).partial()
  .refine((o) => Object.keys(o).length > 0, 'Sin cambios');

const ZoneListQuery = z.object({
  bbox: z.string().max(120).optional(),
  includeInactive: z.enum(['true', 'false']).default('false'),
  categoryId: z.coerce.number().int().positive().optional(),
});

const ContainingQuery = z.object({ lat: z.coerce.number(), lon: z.coerce.number() });

const AssignPersons = z.object({
  add: z.array(z.uuid()).max(2000).default([]),
  remove: z.array(z.uuid()).max(2000).default([]),
}).refine((o) => o.add.length + o.remove.length > 0, 'Nada que hacer');

/** WKT seguro: los números ya vienen validados por zod; no hay texto libre. */
function polygonWkt(vertices: Array<{ lat: number; lon: number }>): string {
  const closed = [...vertices, vertices[0]!];
  return `POLYGON((${closed.map((v) => `${v.lon} ${v.lat}`).join(', ')}))`;
}

/** Devuelve (wkt, vértices jsonb, centro/radio) para cada tipo de zona. */
function geometrySql(g: ZoneGeometry, maxRadiusM: number): {
  wkt: string; vertices: string; centerLat: number | null; centerLon: number | null; radiusM: number | null;
} {
  if (g.kind === 'circle') {
    if (g.radiusM > maxRadiusM) throw badRequest(`El radio máximo permitido es ${maxRadiusM} m`);
    return {
      wkt: `ST_Buffer(ST_GeomFromText('POINT(${g.lon} ${g.lat})', 4326)::geography, ${g.radiusM})::geometry`,
      vertices: JSON.stringify([{ lat: g.lat, lon: g.lon }]),
      centerLat: g.lat, centerLon: g.lon, radiusM: g.radiusM,
    };
  }
  if (g.kind === 'rectangle') {
    if (g.north <= g.south || g.east <= g.west) throw badRequest('Rectángulo incoherente');
    const verts = [
      { lat: g.south, lon: g.west }, { lat: g.south, lon: g.east },
      { lat: g.north, lon: g.east }, { lat: g.north, lon: g.west },
    ];
    return {
      wkt: `ST_GeomFromText('${polygonWkt(verts)}', 4326)`,
      vertices: JSON.stringify(verts),
      centerLat: (g.north + g.south) / 2, centerLon: (g.east + g.west) / 2, radiusM: null,
    };
  }
  return {
    wkt: `ST_GeomFromText('${polygonWkt(g.vertices)}', 4326)`,
    vertices: JSON.stringify(g.vertices),
    centerLat: null, centerLon: null, radiusM: null,
  };
}

export type ZoneRow = {
  id: string; name: string; description: string | null; kind: string;
  vertices: Array<{ lat: number; lon: number }> | null;
  center_lat: number | null; center_lon: number | null; radius_m: number | null;
  label_text: string | null; show_label: boolean;
  category_id: number | null; category_name: string | null;
  category_color: string | null; category_icon: string | null;
  color_hex: string | null; fill_opacity: string; stroke_width: string;
  is_active: boolean; is_synthetic: boolean;
  area_km2: string | null;
  members_count: number | null; manual_count: number | null;
  passes_inside: number | null; personnel_count: number | null;
  created_at: Date; updated_at: Date;
};

const ZONE_SELECT = `
  SELECT z.id, z.name, z.description, z.kind, z.vertices, z.center_lat, z.center_lon, z.radius_m,
         z.label_text, z.show_label, z.category_id, c.name AS category_name,
         c.color_hex AS category_color, c.icon AS category_icon,
         z.color_hex, z.fill_opacity, z.stroke_width, z.is_active, z.is_synthetic,
         round((ST_Area(z.geom) / 1000000.0)::numeric, 2)::text AS area_km2,
         z.created_at, z.updated_at,
         (SELECT count(*)::int FROM geo.zone_members m WHERE m.zone_id = z.id) AS members_count,
         (SELECT count(*)::int FROM geo.zone_members m WHERE m.zone_id = z.id AND m.source = 'manual') AS manual_count,
         (SELECT count(*)::int FROM directory.passes ps
            WHERE (ps.authorized_zone_id = z.id OR
                   EXISTS (SELECT 1 FROM geo.person_locations pl
                            WHERE pl.person_id = ps.person_id
                              AND ST_Contains(z.geom::geometry, pl.geom::geometry)))
              AND ps.returned_at IS NULL AND ps.cancelled_at IS NULL
              AND now() >= ps.starts_at AND now() <= ps.ends_at) AS passes_inside,
         (SELECT count(*)::int FROM directory.personnel pe
            WHERE pe.is_active AND pe.zone_id = z.id) AS personnel_count
    FROM geo.zones z LEFT JOIN geo.zone_categories c ON c.id = z.category_id`;

export function zoneDto(r: ZoneRow) {
  return {
    id: r.id,
    name: r.name,
    description: r.description,
    kind: r.kind,
    vertices: (r.vertices as Array<{ lat: number; lon: number }> | null) ?? [],
    center: r.center_lat != null && r.center_lon != null ? { lat: r.center_lat, lon: r.center_lon } : null,
    radiusM: r.radius_m,
    label: r.label_text,
    showLabel: r.show_label,
    category: r.category_id != null
      ? { id: r.category_id, name: r.category_name, colorHex: r.category_color, icon: r.category_icon }
      : null,
    colorHex: r.color_hex ?? r.category_color ?? '#0F6C81',
    fillOpacity: Number(r.fill_opacity),
    strokeWidth: Number(r.stroke_width),
    isActive: r.is_active,
    isSynthetic: r.is_synthetic,
    areaKm2: r.area_km2 ? Number(r.area_km2) : null,
    membersCount: r.members_count ?? 0,
    manualCount: r.manual_count ?? 0,
    passesInside: r.passes_inside ?? 0,
    personnelCount: r.personnel_count ?? 0,
    createdAt: r.created_at.toISOString(),
    updatedAt: r.updated_at.toISOString(),
  };
}

export type ZoneDto = ReturnType<typeof zoneDto>;

export async function zoneRoutes(app: FastifyInstance): Promise<void> {
  const { ctx } = app;

  app.get('/zones', { preHandler: guard('zones.read') }, async (req) => {
    const q = ZoneListQuery.parse(req.query);
    const where: string[] = [];
    const params: unknown[] = [];
    if (q.includeInactive === 'false') where.push('z.is_active');
    if (q.categoryId) { params.push(q.categoryId); where.push(`z.category_id = $${params.length}`); }
    if (q.bbox) {
      const parts = q.bbox.split(',').map(Number);
      if (parts.length !== 4 || parts.some((n) => !Number.isFinite(n))) throw badRequest('bbox incoherente');
      const [w, s, e, n] = parts;
      params.push(w, s, e, n);
      const b = params.length;
      where.push(`ST_Intersects(z.geom, ST_MakeEnvelope($${b - 3}, $${b - 2}, $${b - 1}, $${b}, 4326))`);
    }
    const sql = `${ZONE_SELECT} ${where.length ? `WHERE ${where.join(' AND ')}` : ''} ORDER BY z.created_at`;
    const { rows } = await ctx.db.query<ZoneRow>(sql, params);
    return { items: rows.map(zoneDto) };
  });

  /** ¿Qué zonas hay bajo este punto del mapa? (toque del usuario) */
  app.get('/zones/containing', { preHandler: guard('zones.read') }, async (req) => {
    const { lat, lon } = ContainingQuery.parse(req.query);
    assertCoordinate(lat, lon, await ctx.settings.allowedBBox());
    const { rows } = await ctx.db.query<ZoneRow>(
      `${ZONE_SELECT}
        WHERE z.is_active
          AND ST_Contains(z.geom::geometry, ST_SetSRID(ST_MakePoint($1, $2), 4326))
        ORDER BY ST_Area(z.geom)`,
      [lon, lat],
    );
    return { items: rows.map(zoneDto) };
  });

  app.get('/zones/categories', { preHandler: guard('zones.read') }, async () => {
    const { rows } = await ctx.db.query(
      `SELECT id, name, description, color_hex AS "colorHex", icon, sort_order AS "sortOrder",
              is_active AS "isActive",
              (SELECT count(*)::int FROM geo.zones z WHERE z.category_id = c.id) AS "zoneCount"
         FROM geo.zone_categories c ORDER BY sort_order, id`,
    );
    return { items: rows };
  });

  const CategoryBody = z.object({
    name: z.string().trim().min(1).max(80),
    description: z.string().trim().max(500).default(''),
    colorHex: z.string().regex(/^#[0-9A-Fa-f]{6}$/).default('#0F6C81'),
    icon: z.string().trim().min(1).max(60).default('label'),
    sortOrder: z.number().int().min(0).max(9999).default(0),
    isActive: z.boolean().default(true),
  });

  app.post('/zones/categories', { preHandler: guard('zones.write') }, async (req, reply) => {
    const b = CategoryBody.parse(req.body);
    const { rows } = await ctx.db.query<{ id: number }>(
      `INSERT INTO geo.zone_categories (name, description, color_hex, icon, sort_order, is_active)
       VALUES ($1,$2,$3,$4,$5,$6) RETURNING id`, [b.name, b.description, b.colorHex, b.icon, b.sortOrder, b.isActive]);
    await writeAudit(ctx.db, req, { action: 'zone_category.create', entityType: 'zone_category',
      entityId: String(rows[0]!.id), details: { name: b.name } });
    reply.code(201);
    return { id: rows[0]!.id };
  });

  app.patch('/zones/categories/:id', { preHandler: guard('zones.write') }, async (req) => {
    const id = z.coerce.number().int().positive().parse((req.params as { id: string }).id);
    const b = CategoryBody.partial().refine((o) => Object.keys(o).length > 0, 'Sin cambios').parse(req.body);
    const sets: string[] = [];
    const params: unknown[] = [id];
    for (const [k, col] of [['name', 'name'], ['description', 'description'], ['colorHex', 'color_hex'],
      ['icon', 'icon'], ['sortOrder', 'sort_order'], ['isActive', 'is_active']] as const) {
      if (b[k] !== undefined) { params.push(b[k]); sets.push(`${col} = $${params.length}`); }
    }
    const res = await ctx.db.query(`UPDATE geo.zone_categories SET ${sets.join(', ')} WHERE id = $1`, params);
    if ((res.rowCount ?? 0) === 0) throw notFound('Categoría no encontrada');
    await writeAudit(ctx.db, req, { action: 'zone_category.update', entityType: 'zone_category', entityId: String(id) });
    return { ok: true };
  });

  app.post('/zones', { preHandler: guard('zones.write') }, async (req, reply) => {
    const user = requireUser(req);
    const b = CreateZone.parse(req.body);
    const maxRadius = await ctx.settings.number('zones.max_radius_m', 100000);
    const g = geometrySql(b.geometry, maxRadius);
    const checkPoints: Array<{ lat: number; lon: number }> = b.geometry.kind === 'circle'
      ? [{ lat: b.geometry.lat, lon: b.geometry.lon }]
      : b.geometry.kind === 'rectangle'
        ? [{ lat: b.geometry.north, lon: b.geometry.east }, { lat: b.geometry.south, lon: b.geometry.west }]
        : b.geometry.vertices;
    for (const v of checkPoints) {
      assertCoordinate(v.lat, v.lon, await ctx.settings.allowedBBox());
    }
    const id = await withTransaction(ctx.db, async (c) => {
      const { rows } = await c.query<{ id: string }>(
        `INSERT INTO geo.zones (name, description, kind, geom, vertices, center_lat, center_lon, radius_m,
           label_text, show_label, category_id, color_hex, fill_opacity, stroke_width, is_active, created_by)
         VALUES ($1,$2,$3,${g.wkt}::geography,$4::jsonb,$5,$6,$7,$8,$9,$10,$11,$12,$13,$14,$15)
         RETURNING id`,
        [b.name, b.description ?? null, b.geometry.kind, g.vertices, g.centerLat, g.centerLon, g.radiusM,
          b.labelText ?? null, b.showLabel, b.categoryId ?? null, b.colorHex ?? null,
          b.fillOpacity, b.strokeWidth, b.isActive, user.id],
      );
      await writeAudit(c, req, { action: 'zone.create', entityType: 'zone', entityId: rows[0]!.id,
        details: { name: b.name, kind: b.geometry.kind } });
      return rows[0]!.id;
    });
    const { rows } = await ctx.db.query<ZoneRow>(`${ZONE_SELECT} WHERE z.id = $1`, [id]);
    reply.code(201);
    return zoneDto(rows[0]!);
  });

  app.patch('/zones/:id', { preHandler: guard('zones.write') }, async (req) => {
    const { id } = IdParams.parse(req.params);
    const b = UpdateZone.parse(req.body);
    const sets: string[] = [];
    const params: unknown[] = [id];
    const add = (sql: string, val: unknown) => { params.push(val); sets.push(sql.replace('?', `$${params.length}`)); };
    if (b.name !== undefined) add('name = ?', b.name);
    if (b.description !== undefined) add('description = ?', b.description);
    if (b.labelText !== undefined) add('label_text = ?', b.labelText);
    if (b.showLabel !== undefined) add('show_label = ?', b.showLabel);
    if (b.categoryId !== undefined) add('category_id = ?', b.categoryId);
    if (b.colorHex !== undefined) add('color_hex = ?', b.colorHex);
    if (b.fillOpacity !== undefined) add('fill_opacity = ?', b.fillOpacity);
    if (b.strokeWidth !== undefined) add('stroke_width = ?', b.strokeWidth);
    if (b.isActive !== undefined) add('is_active = ?', b.isActive);
    await withTransaction(ctx.db, async (c) => {
      const res = await c.query(`UPDATE geo.zones SET ${sets.join(', ')} WHERE id = $1`, params);
      if ((res.rowCount ?? 0) === 0) throw notFound('Zona no encontrada');
      await writeAudit(c, req, { action: 'zone.update', entityType: 'zone', entityId: id,
        details: { fields: Object.keys(b) } });
    });
    const { rows } = await ctx.db.query<ZoneRow>(`${ZONE_SELECT} WHERE z.id = $1`, [id]);
    return zoneDto(rows[0]!);
  });

  app.delete('/zones/:id', { preHandler: guard('zones.write') }, async (req) => {
    const { id } = IdParams.parse(req.params);
    await withTransaction(ctx.db, async (c) => {
      const res = await c.query('DELETE FROM geo.zones WHERE id = $1', [id]);
      if ((res.rowCount ?? 0) === 0) throw notFound('Zona no encontrada');
      await writeAudit(c, req, { action: 'zone.delete', entityType: 'zone', entityId: id });
    });
    return { ok: true };
  });

  /**
   * Personas de una zona: las que viven dentro del polígono (geometría) más
   * las asignadas manualmente. Respeta grupos y visibilidad del usuario.
   */
  app.get('/zones/:id/persons', { preHandler: guard('zones.read', 'persons.read') }, async (req) => {
    const { id } = IdParams.parse(req.params);
    const q = PaginationQuery.parse(req.query);
    const user = requireUser(req);
    const exact = user.permissions.has('locations.exact.read');
    const groupIds = ctx.groups.filter((g) => user.permissions.has(g.readPermission)).map((g) => g.id);
    if (groupIds.length === 0) throw forbidden('No tiene permiso para consultar ningún grupo');
    const max = await ctx.settings.number('zones.max_results', 2000);
    const restricted = user.rank >= 80;
    const limit = Math.min(q.pageSize, max);
    const offset = (q.page - 1) * limit;
    // Una persona puede vivir dentro del polígono Y estar asignada a la vez:
    // el CTE la deduplica con un indicador por vía de asignación.
    const INSIDE_CTE = `WITH zone AS (SELECT geom FROM geo.zones WHERE id = $1),
            inside AS (
              SELECT person_id, bool_or(via) AS "viaGeometry", bool_or(NOT via) AS "viaManual"
                FROM (SELECT l.person_id, true AS via
                        FROM geo.person_locations l, zone z
                       WHERE ST_Contains(z.geom::geometry, l.geom::geometry)
                      UNION ALL
                      SELECT m.person_id, false
                        FROM geo.zone_members m
                       WHERE m.zone_id = $1 AND m.source IN ('manual','import')) t
               GROUP BY person_id
            )`;
    const { rows } = await ctx.db.query(
      `${INSIDE_CTE}
       SELECT p.id, p.code, p.given_names || ' ' || p.family_names AS name,
              CASE WHEN $3::boolean THEN p.phone END AS phone,
              ST_Y(l.geom::geometry) AS lat, ST_X(l.geom::geometry) AS lon,
              l.address_text, i.intern_code AS "internCode", i.risk_level AS "riskLevel",
              EXISTS (SELECT 1 FROM directory.passes ps
                       WHERE ps.person_id = p.id AND ps.returned_at IS NULL AND ps.cancelled_at IS NULL
                         AND now() >= ps.starts_at AND now() <= ps.ends_at) AS "onPass",
              ARRAY(SELECT g.code FROM directory.person_memberships mm
                      JOIN directory.person_groups g ON g.id = mm.group_id
                     WHERE mm.person_id = p.id AND mm.group_id = ANY($2::smallint[]) ORDER BY g.code) AS groups,
              inside."viaGeometry", inside."viaManual"
         FROM inside
         JOIN directory.persons p ON p.id = inside.person_id
         LEFT JOIN geo.person_locations l ON l.person_id = p.id
         LEFT JOIN directory.inmates i ON i.person_id = p.id
        WHERE p.is_active
          AND EXISTS (SELECT 1 FROM directory.person_memberships vm
                       WHERE vm.person_id = p.id AND vm.group_id = ANY($2::smallint[]))
          AND (p.visibility = 'normal' OR $4::boolean)
        ORDER BY "onPass" DESC, p.family_names, p.given_names
        LIMIT $5 OFFSET $6`,
      [id, groupIds, exact, restricted, limit, offset],
    );
    const total = await ctx.db.query<{ n: number }>(
      `${INSIDE_CTE}
       SELECT count(*)::int AS n FROM inside
         JOIN directory.persons p ON p.id = inside.person_id
        WHERE p.is_active
          AND EXISTS (SELECT 1 FROM directory.person_memberships vm
                       WHERE vm.person_id = p.id AND vm.group_id = ANY($2::smallint[]))
          AND (p.visibility = 'normal' OR $3::boolean)`,
      [id, groupIds, restricted],
    );
    return {
      items: rows, page: q.page, pageSize: limit,
      total: Math.min(total.rows[0]?.n ?? 0, max), totalIsCapped: (total.rows[0]?.n ?? 0) > max,
    };
  });

  /** Asignar o quitar personas manualmente a la zona. */
  app.put('/zones/:id/persons', { preHandler: guard('zones.assign') }, async (req) => {
    const { id } = IdParams.parse(req.params);
    const b = AssignPersons.parse(req.body);
    const user = requireUser(req);
    const result = await withTransaction(ctx.db, async (c) => {
      const zone = await c.query('SELECT 1 FROM geo.zones WHERE id = $1', [id]);
      if (zone.rowCount === 0) throw notFound('Zona no encontrada');
      let added = 0;
      let removed = 0;
      if (b.add.length > 0) {
        const res = await c.query(
          `INSERT INTO geo.zone_members (zone_id, person_id, source, added_by)
           SELECT $1, x, 'manual', $2 FROM unnest($3::uuid[]) x
           WHERE EXISTS (SELECT 1 FROM directory.persons p WHERE p.id = x AND p.is_active)
           ON CONFLICT (zone_id, person_id) DO NOTHING`,
          [id, user.id, b.add],
        );
        added = res.rowCount ?? 0;
      }
      if (b.remove.length > 0) {
        const res = await c.query(
          `DELETE FROM geo.zone_members WHERE zone_id = $1 AND person_id = ANY($2::uuid[])`,
          [id, b.remove],
        );
        removed = res.rowCount ?? 0;
      }
      await writeAudit(c, req, { action: 'zone.persons_assign', entityType: 'zone', entityId: id,
        details: { added, removed } });
      return { added, removed };
    });
    return result;
  });

  /**
   * Recalcula la pertenencia por geometría: todas las personas con ubicación
   * fija dentro del polígono quedan asignadas (source=geometry). Las manuales
   * se conservan; las asignaciones por geometría obsoletas se eliminan.
   */
  app.post('/zones/:id/recompute', { preHandler: guard('zones.assign') }, async (req) => {
    const { id } = IdParams.parse(req.params);
    const user = requireUser(req);
    const max = await ctx.settings.number('zones.max_results', 2000);
    const result = await withTransaction(ctx.db, async (c) => {
      const zone = await c.query('SELECT geom FROM geo.zones WHERE id = $1', [id]);
      if (zone.rowCount === 0) throw notFound('Zona no encontrada');
      const del = await c.query(
        `WITH gone AS (
           DELETE FROM geo.zone_members m WHERE m.zone_id = $1 AND m.source = 'geometry'
             AND NOT EXISTS (
               SELECT 1 FROM geo.person_locations l
                 JOIN directory.persons p ON p.id = l.person_id AND p.is_active
                WHERE l.person_id = m.person_id AND ST_Contains((SELECT geom::geometry FROM geo.zones WHERE id = $1), l.geom::geometry))
           RETURNING 1) SELECT count(*)::int AS n FROM gone`, [id]);
      const ins = await c.query(
        `INSERT INTO geo.zone_members (zone_id, person_id, source, added_by)
         SELECT $1, l.person_id, 'geometry', $2
           FROM geo.person_locations l
           JOIN directory.persons p ON p.id = l.person_id AND p.is_active
          WHERE ST_Contains((SELECT geom::geometry FROM geo.zones WHERE id = $1), l.geom::geometry)
          LIMIT $3
          ON CONFLICT (zone_id, person_id) DO NOTHING`, [id, user.id, max]);
      await writeAudit(c, req, { action: 'zone.recompute', entityType: 'zone', entityId: id,
        details: { removed: del.rows[0]?.n ?? 0 } });
      return { removedStale: del.rows[0]?.n ?? 0, added: ins.rowCount ?? 0 };
    });
    return result;
  });

  /** Personal de la fuerza de la zona: asignado a ella y el que vive cerca. */
  app.get('/zones/:id/personnel', { preHandler: guard('zones.read', 'personnel.read') }, async (req) => {
    const { id } = IdParams.parse(req.params);
    const radius = await ctx.settings.number('personnel.near_radius_m', 5000);
    const max = await ctx.settings.number('personnel.max_results', 50);
    const { rows } = await ctx.db.query(
      `WITH zone AS (SELECT geom FROM geo.zones WHERE id = $1)
       SELECT pe.id, pe.code, pe.full_name AS name, pe.rank, pe.unit, pe.phone, pe.phone_alt,
              pe.address_text, pe.role_note, (pe.zone_id = $1) AS assigned,
              ST_Y(pe.geom::geometry) AS lat, ST_X(pe.geom::geometry) AS lon,
              round(ST_Distance(pe.geom, z.geom))::int AS "distanceM",
              (ST_Contains(z.geom::geometry, pe.geom::geometry)) AS "insideZone"
         FROM zone z, directory.personnel pe
        WHERE pe.is_active
          AND (pe.zone_id = $1 OR (pe.geom IS NOT NULL AND ST_DWithin(pe.geom, z.geom, $2::int)))
        ORDER BY assigned DESC, "distanceM" NULLS LAST
        LIMIT $3`,
      [id, radius, max],
    );
    return { items: rows, radiusM: radius };
  });

  /** Pases que se cumplen dentro de la zona (autorizados en ella o por residencia). */
  app.get('/zones/:id/passes', { preHandler: guard('zones.read', 'passes.read') }, async (req) => {
    const { id } = IdParams.parse(req.params);
    const { rows } = await ctx.db.query(
      `WITH zone AS (SELECT geom FROM geo.zones WHERE id = $1)
       SELECT ps.id, ps.person_id, ps.starts_at AS "startsAt", ps.ends_at AS "endsAt",
              ps.facility, ps.authorized_address AS "authorizedAddress",
              CASE WHEN ps.cancelled_at IS NOT NULL THEN 'cancelled'
                   WHEN ps.returned_at IS NOT NULL THEN 'returned'
                   WHEN now() < ps.starts_at THEN 'scheduled'
                   WHEN now() <= ps.ends_at THEN 'active'
                   ELSE 'expired' END AS state,
              pt.name AS "passType", pt.color_hex AS "passTypeColor",
              p.code, p.given_names || ' ' || p.family_names AS name, p.phone,
              i.intern_code AS "internCode", i.risk_level AS "riskLevel",
              ST_Y(l.geom::geometry) AS lat, ST_X(l.geom::geometry) AS lon,
              (ps.authorized_zone_id = $1) AS "authorizedHere"
         FROM zone z
         JOIN directory.passes ps ON ps.authorized_zone_id = $1
                OR EXISTS (SELECT 1 FROM geo.person_locations pl
                            WHERE pl.person_id = ps.person_id AND ST_Contains(z.geom::geometry, pl.geom::geometry))
         LEFT JOIN directory.pass_types pt ON pt.id = ps.pass_type_id
         JOIN directory.persons p ON p.id = ps.person_id AND p.is_active
         LEFT JOIN directory.inmates i ON i.person_id = p.id
         LEFT JOIN geo.person_locations l ON l.person_id = p.id
        ORDER BY state, ps.ends_at`,
      [id],
    );
    return { items: rows };
  });
}
