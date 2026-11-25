import type { FastifyInstance } from 'fastify';
import { z } from 'zod';
import { clusterCellDegrees, parseBBox } from '../../lib/geo.js';
import { GroupsParam } from '../../lib/pagination.js';
import { authenticate, canSeeRestricted, guard, requireUser, allowedGroups } from '../../plugins/auth.js';
import { readManifest } from './manifest.js';

const PointsQuery = z.object({
  bbox: z.string().min(7).max(120),
  zoom: z.coerce.number().min(0).max(22),
  groups: GroupsParam.optional(),
});

/** A partir de este zoom se intentan devolver puntos individuales. */
const POINTS_MIN_ZOOM = 15;
/** Niveles con agregados precalculados en geo.map_cluster_cells (0010). */
const PRECOMPUTED_MIN_ZOOM = 6;
const PRECOMPUTED_MAX_ZOOM = 16;

export async function mapRoutes(app: FastifyInstance): Promise<void> {
  const { ctx } = app;

  app.get('/maps/styles', { preHandler: authenticate() }, async () => {
    const m = await readManifest(ctx.cfg.mapManifestPath);
    if (!m) return { installed: false, styles: [], attribution: '© OpenStreetMap contributors' };
    return {
      installed: true,
      name: m.name,
      version: m.version,
      isSynthetic: m.isSynthetic,
      attribution: m.attribution,
      bounds: m.bounds,
      center: m.center ?? null,
      minzoom: m.minzoom,
      maxzoom: m.maxzoom,
      tileUrlTemplate: '/tiles/{style}/{z}/{x}/{y}.png',
      styles: m.styles.map((s) => ({ id: s.id, name: s.name, kind: s.kind })),
    };
  });

  /**
   * Puntos de personas para la vista actual. Nunca devuelve el conjunto
   * completo: a zoom bajo agrega por celdas (ST_SnapToGrid) y a zoom alto
   * devuelve como máximo map.max_points puntos.
   */
  app.get('/maps/points', { preHandler: guard('persons.read') }, async (req) => {
    const q = PointsQuery.parse(req.query);
    const user = requireUser(req);
    const bbox = parseBBox(q.bbox);
    const groupIds = allowedGroups(ctx, user, q.groups);
    const restricted = canSeeRestricted(user);
    const exact = user.permissions.has('locations.exact.read');
    const maxPoints = await ctx.settings.number('map.max_points', 2000);
    const base = [bbox.west, bbox.south, bbox.east, bbox.north, groupIds, restricted];
    const filter = `l.geom && ST_MakeEnvelope($1, $2, $3, $4, 4326)::geography
      AND p.is_active AND (p.visibility = 'normal' OR $6::boolean)
      AND EXISTS (SELECT 1 FROM directory.person_memberships m
                   WHERE m.person_id = p.id AND m.group_id = ANY($5::smallint[]))`;

    const cell = clusterCellDegrees(q.zoom);
    const level = Math.round(q.zoom);
    // Ids reales de los grupos (no se asume el orden de inserción).
    const groupIdOf = (code: string) => ctx.groups.find((g) => g.code === code)?.id ?? -1;
    // Bits de geo.map_cluster_cells (0010): 1 = A, 2 = B, 4 = restringida.
    const mask = (groupIds.includes(groupIdOf('A')) ? 1 : 0) | (groupIds.includes(groupIdOf('B')) ? 2 : 0);
    const cellFilter = `level = $5::smallint
            AND cx BETWEEN floor($1::float8 / $8::float8)::int AND floor($3::float8 / $8::float8)::int
            AND cy BETWEEN floor($2::float8 / $8::float8)::int AND floor($4::float8 / $8::float8)::int
            AND flags & $6::int <> 0 AND (flags & 4 = 0 OR $7::boolean)`;

    if (exact && q.zoom >= POINTS_MIN_ZOOM) {
      // Cota superior barata con las celdas precalculadas: evita construir
      // miles de puntos para descartarlos cuando la vista está muy poblada.
      const boundLevel = Math.min(level, PRECOMPUTED_MAX_ZOOM);
      const bound = await ctx.db.query<{ n: number | null }>(
        `SELECT sum(n)::int AS n FROM geo.map_cluster_cells WHERE ${cellFilter}`,
        [bbox.west, bbox.south, bbox.east, bbox.north, boundLevel, mask, restricted, clusterCellDegrees(boundLevel)],
      );
      if ((bound.rows[0]?.n ?? 0) <= maxPoints) {
        // La consulta en vivo es la fuente exacta (la cota puede estar
        // desfasada hasta el siguiente refresco); si se pasa, se agrupa.
        const { rows } = await ctx.db.query(
          `SELECT p.id, p.code, p.given_names || ' ' || p.family_names AS name,
                  ST_Y(l.geom::geometry) AS lat, ST_X(l.geom::geometry) AS lon,
                  l.precision_level AS "precisionLevel", l.validation_status AS "validationStatus",
                  ARRAY(SELECT g.code FROM directory.person_memberships m
                          JOIN directory.person_groups g ON g.id = m.group_id
                         WHERE m.person_id = p.id AND m.group_id = ANY($5::smallint[]) ORDER BY g.code) AS groups
             FROM geo.person_locations l JOIN directory.persons p ON p.id = l.person_id
            WHERE ${filter}
            LIMIT $7`,
          [...base, maxPoints + 1],
        );
        if (rows.length <= maxPoints) return { mode: 'points', items: rows, truncated: false };
      }
    }

    if (level >= PRECOMPUTED_MIN_ZOOM && level <= PRECOMPUTED_MAX_ZOOM) {
      const { rows } = await ctx.db.query(
        `SELECT sum(n)::int AS count, sum(sum_lat) / sum(n) AS lat, sum(sum_lon) / sum(n) AS lon,
                bool_or(flags & $6::int & 1 <> 0) AS "hasA", bool_or(flags & $6::int & 2 <> 0) AS "hasB"
           FROM geo.map_cluster_cells
          WHERE ${cellFilter}
          GROUP BY cx, cy
          LIMIT 5000`,
        [bbox.west, bbox.south, bbox.east, bbox.north, level, mask, restricted, cell],
      );
      const state = await ctx.db.query<{ refreshedAt: Date; pending: boolean }>(
        `SELECT refreshed_at AS "refreshedAt", changed_at > refreshed_at AS pending FROM geo.map_cluster_state`);
      return {
        mode: 'clusters', cellDegrees: cell, items: rows, truncated: rows.length >= 5000,
        aggregatedAt: state.rows[0]?.refreshedAt.toISOString() ?? null,
        pendingChanges: state.rows[0]?.pending ?? false,
      };
    }

    const { rows } = await ctx.db.query(
      `SELECT count(*)::int AS count,
              avg(ST_Y(l.geom::geometry)) AS lat, avg(ST_X(l.geom::geometry)) AS lon,
              bool_or(EXISTS (SELECT 1 FROM directory.person_memberships m
                               WHERE m.person_id = p.id AND m.group_id = $8 AND $8 = ANY($5::smallint[]))) AS "hasA",
              bool_or(EXISTS (SELECT 1 FROM directory.person_memberships m
                               WHERE m.person_id = p.id AND m.group_id = $9 AND $9 = ANY($5::smallint[]))) AS "hasB"
         FROM geo.person_locations l JOIN directory.persons p ON p.id = l.person_id
        WHERE ${filter}
        GROUP BY ST_SnapToGrid(l.geom::geometry, $7)
        LIMIT 5000`,
      [...base, cell, groupIdOf('A'), groupIdOf('B')],
    );
    return { mode: 'clusters', cellDegrees: cell, items: rows, truncated: rows.length >= 5000 };
  });
}
