import type { FastifyInstance } from 'fastify';
import { z } from 'zod';
import { withTransaction } from '../../db/pool.js';
import { badRequest, conflict, forbidden, notFound } from '../../lib/errors.js';
import { PaginationQuery } from '../../lib/pagination.js';
import { allowedGroups, authenticate, canSeeRestricted, guard, requireUser } from '../../plugins/auth.js';
import { writeAudit } from '../audit/audit-writer.js';

const IdParams = z.object({ id: z.uuid() });

/** Estado calculado por fecha: no hay cron que actualizar. */
const STATE_SQL = `CASE WHEN ps.cancelled_at IS NOT NULL THEN 'cancelled'
                        WHEN ps.returned_at IS NOT NULL THEN 'returned'
                        WHEN now() < ps.starts_at THEN 'scheduled'
                        WHEN now() <= ps.ends_at THEN 'active'
                        ELSE 'expired' END`;

const PASS_SELECT = `
  SELECT ps.id, ps.person_id AS "personId", ps.pass_type_id AS "passTypeId",
         pt.name AS "passTypeName", pt.color_hex AS "passTypeColor",
         ps.facility, ps.starts_at AS "startsAt", ps.ends_at AS "endsAt",
         ps.returned_at AS "returnedAt", ps.cancelled_at AS "cancelledAt",
         ps.authorized_zone_id AS "authorizedZoneId", z.name AS "authorizedZoneName",
         ps.authorized_address AS "authorizedAddress", ps.notes,
         ps.data_source AS "dataSource", ps.created_at AS "createdAt",
         ${STATE_SQL} AS state,
         p.code, p.given_names || ' ' || p.family_names AS "personName",
         i.intern_code AS "internCode", i.facility AS "internFacility",
         i.risk_level AS "riskLevel", i.status AS "internStatus",
         ST_Y(l.geom::geometry) AS lat, ST_X(l.geom::geometry) AS lon,
         l.address_text, l.validation_status AS "validationStatus"
    FROM directory.passes ps
    LEFT JOIN directory.pass_types pt ON pt.id = ps.pass_type_id
    LEFT JOIN geo.zones z ON z.id = ps.authorized_zone_id
    JOIN directory.persons p ON p.id = ps.person_id
    LEFT JOIN directory.inmates i ON i.person_id = p.id
    LEFT JOIN geo.person_locations l ON l.person_id = p.id`;

const PASS_VISIBLE = `
  EXISTS (SELECT 1 FROM directory.person_memberships vm
           WHERE vm.person_id = ps.person_id AND vm.group_id = ANY($1::smallint[]))
  AND (p.visibility = 'normal' OR $2::boolean)`;

const CreatePass = z.object({
  personId: z.uuid(),
  passTypeId: z.number().int().positive().nullish(),
  facility: z.string().trim().max(160).nullish(),
  startsAt: z.coerce.date(),
  endsAt: z.coerce.date(),
  authorizedZoneId: z.uuid().nullish(),
  authorizedAddress: z.string().trim().max(300).nullish(),
  notes: z.string().trim().max(2000).nullish(),
});

const UpdatePass = CreatePass.omit({ personId: true }).partial()
  .refine((o) => Object.keys(o).length > 0, 'Sin cambios');

