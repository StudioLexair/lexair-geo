import { parse } from 'csv-parse/sync';
import { z } from 'zod';
import { assertCoordinate, type BBox, PRECISION_LEVELS } from '../../lib/geo.js';
import { normalizeText } from '../../lib/text.js';
import { PersonCodeSchema } from '../persons/schemas.js';

export const REQUIRED_COLUMNS = ['code', 'given_names', 'family_names', 'data_source'] as const;
export const OPTIONAL_COLUMNS = [
  'phone', 'notes', 'lat', 'lon', 'address_text', 'municipality', 'precision_level', 'consent_status',
] as const;
export const MAX_ROWS = 50_000;

const emptyToNull = (v: unknown) => (typeof v === 'string' && v.trim() === '' ? null : v);

const RowSchema = z.object({
  code: PersonCodeSchema,
  given_names: z.string().trim().min(1).max(120),
  family_names: z.string().trim().min(1).max(120),
  data_source: z.string().trim().min(2).max(120),
  phone: z.preprocess(emptyToNull, z.string().trim().regex(/^[0-9 +()-]{5,25}$/).nullable().default(null)),
  notes: z.preprocess(emptyToNull, z.string().trim().max(2000).nullable().default(null)),
  lat: z.preprocess(emptyToNull, z.coerce.number().nullable().default(null)),
  lon: z.preprocess(emptyToNull, z.coerce.number().nullable().default(null)),
  address_text: z.preprocess(emptyToNull, z.string().trim().max(300).nullable().default(null)),
  municipality: z.preprocess(emptyToNull, z.string().trim().max(120).nullable().default(null)),
  precision_level: z.preprocess(
    emptyToNull,
    z.enum(PRECISION_LEVELS).exclude(['exact_verified']).nullable().default(null),
  ),
  consent_status: z.preprocess(
    emptyToNull,
    z.enum(['granted', 'not_required', 'pending', 'revoked']).nullable().default(null),
  ),
});
export type ImportRow = z.infer<typeof RowSchema> & { line: number; municipalityId: number | null };
export type RowError = { line: number; code: string | null; errors: string[] };

export type ValidationOutcome = { rows: ImportRow[]; errors: RowError[]; total: number };

/**
 * Valida un CSV completo sin tocar la base de datos. Códigos duplicados en el
 * mismo fichero, coordenadas incompletas o fuera de territorio y municipios
 * desconocidos se reportan por línea.
 */
export function validateCsv(text: string, municipalities: Map<string, number>, bbox: BBox): ValidationOutcome {
  let records: Record<string, string>[];
  try {
    records = parse(text, { columns: (h: string[]) => h.map((c) => c.trim().toLowerCase()),
      skip_empty_lines: true, trim: true, bom: true, relax_column_count: false });
  } catch (err) {
    return { rows: [], total: 0, errors: [{ line: 0, code: null, errors: [`CSV ilegible: ${(err as Error).message}`] }] };
  }
  const header = Object.keys(records[0] ?? {});
  const missing = REQUIRED_COLUMNS.filter((c) => !header.includes(c));
  if (records.length === 0 || missing.length > 0) {
    return { rows: [], total: records.length, errors: [{ line: 1, code: null,
      errors: [records.length === 0 ? 'El fichero no contiene filas' : `Faltan columnas: ${missing.join(', ')}`] }] };
  }
  if (records.length > MAX_ROWS) {
    return { rows: [], total: records.length, errors: [{ line: 0, code: null,
      errors: [`Máximo ${MAX_ROWS} filas por importación`] }] };
  }
  const rows: ImportRow[] = [];
  const errors: RowError[] = [];
  const seen = new Set<string>();
  records.forEach((rec, i) => {
    const line = i + 2;
    const parsed = RowSchema.safeParse(rec);
    if (!parsed.success) {
      errors.push({ line, code: rec['code'] ?? null,
        errors: parsed.error.issues.map((x) => `${x.path.join('.')}: ${x.message}`) });
      return;
    }
    const r = parsed.data;
    const rowErrors: string[] = [];
    if (seen.has(r.code)) rowErrors.push('Código duplicado en el fichero');
    seen.add(r.code);
    if ((r.lat === null) !== (r.lon === null)) rowErrors.push('lat y lon deben indicarse juntas');
    if (r.lat !== null && r.lon !== null) {
      try { assertCoordinate(r.lat, r.lon, bbox); } catch (e) { rowErrors.push((e as Error).message); }
    }
    let municipalityId: number | null = null;
    if (r.municipality) {
      municipalityId = municipalities.get(normalizeText(r.municipality)) ?? null;
      if (municipalityId === null) rowErrors.push(`Municipio desconocido: ${r.municipality}`);
    }
    if (rowErrors.length) errors.push({ line, code: r.code, errors: rowErrors });
    else rows.push({ ...r, line, municipalityId });
  });
  return { rows, errors, total: records.length };
}
