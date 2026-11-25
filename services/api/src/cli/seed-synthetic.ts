import { parseArgs } from 'node:util';
import pg from 'pg';

/**
 * Genera personas FICTICIAS para pruebas de rendimiento (is_synthetic = true,
 * código SYN-*, sin teléfonos). Las coordenadas se reparten alrededor de las
 * localidades OSM cargadas (ponderadas por tipo) y se descartan si caen fuera
 * de los límites municipales. Sin catálogo OSM se usa reparto uniforme en el
 * territorio permitido y se avisa de ello.
 *
 * Uso: node dist/cli/seed-synthetic.js --count 500000 [--batch 25000]
 */
const SYL = ['ka', 'lo', 'mi', 'ra', 'te', 'vi', 'do', 'sa', 'ne', 'ru', 'zo', 'be', 'li', 'na', 'to',
  'ge', 'fa', 'mo', 'xi', 'pe', 'du', 'ya', 'ce', 'ho'];

async function main(): Promise<void> {
  const { values } = parseArgs({ options: {
    count: { type: 'string', default: '500000' },
    batch: { type: 'string', default: '25000' },
    'start-at': { type: 'string', default: '1' },
  } });
  const total = Number(values.count);
  const batch = Number(values.batch);
  const start = Number(values['start-at']);
  if (!Number.isInteger(total) || total < 1 || total > 2_000_000) throw new Error('--count inválido');
  const client = new pg.Client({ connectionString: process.env.DATABASE_URL });
  await client.connect();
  const t0 = Date.now();
  try {
    const loc = await client.query<{ n: number }>('SELECT count(*)::int AS n FROM geo.localities');
    const mode = (loc.rows[0]?.n ?? 0) > 0 ? 'osm_localities' : 'uniform_bbox';
    if (mode === 'uniform_bbox') console.warn('AVISO: sin localidades OSM; reparto uniforme sintético');
    await client.query(`CREATE TEMP TABLE seeds AS
      SELECT row_number() OVER () AS rn, centroid::geometry AS g,
             CASE kind WHEN 'city' THEN 0.014 WHEN 'town' THEN 0.006 WHEN 'suburb' THEN 0.004 ELSE 0.0025 END AS sigma,
             CASE kind WHEN 'city' THEN 60 WHEN 'town' THEN 12 WHEN 'suburb' THEN 8 WHEN 'village' THEN 3 ELSE 1 END AS w,
             municipality_id
        FROM geo.localities`);
    await client.query(`CREATE TEMP TABLE seed_pick AS
      SELECT s.*, sum(w) OVER (ORDER BY rn) - w AS lo, sum(w) OVER (ORDER BY rn) AS hi,
             sum(w) OVER () AS tot FROM seeds s`);
    const bbox = await client.query<{ value: { west: number; south: number; east: number; north: number } }>(
      "SELECT value FROM catalog.system_settings WHERE key = 'geo.allowed_bbox'");
    const b = bbox.rows[0]?.value ?? { west: -80.6, south: 22.0, east: -79.3, north: 22.9 };
    for (let from = start; from < start + total; from += batch) {
      const to = Math.min(from + batch - 1, start + total - 1);
      await client.query('BEGIN');
      await client.query(`
        WITH n AS (SELECT i, random() AS r1, random() AS r2, random() AS r3, random() AS rg FROM generate_series($1::int, $2::int) i),
        ins AS (
          INSERT INTO directory.persons (code, given_names, family_names, data_source, is_synthetic, consent_status)
          SELECT 'SYN-' || lpad(i::text, 7, '0'),
                 initcap(($3::text[])[1 + (i * 7) % 24] || ($3::text[])[1 + (i * 13) % 24] || ($3::text[])[1 + (i / 24) % 24]),
                 initcap(($3::text[])[1 + (i * 5) % 24] || ($3::text[])[1 + (i * 11 / 7) % 24] || 'n') || ' ' ||
                 initcap(($3::text[])[1 + (i * 17) % 24] || ($3::text[])[1 + (i / 576) % 24] || 'z'),
                 'synthetic_generator', true, 'not_required'
            FROM n
          ON CONFLICT (code) DO NOTHING
          RETURNING id, code
        ), mem AS (
          INSERT INTO directory.person_memberships (person_id, group_id, source)
          SELECT ins.id, g, 'migration' FROM ins,
                 (SELECT id FROM directory.person_groups WHERE code = 'A') ga,
                 (SELECT id FROM directory.person_groups WHERE code = 'B') gb,
                 LATERAL (SELECT unnest(CASE WHEN (hashtext(code) & 1023) < 614 THEN ARRAY[ga.id]
                                            WHEN (hashtext(code) & 1023) < 921 THEN ARRAY[gb.id]
                                            ELSE ARRAY[ga.id, gb.id] END) AS g) x
          RETURNING person_id
        )
        INSERT INTO geo.person_locations (person_id, geom, address_text, municipality_id, coord_source,
          precision_level, address_granularity, validation_status)
        SELECT ins.id, pt.g::geography, 'Dirección ficticia ' || substr(ins.code, 5), pt.muni, 'synthetic',
               'unverified', 'unknown', 'pending'
          FROM ins
          JOIN n ON 'SYN-' || lpad(n.i::text, 7, '0') = ins.code
          CROSS JOIN LATERAL (
            SELECT ST_SetSRID(ST_MakePoint(
                     ST_X(sp.g) + sp.sigma * sqrt(-2 * ln(greatest(n.r1, 1e-9))) * cos(2 * pi() * n.r2),
                     ST_Y(sp.g) + sp.sigma * sqrt(-2 * ln(greatest(n.r1, 1e-9))) * sin(2 * pi() * n.r2)), 4326) AS g0,
                   sp.g AS seed_g, sp.municipality_id AS seed_muni
              FROM seed_pick sp WHERE $4::text = 'osm_localities' AND n.rg * sp.tot >= sp.lo AND n.rg * sp.tot < sp.hi
             UNION ALL
            SELECT ST_SetSRID(ST_MakePoint($5::float8 + n.r1 * ($7::float8 - $5::float8), $6::float8 + n.r2 * ($8::float8 - $6::float8)), 4326), NULL, NULL
             WHERE $4::text <> 'osm_localities'
             LIMIT 1
          ) raw
          CROSS JOIN LATERAL (
            SELECT (SELECT m.id FROM geo.municipalities m WHERE m.boundary IS NOT NULL
                      AND ST_Contains(m.boundary, raw.g0) LIMIT 1) AS found
          ) f
          CROSS JOIN LATERAL (
            -- Punto fuera de los límites (mar, otra provincia): se usa el centroide de la localidad.
            SELECT CASE WHEN f.found IS NOT NULL OR raw.seed_g IS NULL THEN raw.g0 ELSE raw.seed_g END AS g,
                   coalesce(f.found, raw.seed_muni) AS muni
          ) pt`,
        [from, to, SYL, mode, b.west, b.south, b.east, b.north]);
      await client.query('COMMIT');
      console.log(`… ${to - start + 1}/${total} (${((Date.now() - t0) / 1000).toFixed(1)} s)`);
    }
    await client.query('ANALYZE directory.persons; ANALYZE directory.person_memberships; ANALYZE geo.person_locations');
    const c = await client.query(`SELECT (SELECT count(*) FROM directory.persons WHERE is_synthetic) AS persons,
      (SELECT count(*) FROM geo.person_locations l JOIN directory.persons p ON p.id = l.person_id
        WHERE p.is_synthetic) AS located`);
    console.log(JSON.stringify({ mode, ...c.rows[0], seconds: (Date.now() - t0) / 1000 }));
  } finally {
    await client.end();
  }
}

main().catch((err) => {
  console.error(err instanceof Error ? err.message : err);
  process.exit(1);
});
