import type { FastifyInstance } from 'fastify';
import { z } from 'zod';
import { badRequest, notFound } from '../../lib/errors.js';
import { maskDistance, resolveRadius } from '../../lib/geo.js';
import { buildPage, offsetOf } from '../../lib/pagination.js';
import { guard, requireUser } from '../../plugins/auth.js';
import { writeAudit } from '../audit/audit-writer.js';
import { PERSON_JOINS, PERSON_SELECT, PERSON_VISIBLE, toPersonDto, type PersonRow } from '../persons/dto.js';
import { findPersonById, ON_PASS_SQL } from '../persons/repo.js';
import { visibilityFor } from '../persons/routes.js';
import { NearbyQuery } from '../persons/schemas.js';

/** Búsqueda global unificada (/search): detecta qué es lo escrito y busca a
 * la vez personas (con fonética y corrección de tipeo), direcciones (nombres
 * antiguos incluidos), zonas y personal. Devuelve grupos + una sugerencia
 * «¿quisiste decir…?» cuando el parecido máximo es bajo. */
const BusquedaQuery = z.object({
  q: z.string().trim().min(2).max(120),
  limit: z.coerce.number().int().min(1).max(25).default(8),
  filtro: z.preprocess(
    (v) => (Array.isArray(v) ? v : v == null ? [] : [v]),
    z.array(z.enum(['con_permiso', 'sin_ubicacion', 'con_telefono'])).max(3),
  ).default([]),
  municipio: z.string().trim().max(120).optional(),
});

type DireccionDto = {
  label: string; municipality: string | null; lat: number; lon: number;
  fuente: 'calle' | 'vivienda' | 'antiguo';
};

