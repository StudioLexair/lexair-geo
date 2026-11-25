import type { Db } from '../../db/pool.js';
import { precisionForGranularity } from '../../lib/geo.js';
import { extractMunicipalityContext, parseAddressQuery, type MunicipalityRef } from '../../lib/text.js';

export type GeocodeResult = {
  kind: 'address' | 'street' | 'locality' | 'poi' | 'municipality';
  label: string;
  lat: number;
  lon: number;
  granularity: 'dwelling' | 'street' | 'locality' | 'poi' | 'municipality';
  suggestedPrecision: string;
  confidence: number;
  municipalityId: number | null;
  municipality: string | null;
  localityId: number | null;
  locality: string | null;
  source: string;
  isSynthetic: boolean;
  note: string | null;
};

type Row = Omit<GeocodeResult, 'suggestedPrecision' | 'note' | 'confidence'> & {
  score: number;
  house_number: string | null;
};

/**
 * Geocodificador local. Combina direcciones/tramos de calle, alias,
 * localidades, puntos de interés y municipios. Nunca fabrica coordenadas:
 * si no hay coincidencias devuelve una lista vacía.
 */
export async function geocode(
  db: Db,
  raw: string,
  opts: { municipalityId?: number | undefined; limit: number },
): Promise<GeocodeResult[]> {
  let q = parseAddressQuery(raw);
  if (q.full.length < 2) return [];
  let municipalityId = opts.municipalityId;
  const ctx = extractMunicipalityContext(q.full, await municipalityRefs(db));
  if (ctx && (municipalityId === undefined || municipalityId === ctx.municipalityId)) {
    municipalityId = ctx.municipalityId;
    q = parseAddressQuery(ctx.rest);
  }
  const streetText = stripGenericStreetWord(q.street || q.full);
  const client = await db.connect();
  try {
    await client.query('BEGIN READ ONLY');
    await client.query(`SELECT set_config('pg_trgm.word_similarity_threshold', '0.45', true),
                               set_config('pg_trgm.similarity_threshold', '0.3', true)`);
    const { rows } = await client.query<Row>(GEOCODE_SQL, [
      streetText, q.houseNumber, municipalityId ?? null, opts.limit * 3,
    ]);
    await client.query('COMMIT');
    return rank(rows, q.houseNumber, opts.limit);
  } catch (err) {
    await client.query('ROLLBACK').catch(() => undefined);
    throw err;
  } finally {
    client.release();
  }
}

/**
 * En la cartografía OSM cubana la mayoría de calles no incluyen «Calle» en el
 * nombre ("Martí", "Independencia"); si el usuario lo escribe, la similitud
 * favorecería a calles llamadas literalmente "Calle C". Se ignora solo si queda
 * texto suficiente ("calle c" se mantiene).
 */
export function stripGenericStreetWord(t: string): string {
  const m = t.match(/^(calle|c)\s+(.+)$/);
  return m && m[2] && m[2].replace(/\d+/g, '').trim().length >= 3 ? m[2] : t;
}

let muniCache: { at: number; refs: MunicipalityRef[] } | null = null;

/** Nombres normalizados de municipios (caché de 5 min; son 13 y casi nunca cambian). */
async function municipalityRefs(db: Db): Promise<MunicipalityRef[]> {
  if (muniCache && Date.now() - muniCache.at < 300_000) return muniCache.refs;
  const { rows } = await db.query<MunicipalityRef>('SELECT id, name_norm AS norm FROM geo.municipalities');
  muniCache = { at: Date.now(), refs: rows };
  return rows;
}

