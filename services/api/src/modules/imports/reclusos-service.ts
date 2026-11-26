import { withTransaction, type DbClient } from '../../db/pool.js';
import { normalizeText } from '../../lib/text.js';
import { composeAddress, type ReclusoRow } from './reclusos-xml-parser.js';

const BATCH = 500;

export type ReclusosOutcome = {
  total: number;
  ok: number;
  inmates: number;
  located: number;
  errors: { row: number; message: string }[];
};

/**
 * Carga del libro de reclusos: personas por NIDENTIDAD (upsert), membresía al
 * grupo destino, ficha de interno (unidad + ingreso real) y ubicación
 * aproximada por municipio. La precisión exacta llega después con el kardex.
 */
type ReclusosDeps = {
  db: Parameters<typeof withTransaction>[0];
  settings: { number(key: string, fallback: number): Promise<number> };
};

export async function importReclusos(
  ctx: ReclusosDeps,
  rows: ReclusoRow[],
  muniMap: Map<string, number>,
  opts: { groupId: number; userId: string; dryRun: boolean; rowCap: number },
): Promise<ReclusosOutcome> {
  const errors: { row: number; message: string }[] = [];
  const capped = rows.slice(0, opts.rowCap);
  rows.slice(opts.rowCap).forEach((_, i) =>
    errors.push({ row: opts.rowCap + i + 1, message: 'supera el límite de filas por importación (xml.row_cap)' }));

  const usedInternCodes = new Set<string>();
  const batchRows = capped.map((r, i) => {
    let rowNo = i + 1;
    const address = composeAddress(r);
    const muniId = r.municipio ? (muniMap.get(normalizeText(r.municipio)) ?? null) : null;
    if (r.municipio && muniId == null) {
      errors.push({ row: rowNo, message: `municipio sin coincidencia: ${r.municipio}` });
    }
    let internCode: string | null = null;
    const exped = r.expediente.trim().toUpperCase();
    if (exped) {
      if (exped.match(/^[A-Z0-9][A-Z0-9/-]{2,31}$/) && !usedInternCodes.has(exped)) {
        internCode = exped;
        usedInternCodes.add(exped);
      } else {
        errors.push({ row: rowNo, message: 'expediente duplicado o con formato no válido (se ignora)' });
      }
    }
    return {
      row: rowNo,
      code: r.nidentidad,
      given: [r.nombre1, r.nombre2].filter(Boolean).join(' ').trim(),
      family: [r.apellido1, r.apellido2].filter(Boolean).join(' ').trim(),
      address,
      muniId,
      internCode,
      cdr: (r.cdr || '').trim() || null,
      facility: r.unidad || null,
      ingreso: r.fecIngresoReal ? `Ingreso real: ${r.fecIngresoReal}` : null,
      municipio: r.municipio || null,
    };
  }).filter((r) => r.given.length > 0 && r.family.length > 0);

  if (opts.dryRun) {
    return { total: rows.length, ok: batchRows.length, inmates: batchRows.filter((r) => r.facility).length,
      located: batchRows.filter((r) => r.muniId != null).length, errors };
  }

  let ok = 0;
  let located = 0;
  for (let i = 0; i < batchRows.length; i += BATCH) {
    const batch = batchRows.slice(i, i + BATCH);
    const data = JSON.stringify(batch.map((r) => ({
      code: r.code, given: r.given, family: r.family, address: r.address,
      muniId: r.muniId, internCode: r.internCode, facility: r.facility, ingreso: r.ingreso,
      cdr: r.cdr,
    })));
    const inserted = await withTransaction(ctx.db, async (c: DbClient) => {
      const up = await c.query<{ n: number }>(
        `WITH src AS (
           SELECT * FROM jsonb_to_recordset($1::jsonb) AS x(code text, given text, family text, cdr text)
         ), up AS (
           INSERT INTO directory.persons (code, given_names, family_names, data_source, cdr,
             consent_status, consent_recorded_at, created_by)
           SELECT code, given, family, 'reclusos_xml', cdr, 'not_required', now(), $2
             FROM src
           ON CONFLICT (code) DO UPDATE SET given_names = EXCLUDED.given_names,
             family_names = EXCLUDED.family_names, data_source = EXCLUDED.data_source,
             cdr = coalesce(EXCLUDED.cdr, directory.persons.cdr),
             is_active = true
           RETURNING id, code
         ), mem AS (
           INSERT INTO directory.person_memberships (person_id, group_id, source, added_by)
           SELECT id, $3, 'import', $2 FROM up
           ON CONFLICT (person_id, group_id) DO NOTHING
         ), res AS (
           SELECT count(*)::int AS n FROM up
         )
         SELECT n FROM res`,
        [data, opts.userId, opts.groupId],
      );
      const inmates = await c.query(
        `INSERT INTO directory.inmates AS im (person_id, intern_code, facility, status, notes, data_source, created_by)
         SELECT p.id, x.\"internCode\", nullif(x.\"facility\", ''), 'Internado', x.ingreso, 'reclusos_xml', $2
           FROM jsonb_to_recordset($1::jsonb) AS x(code text, \"internCode\" text, \"facility\" text, ingreso text)
           JOIN directory.persons p ON p.code = x.code
         ON CONFLICT (person_id) DO UPDATE SET intern_code = coalesce(EXCLUDED.intern_code, im.intern_code),
           facility = coalesce(EXCLUDED.facility, im.facility), status = 'Internado',
           notes = EXCLUDED.notes, is_active = true,
           updated_at = now()`,
        [data, opts.userId],
      );
      const locs = await c.query(
        `INSERT INTO geo.person_locations AS pl (person_id, geom, address_text, municipality_id,
           coord_source, precision_level, address_granularity, validation_status, updated_by)
         SELECT p.id, ST_PointOnSurface(mm.boundary), x.address, mm.id, 'geocoded_address',
                'general_area', 'municipality', 'pending', $2
           FROM jsonb_to_recordset($1::jsonb) AS x(code text, address text, \"muniId\" int)
           JOIN directory.persons p ON p.code = x.code
           JOIN geo.municipalities mm ON mm.id = x.\"muniId\" AND mm.boundary IS NOT NULL
         ON CONFLICT (person_id) DO UPDATE SET geom = EXCLUDED.geom, address_text = EXCLUDED.address_text,
           municipality_id = EXCLUDED.municipality_id, coord_source = 'geocoded_address',
           precision_level = 'general_area', address_granularity = 'municipality',
           validation_status = 'pending', verified_at = NULL, verified_by = NULL,
           updated_at = now(), updated_by = EXCLUDED.updated_by
         WHERE pl.precision_level IN ('general_area','unverified')`,
        [data, opts.userId],
      );
      return { up: Number((up.rows[0] as { n?: number } | undefined)?.n ?? 0),
        inmates: inmates.rowCount ?? 0, locs: locs.rowCount ?? 0 };
    });
    ok += inserted.up;
    located += inserted.locs;
    if (inserted.inmates < batch.length) {
      errors.push({ row: i + 1, message: 'algunas filas del lote quedaron sin ficha de interno' });
    }
  }
  return { total: rows.length, ok, inmates: batchRows.filter((r) => r.facility).length, located, errors };
}