function detectarTipo(q: string): 'identidad' | 'telefono' | 'direccion' | 'texto' {
  const soloDigitos = q.replace(/\D/g, '');
  if (/^\d{11}$/.test(soloDigitos)) return 'identidad';
  if (/[0-9]{6,}/.test(q) && /^[0-9+()\s-]+$/.test(q)) return 'telefono';
  if (/#\s*\d/.test(q) || /\b(calle|avda|avenida|carrera|camino|reparto|barrio|carretera)\b/i.test(q)) return 'direccion';
  return 'texto';
}

const IdParams = z.object({ id: z.uuid() });

export async function searchRoutes(app: FastifyInstance): Promise<void> {
  const { ctx } = app;

  app.get('/search', { preHandler: guard('persons.read') }, async (req) => {
    const started = Date.now();
    const { q, limit, filtro, municipio } = BusquedaQuery.parse(req.query);
    const user = requireUser(req);
    const v = visibilityFor(ctx, req);
    const norm = await ctx.db.query<{ n: string }>(
      'SELECT catalog.normalize_text($1) AS n', [q]);
    const qNorm = norm.rows[0]?.n ?? q;
    const fonemaQ = await ctx.db.query<{ n: string }>(
      'SELECT catalog.fonema($1) AS n', [qNorm]);
    const qFonema = fonemaQ.rows[0]?.n ?? '';

    // --- Personas -----------------------------------------------------------
    const conds: string[] = [];
    const params: unknown[] = [v.groupIds, v.restricted, q, qNorm, qFonema, limit];
    if (filtro.includes('con_permiso')) conds.push(ON_PASS_SQL);
    if (filtro.includes('sin_ubicacion')) conds.push('l.person_id IS NULL');
    if (filtro.includes('con_telefono')) conds.push('p.phone IS NOT NULL');
    if (municipio) {
      params.push(`%${municipio}%`);
      conds.push(`mu.name ILIKE $${params.length}`);
    }
    const whereFiltros = conds.length ? ` AND ${conds.join(' AND ')}` : '';
    const personsRows = await ctx.db.query<PersonRow & { score: number }>(
      `WITH cand AS (
         SELECT p.id,
           CASE
             WHEN p.code = upper($3) THEN 10
             WHEN p.code LIKE upper($3) || '%' THEN 8.5
             WHEN p.phone = $3 THEN 9
             WHEN p.full_name_norm LIKE $4 || '%' THEN 7
             WHEN p.full_name_fonema = $5 THEN 6.5
             ELSE similarity(p.full_name_norm, $4) * 6
           END AS score
           FROM directory.persons p
          WHERE p.is_active
            AND (p.code ILIKE '%' || $3 || '%'
                 OR p.full_name_norm LIKE '%' || $4 || '%'
                 OR p.full_name_norm % $4
                 OR p.full_name_fonema = $5
                 OR p.phone LIKE '%' || $3 || '%')
         LIMIT 400
       )
       ${PERSON_SELECT}, cand.score ${PERSON_JOINS}
       JOIN cand ON cand.id = p.id
       WHERE ${PERSON_VISIBLE}${whereFiltros}
       ORDER BY cand.score DESC, p.full_name_norm
       LIMIT $6`,
      params);
    const persons = personsRows.rows.map((r) => ({
      ...toPersonDto(r, user),
      score: Number(r.score),
    }));

    // --- Direcciones (calles, viviendas y nombres antiguos) -----------------
    const dirsRows = await ctx.db.query<DireccionDto>(
      `WITH objetivo AS (
         SELECT coalesce(
                  (regexp_match($1, '#\\s*([0-9]+[A-Za-z]?)'))[1],
                  (regexp_match($1, '\\s([0-9]{1,5}[A-Za-z]?)\\s*$'))[1]) AS num
       ), calles AS (
         SELECT a.street_name, NULL::text AS house_number, mu.name AS municipality,
                ST_Y(a.geom::geometry) AS lat, ST_X(a.geom::geometry) AS lon,
                similarity(a.search_norm, $2) AS s, 'calle'::text AS fuente
           FROM geo.addresses a LEFT JOIN geo.municipalities mu ON mu.id = a.municipality_id
          WHERE a.granularity = 'street' AND a.search_norm % $2
       ), viviendas AS (
         SELECT a.street_name, a.house_number, mu.name AS municipality,
                ST_Y(a.geom::geometry) AS lat, ST_X(a.geom::geometry) AS lon,
                similarity(a.search_norm, $2) * 1.1 AS s, 'vivienda'::text AS fuente
           FROM geo.addresses a LEFT JOIN geo.municipalities mu ON mu.id = a.municipality_id, objetivo
          WHERE a.granularity = 'dwelling' AND objetivo.num IS NOT NULL
            AND a.house_number ILIKE objetivo.num || '%'
       ), antiguos AS (
         SELECT sa.street_name, NULL::text AS house_number, mu.name AS municipality,
                ST_Y(rep.g::geometry) AS lat, ST_X(rep.g::geometry) AS lon,
                similarity(sa.alias_norm, $2) * 0.95 AS s, 'antiguo'::text AS fuente
           FROM geo.street_aliases sa
           LEFT JOIN geo.municipalities mu ON mu.id = sa.municipality_id
           LEFT JOIN LATERAL (
             SELECT a.geom AS g FROM geo.addresses a
              WHERE a.granularity = 'street' AND a.street_name = sa.street_name
                AND (a.municipality_id = sa.municipality_id OR sa.municipality_id IS NULL)
              LIMIT 1) rep ON true
          WHERE sa.alias_norm % $2 AND rep.g IS NOT NULL
       ), todas AS (
         SELECT * FROM calles UNION ALL SELECT * FROM viviendas UNION ALL
         (SELECT * FROM antiguos WHERE s > 0.45)
       )
       SELECT label, municipality, lat, lon, fuente FROM (
         SELECT DISTINCT ON (label) label, municipality, lat, lon, fuente, s
           FROM (SELECT street_name || coalesce(' ' || house_number, '') AS label,
                        municipality, lat, lon, fuente, s FROM todas) t
          WHERE lat IS NOT NULL AND s > 0.3
          ORDER BY label, s DESC
       ) unicos
        ORDER BY s DESC
        LIMIT $3`,
      [q, qNorm, limit]);
    const direcciones = dirsRows.rows.filter((d) => d.lat != null);

    // --- Zonas (solo con permiso) -------------------------------------------
    let zonas: Array<{ id: string; name: string; lat: number; lon: number }> = [];
    if (user.permissions.has('zones.read')) {
      const z = await ctx.db.query<{ id: string; name: string; lat: number; lon: number }>(
        `SELECT id, name, ST_Y(ST_Centroid(geom::geometry)) AS lat, ST_X(ST_Centroid(geom::geometry)) AS lon
           FROM geo.zones WHERE is_active AND name % $1
          ORDER BY similarity(name, $1) DESC LIMIT $2`,
        [q, Math.min(limit, 6)]);
      // normalize_z no existe: usar name normalizado en línea.
      zonas = z.rows;
    }

    // --- Sugerencia «¿quisiste decir…?» -------------------------------------
    let sugerencia: string | null = null;
    const topScore = persons[0]?.score ?? 0;
    if (topScore < 5 && persons.length > 0) {
      sugerencia = persons[0]?.fullName ?? null; // «¿quisiste decir…?» con el mejor parecido ya hallado
    } else if (topScore < 5) {
      const sug = await ctx.db.query<{ n: string }>(
        `SELECT s FROM (
           SELECT given_names || ' ' || family_names AS s,
                  similarity(catalog.normalize_text(given_names || ' ' || family_names), $1) AS sim
             FROM directory.persons WHERE is_active
           UNION ALL
           SELECT name, similarity(catalog.normalize_text(name), $1)
             FROM geo.municipalities
         ) t WHERE sim > 0.32 ORDER BY sim DESC LIMIT 1`,
        [qNorm]);
      sugerencia = sug.rows[0]?.n ?? null;
    }

    return {
      q,
      detectado: detectarTipo(q),
      sugerencia,
      persons,
      addresses: direcciones,
      zones: zonas,
      tookMs: Date.now() - started,
    };
  });

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