function rank(rows: Row[], houseNumber: string | null, limit: number): GeocodeResult[] {
  const seen = new Set<string>();
  const out: GeocodeResult[] = [];
  for (const r of rows.sort((a, b) => b.score - a.score)) {
    let granularity = r.granularity;
    let label = r.label;
    let kind = r.kind;
    if (r.kind === 'address' && houseNumber && r.house_number?.toLowerCase() !== houseNumber) {
      // El número pedido no existe: se ofrece la calle, sin mostrar otro número.
      granularity = 'street';
      kind = 'street';
      label = r.label.replace(/ #[^#]*$/, '');
    }
    const key = kind === 'street'
      ? `street|${label}|${r.municipalityId}|${r.localityId}`
      : `${kind}|${label}|${r.lat.toFixed(5)}|${r.lon.toFixed(5)}`;
    if (seen.has(key)) continue;
    seen.add(key);
    let note: string | null = null;
    let confidence = Math.min(1, r.score);
    if (houseNumber && granularity === 'street') {
      note = `Número ${houseNumber} no encontrado: la posición representa la calle, no la vivienda`;
      confidence *= 0.7;
    } else if (granularity === 'street') {
      note = 'La posición representa un tramo de calle, no una vivienda concreta';
    }
    out.push({
      kind, label, lat: r.lat, lon: r.lon, granularity,
      suggestedPrecision: precisionForGranularity(granularity),
      confidence: Math.round(confidence * 1000) / 1000,
      municipalityId: r.municipalityId, municipality: r.municipality,
      localityId: r.localityId, locality: r.locality,
      source: r.source, isSynthetic: r.isSynthetic, note,
    });
    if (out.length >= limit) break;
  }
  return out;
}

const GEOCODE_SQL = `
WITH q AS (SELECT catalog.normalize_text($1) AS t, lower($2::text) AS num, $3::int AS muni),
alias_hits AS (
  SELECT DISTINCT a.street_norm, word_similarity(q.t, a.alias_norm) AS s
    FROM geo.street_aliases a, q
   WHERE q.t <% a.alias_norm AND (q.muni IS NULL OR a.municipality_id IS NULL OR a.municipality_id = q.muni)
),
addr AS (
  SELECT CASE WHEN ad.granularity = 'dwelling' THEN 'address' ELSE 'street' END AS kind,
         ad.street_name || coalesce(' #' || ad.house_number, '') AS label,
         ad.house_number, ad.granularity, ad.geom, ad.municipality_id, ad.locality_id, ad.source_code,
         word_similarity(q.t, ad.search_norm)
           + CASE WHEN q.num IS NOT NULL AND lower(ad.house_number) = q.num THEN 0.25 ELSE 0 END AS score
    FROM geo.addresses ad, q
   WHERE (q.t <% ad.search_norm) AND (q.muni IS NULL OR ad.municipality_id = q.muni)
  UNION ALL
  SELECT 'street', ad.street_name, ad.house_number, ad.granularity, ad.geom, ad.municipality_id,
         ad.locality_id, ad.source_code, ah.s * 0.95
    FROM alias_hits ah JOIN geo.addresses ad ON ad.search_norm = ah.street_norm, q
   WHERE ad.granularity = 'street' AND (q.muni IS NULL OR ad.municipality_id = q.muni)
),
loc AS (
  SELECT 'locality' AS kind, l.name AS label, NULL::text AS house_number, 'locality' AS granularity,
         l.centroid AS geom, l.municipality_id, l.id AS locality_id, l.source_code,
         CASE WHEN l.name_norm = q.t
           THEN 1.05 + CASE l.kind WHEN 'city' THEN 0.06 WHEN 'town' THEN 0.04 WHEN 'suburb' THEN 0.01 ELSE 0.02 END
           WHEN l.kind IN ('city', 'town') AND word_similarity(q.t, l.name_norm) = 1
             THEN CASE l.kind WHEN 'city' THEN 1.03 ELSE 1.01 END
           ELSE similarity(q.t, l.name_norm) * 0.9 END AS score
    FROM geo.localities l, q
   WHERE (q.t % l.name_norm OR q.t <% l.name_norm) AND (q.muni IS NULL OR l.municipality_id = q.muni)
),
poi AS (
  SELECT 'poi' AS kind, p.name || ' (' || p.category || ')' AS label, NULL::text AS house_number,
         'poi' AS granularity, p.geom, p.municipality_id, NULL::int AS locality_id, p.source_code,
         word_similarity(q.t, p.name_norm) * 0.85 AS score
    FROM geo.points_of_interest p, q
   WHERE q.t <% p.name_norm AND (q.muni IS NULL OR p.municipality_id = q.muni)
),
mun AS (
  SELECT 'municipality' AS kind, m.name AS label, NULL::text AS house_number, 'municipality' AS granularity,
         ST_PointOnSurface(m.boundary)::geography AS geom, m.id AS municipality_id, NULL::int AS locality_id,
         m.source_code, CASE WHEN m.name_norm = q.t THEN 1.08
           WHEN word_similarity(q.t, m.name_norm) = 1 THEN 1.0 ELSE similarity(q.t, m.name_norm) * 0.8 END AS score
    FROM geo.municipalities m, q
   WHERE m.boundary IS NOT NULL AND (q.t % m.name_norm OR q.t <% m.name_norm)
),
allr AS (
  SELECT * FROM (SELECT * FROM addr ORDER BY score DESC LIMIT $4) a
  UNION ALL SELECT * FROM (SELECT * FROM loc ORDER BY score DESC LIMIT $4) b
  UNION ALL SELECT * FROM (SELECT * FROM poi ORDER BY score DESC LIMIT $4) c
  UNION ALL SELECT * FROM mun
)
SELECT r.kind, r.label, r.house_number, r.granularity, r.score::float8 AS score,
       ST_Y(r.geom::geometry) AS lat, ST_X(r.geom::geometry) AS lon,
       r.municipality_id AS "municipalityId", m.name AS municipality,
       r.locality_id AS "localityId", l.name AS locality,
       ds.attribution AS source, ds.is_synthetic AS "isSynthetic"
  FROM allr r
  LEFT JOIN geo.municipalities m ON m.id = r.municipality_id
  LEFT JOIN geo.localities l ON l.id = r.locality_id
  JOIN geo.data_sources ds ON ds.code = r.source_code
 ORDER BY r.score DESC
 LIMIT $4`;