export async function passRoutes(app: FastifyInstance): Promise<void> {
  const { ctx } = app;

  /** Opciones configurables para formularios (estados y riesgos de interno). */
  app.get('/passes/options', { preHandler: authenticate() }, async () => ({
    statuses: await ctx.settings.stringList('inmate.statuses',
      ['Internado', 'En pase', 'Excarcelado', 'Libertad condicional']),
    riskLevels: await ctx.settings.stringList('inmate.risk_levels',
      ['Bajo', 'Medio', 'Alto', 'Máximo']),
  }));

  app.get('/passes', { preHandler: guard('passes.read') }, async (req) => {
    const q = PaginationQuery.extend({
      state: z.enum(['active', 'scheduled', 'expired', 'returned', 'cancelled', 'all']).default('active'),
      personId: z.uuid().optional(),
      zoneId: z.uuid().optional(),
      q: z.string().trim().max(120).optional(),
    }).parse(req.query);
    const user = requireUser(req);
    const groupIds = allowedGroups(ctx, user);
    const restricted = canSeeRestricted(user);
    const params: unknown[] = [groupIds, restricted];
    const where: string[] = [PASS_VISIBLE];
    if (q.state !== 'all') { params.push(q.state); where.push(`${STATE_SQL} = $${params.length}`); }
    if (q.personId) { params.push(q.personId); where.push(`ps.person_id = $${params.length}`); }
    if (q.zoneId) { params.push(q.zoneId); where.push(`ps.authorized_zone_id = $${params.length}`); }
    const term = q.q?.trim();
    if (term) {
      params.push(term.toUpperCase(), `%${term.toLowerCase()}%`);
      const [c, l] = [params.length - 1, params.length];
      where.push(`(p.code = $${c} OR i.intern_code = $${c} OR
                   (p.given_names || ' ' || p.family_names) ILIKE $${l})`);
    }
    params.push(q.pageSize, (q.page - 1) * q.pageSize);
    const { rows } = await ctx.db.query(
      `SELECT x.*, x.total FROM (
         SELECT ps.id, ps.person_id AS "personId", ps.pass_type_id AS "passTypeId",
                pt.name AS "passTypeName", pt.color_hex AS "passTypeColor",
                ps.facility, ps.starts_at AS "startsAt", ps.ends_at AS "endsAt",
                ps.returned_at AS "returnedAt", ps.cancelled_at AS "cancelledAt",
                ps.authorized_zone_id AS "authorizedZoneId", z.name AS "authorizedZoneName",
                ps.authorized_address AS "authorizedAddress", ps.notes,
                ps.data_source AS "dataSource", ps.created_at AS "createdAt",
                ${STATE_SQL} AS state,
                p.code, p.given_names || ' ' || p.family_names AS "personName", p.phone,
                i.intern_code AS "internCode", i.risk_level AS "riskLevel",
                count(*) OVER () AS total
           FROM directory.passes ps
           LEFT JOIN directory.pass_types pt ON pt.id = ps.pass_type_id
           LEFT JOIN geo.zones z ON z.id = ps.authorized_zone_id
           JOIN directory.persons p ON p.id = ps.person_id
           LEFT JOIN directory.inmates i ON i.person_id = p.id
          WHERE ${where.join(' AND ')}
          ORDER BY ${STATE_SQL} DESC, ps.ends_at
          LIMIT $${params.length - 1} OFFSET $${params.length}) x`,
      params,
    );
    const total = rows[0]?.total ?? (q.page - 1) * q.pageSize + rows.length;
    return { items: rows.map(({ total: _t, ...r }) => r), page: q.page, pageSize: q.pageSize,
      total: Math.min(total, 50000), totalIsCapped: total > 50000 };
  });

  /** Catálogo configurable de tipos de pase. */
  app.get('/passes/types', { preHandler: guard('passes.read') }, async () => {
    const { rows } = await ctx.db.query(
      `SELECT id, code, name, description, default_days AS "defaultDays", color_hex AS "colorHex",
              is_active AS "isActive",
              (SELECT count(*)::int FROM directory.passes ps WHERE ps.pass_type_id = t.id) AS "passCount"
         FROM directory.pass_types t ORDER BY id`,
    );
    return { items: rows };
  });

  const PassTypeBody = z.object({
    code: z.string().trim().toLowerCase().regex(/^[a-z0-9_-]{2,40}$/),
    name: z.string().trim().min(1).max(80),
    description: z.string().trim().max(500).default(''),
    defaultDays: z.number().int().min(1).max(3650).default(7),
    colorHex: z.string().regex(/^#[0-9A-Fa-f]{6}$/).default('#1565C0'),
    isActive: z.boolean().default(true),
  });

  app.post('/passes/types', { preHandler: guard('passes.write') }, async (req, reply) => {
    const b = PassTypeBody.parse(req.body);
    const { rows } = await ctx.db.query<{ id: number }>(
      `INSERT INTO directory.pass_types (code, name, description, default_days, color_hex, is_active)
       VALUES ($1,$2,$3,$4,$5,$6) RETURNING id`,
      [b.code, b.name, b.description, b.defaultDays, b.colorHex, b.isActive],
    );
    await writeAudit(ctx.db, req, { action: 'pass_type.create', entityType: 'pass_type',
      entityId: String(rows[0]!.id), details: { code: b.code } });
    reply.code(201);
    return { id: rows[0]!.id };
  });

  app.patch('/passes/types/:id', { preHandler: guard('passes.write') }, async (req) => {
    const id = z.coerce.number().int().positive().parse((req.params as { id: string }).id);
    const b = PassTypeBody.partial().refine((o) => Object.keys(o).length > 0, 'Sin cambios').parse(req.body);
    const map = { code: 'code', name: 'name', description: 'description', defaultDays: 'default_days',
      colorHex: 'color_hex', isActive: 'is_active' } as const;
    const sets: string[] = [];
    const params: unknown[] = [id];
    for (const [k, col] of Object.entries(map)) {
      if ((b as Record<string, unknown>)[k] !== undefined) {
        params.push((b as Record<string, unknown>)[k]);
        sets.push(`${col} = $${params.length}`);
      }
    }
    const res = await ctx.db.query(`UPDATE directory.pass_types SET ${sets.join(', ')} WHERE id = $1`, params);
    if ((res.rowCount ?? 0) === 0) throw notFound('Tipo de pase no encontrado');
    await writeAudit(ctx.db, req, { action: 'pass_type.update', entityType: 'pass_type', entityId: String(id) });
    return { ok: true };
  });

  /** Marcadores de internos con pase ACTIVO para el mapa (pase + residencia). */
  app.get('/passes/map', { preHandler: guard('passes.read') }, async (req) => {
    const q = z.object({ bbox: z.string().min(7).max(120) }).parse(req.query);
    const user = requireUser(req);
    const exact = user.permissions.has('locations.exact.read');
    const groupIds = allowedGroups(ctx, user);
    const restricted = canSeeRestricted(user);
    const parts = q.bbox.split(',').map(Number);
    if (parts.length !== 4 || parts.some((x) => !Number.isFinite(x))) throw badRequest('bbox incoherente');
    const [w, s, e, n] = parts;
    const marker = await ctx.settings.all().then((m) => m.get('passes.marker_icon'));
    if (!exact) {
      // Sin permiso de ubicación exacta: solo el recuento, nunca coordenadas.
      const { rows } = await ctx.db.query<{ n: number }>(
        `SELECT count(*)::int AS n FROM directory.passes ps
           JOIN directory.persons p ON p.id = ps.person_id
          WHERE ${PASS_VISIBLE} AND ${STATE_SQL} = 'active'`,
        [groupIds, restricted],
      );
      return { mode: 'hidden', count: rows[0]?.n ?? 0, marker };
    }
    const { rows } = await ctx.db.query(
      `${PASS_SELECT}
        WHERE ${PASS_VISIBLE} AND ${STATE_SQL} = 'active'
          AND l.geom IS NOT NULL
          AND ST_Contains(ST_MakeEnvelope($3, $4, $5, $6, 4326), l.geom::geometry)
        ORDER BY ps.ends_at`,
      [groupIds, restricted, w, s, e, n],
    );
    return { mode: 'points', items: rows, marker };
  });

  app.get('/passes/:id', { preHandler: guard('passes.read') }, async (req) => {
    const { id } = IdParams.parse(req.params);
    const user = requireUser(req);
    const groupIds = allowedGroups(ctx, user);
    const restricted = canSeeRestricted(user);
    const { rows } = await ctx.db.query(
      `${PASS_SELECT} WHERE ps.id = $3 AND ${PASS_VISIBLE}`,
      [groupIds, restricted, id],
    );
    if (!rows[0]) throw notFound('Pase no encontrado o sin permiso');
    return rows[0];
  });

  app.post('/passes', { preHandler: guard('passes.write') }, async (req, reply) => {
    const user = requireUser(req);
    const b = CreatePass.parse(req.body);
    if (b.endsAt.getTime() <= b.startsAt.getTime()) throw badRequest('La fecha de fin debe ser posterior');
    const maxActive = await ctx.settings.number('passes.max_active_per_person', 1);
    const result = await withTransaction(ctx.db, async (c) => {
      const person = await c.query<{ id: string; visibility: string }>(
        'SELECT id, visibility FROM directory.persons WHERE id = $1 AND is_active', [b.personId]);
      if (!person.rows[0]) throw notFound('Persona no encontrada o inactiva');
      if (person.rows[0].visibility === 'restricted' && user.rank < 80) {
        throw forbidden('Persona de visibilidad restringida');
      }
      const inmate = await c.query('SELECT 1 FROM directory.inmates WHERE person_id = $1', [b.personId]);
      if ((inmate.rowCount ?? 0) === 0) {
        throw badRequest('La persona no está registrada como interno; regístrela primero');
      }
      const active = await c.query<{ n: number }>(
        `SELECT count(*)::int AS n FROM directory.passes
          WHERE person_id = $1 AND returned_at IS NULL AND cancelled_at IS NULL
            AND now() >= starts_at AND now() <= ends_at`, [b.personId]);
      if ((active.rows[0]?.n ?? 0) >= maxActive) {
        throw conflict(`El interno ya tiene ${maxActive} pase(s) activo(s) (límite configurado)`);
      }
      const overlap = await c.query<{ n: number }>(
        `SELECT count(*)::int AS n FROM directory.passes
          WHERE person_id = $1 AND returned_at IS NULL AND cancelled_at IS NULL
            AND tstzrange(starts_at, ends_at) && tstzrange($2::timestamptz, $3::timestamptz)`,
        [b.personId, b.startsAt.toISOString(), b.endsAt.toISOString()]);
      const { rows } = await c.query<{ id: string }>(
        `INSERT INTO directory.passes (person_id, intern_id, pass_type_id, facility, starts_at, ends_at,
           authorized_zone_id, authorized_address, notes, created_by)
         VALUES ($1, $1, $2, $3, $4, $5, $6, $7, $8, $9) RETURNING id`,
        [b.personId, b.passTypeId ?? null, b.facility ?? null, b.startsAt.toISOString(),
          b.endsAt.toISOString(), b.authorizedZoneId ?? null, b.authorizedAddress ?? null,
          b.notes ?? null, user.id],
      );
      await writeAudit(c, req, { action: 'pass.create', entityType: 'pass', entityId: rows[0]!.id,
        details: { personId: b.personId, passTypeId: b.passTypeId ?? null,
          overlapping: (overlap.rows[0]?.n ?? 0) > 0 } });
      return { id: rows[0]!.id, overlapping: (overlap.rows[0]?.n ?? 0) > 0 };
    });
    reply.code(201);
    return result;
  });

  app.patch('/passes/:id', { preHandler: guard('passes.write') }, async (req) => {
    const { id } = IdParams.parse(req.params);
    const b = UpdatePass.parse(req.body);
    const map: Record<string, string> = {
      passTypeId: 'pass_type_id', facility: 'facility', startsAt: 'starts_at', endsAt: 'ends_at',
      authorizedZoneId: 'authorized_zone_id', authorizedAddress: 'authorized_address', notes: 'notes',
    };
    const sets: string[] = [];
    const params: unknown[] = [id];
    for (const [k, val] of Object.entries(b)) {
      const col = map[k];
      if (!col) continue;
      const v = val instanceof Date ? val.toISOString() : (val ?? null);
      params.push(v);
      sets.push(`${col} = $${params.length}`);
    }
    if (sets.length === 0) throw badRequest('Nada que cambiar');
    await withTransaction(ctx.db, async (c) => {
      const cur = await c.query<{ starts_at: Date; ends_at: Date }>(
        'SELECT starts_at, ends_at FROM directory.passes WHERE id = $1', [id]);
      if (!cur.rows[0]) throw notFound('Pase no encontrado');
      const starts = (b.startsAt ?? cur.rows[0].starts_at).toISOString();
      const ends = (b.endsAt ?? cur.rows[0].ends_at).toISOString();
      if (new Date(ends).getTime() <= new Date(starts).getTime()) {
        throw badRequest('La fecha de fin debe ser posterior al inicio');
      }
      const res = await c.query(
        `UPDATE directory.passes SET ${sets.join(', ')}
          WHERE id = $1 AND returned_at IS NULL AND cancelled_at IS NULL`, params);
      if ((res.rowCount ?? 0) === 0) throw badRequest('El pase ya está cerrado (devuelto o cancelado)');
      await writeAudit(c, req, { action: 'pass.update', entityType: 'pass', entityId: id,
        details: { fields: Object.keys(b) } });
    });
    return { ok: true };
  });

  /** El interno regresa antes de la fecha prevista. */
  app.post('/passes/:id/return', { preHandler: guard('passes.write') }, async (req) => {
    const { id } = IdParams.parse(req.params);
    const user = requireUser(req);
    const b = z.object({ returnedAt: z.coerce.date().optional() }).parse(req.body ?? {});
    await withTransaction(ctx.db, async (c) => {
      const res = await c.query(
        `UPDATE directory.passes SET returned_at = COALESCE($2::timestamptz, now())
          WHERE id = $1 AND returned_at IS NULL AND cancelled_at IS NULL`, [id, b.returnedAt?.toISOString() ?? null]);
      if ((res.rowCount ?? 0) === 0) throw badRequest('El pase ya está cerrado o no existe');
      await writeAudit(c, req, { action: 'pass.return', entityType: 'pass', entityId: id });
    });
    return { ok: true };
  });

  app.post('/passes/:id/cancel', { preHandler: guard('passes.write') }, async (req) => {
    const { id } = IdParams.parse(req.params);
    await withTransaction(ctx.db, async (c) => {
      const res = await c.query(
        `UPDATE directory.passes SET cancelled_at = now()
          WHERE id = $1 AND returned_at IS NULL AND cancelled_at IS NULL`, [id]);
      if ((res.rowCount ?? 0) === 0) throw badRequest('El pase ya está cerrado o no existe');
      await writeAudit(c, req, { action: 'pass.cancel', entityType: 'pass', entityId: id });
    });
    return { ok: true };
  });

  /** Ficha de interno de una persona + sus pases. */
  app.get('/persons/:id/passes', { preHandler: guard('passes.read') }, async (req) => {
    const { id } = IdParams.parse(req.params);
    const user = requireUser(req);
    const groupIds = allowedGroups(ctx, user);
    const restricted = canSeeRestricted(user);
    const inmate = await ctx.db.query(
      `SELECT i.person_id AS "personId", i.intern_code AS "internCode", i.facility, i.status,
              i.risk_level AS "riskLevel", i.cell_ref AS "cellRef", i.notes, i.is_active AS "isActive",
              i.data_source AS "dataSource"
         FROM directory.inmates i JOIN directory.persons p ON p.id = i.person_id
        WHERE i.person_id = $3 AND ${PASS_VISIBLE.replace('ps.person_id', 'i.person_id')}`,
      [groupIds, restricted, id],
    );
    const passes = await ctx.db.query(
      `${PASS_SELECT} WHERE ps.person_id = $3 AND ${PASS_VISIBLE} ORDER BY ps.starts_at DESC`,
      [groupIds, restricted, id],
    );
    return { inmate: inmate.rows[0] ?? null, passes: passes.rows };
  });

  const UpsertInmate = z.object({
    internCode: z.string().trim().toUpperCase().regex(/^[A-Z0-9][A-Z0-9/-]{2,31}$/).nullish(),
    facility: z.string().trim().max(160).nullish(),
    status: z.string().trim().max(60).nullish(),
    riskLevel: z.string().trim().max(40).nullish(),
    cellRef: z.string().trim().max(60).nullish(),
    notes: z.string().trim().max(2000).nullish(),
    isActive: z.boolean().optional(),
  });

  app.post('/persons/:id/inmate', { preHandler: guard('passes.write') }, async (req, reply) => {
    const { id } = IdParams.parse(req.params);
    const user = requireUser(req);
    const b = UpsertInmate.parse(req.body);
    await withTransaction(ctx.db, async (c) => {
      const person = await c.query('SELECT 1 FROM directory.persons WHERE id = $1 AND is_active', [id]);
      if (!person.rows[0]) throw notFound('Persona no encontrada o inactiva');
      if (b.internCode) {
        const dup = await c.query('SELECT 1 FROM directory.inmates WHERE intern_code = $1 AND person_id <> $2',
          [b.internCode, id]);
        if ((dup.rowCount ?? 0) > 0) throw conflict('Ya existe un interno con ese código');
      }
      await c.query(
        `INSERT INTO directory.inmates (person_id, intern_code, facility, status, risk_level, cell_ref, notes, data_source, created_by)
         VALUES ($1,$2,$3,$4,$5,$6,$7,'manual',$8)
         ON CONFLICT (person_id) DO UPDATE SET
           intern_code = COALESCE($2, directory.inmates.intern_code),
           facility = COALESCE($3, directory.inmates.facility),
           status = COALESCE($4, directory.inmates.status),
           risk_level = COALESCE($5, directory.inmates.risk_level),
           cell_ref = COALESCE($6, directory.inmates.cell_ref),
           notes = COALESCE($7, directory.inmates.notes),
           is_active = COALESCE($9, directory.inmates.is_active)`,
        [id, b.internCode ?? null, b.facility ?? null, b.status ?? null, b.riskLevel ?? null,
          b.cellRef ?? null, b.notes ?? null, user.id, b.isActive ?? null],
      );
      await writeAudit(c, req, { action: 'inmate.upsert', entityType: 'inmate', entityId: id });
    });
    reply.code(201);
    const { rows } = await ctx.db.query(
      `SELECT person_id AS "personId", intern_code AS "internCode", facility, status,
              risk_level AS "riskLevel", cell_ref AS "cellRef", notes, is_active AS "isActive"
         FROM directory.inmates WHERE person_id = $1`, [id]);
    return rows[0];
  });
}
