/* eslint-disable max-lines -- parseo Oracle por bloques largos */
import type { FastifyRequest } from 'fastify';
import { z } from 'zod';
import type { DbClient } from '../../db/pool.js';
import { AppError } from '../../lib/errors.js';
import { writeAudit } from '../audit/audit-writer.js';
import { decryptSecret } from './crypto.js';
import { connectString, rowsOf, withOracle, type OracleConnection } from './driver.js';

/**
 * Motor de sincronización Oracle 11g → PostgreSQL/PostGIS.
 *
 * Cada conector define «mappings»: qué tabla/vista de Oracle alimenta cada
 * objetivo del esquema local (personas, internos, personal, pases), qué
 * columna es la clave externa y cómo se corresponden los campos. Todo es
 * configurable desde la administración; no hay nada fijo en el código.
 *
 * Oracle 11g no soporta `FETCH FIRST`: se acota con `ROWNUM` en subconsulta.
 */

export const MappingSchema = z.object({
  type: z.enum(['persons', 'inmates', 'personnel', 'passes']),
  sourceTable: z.string().trim().regex(
    /^[A-Za-z_][A-Za-z0-9_$#]{0,127}(\.[A-Za-z_][A-Za-z0-9_$#]{0,127})?$/,
    'Tabla Oracle no válida (admite ESQUEMA.TABLA)'),
  keyColumn: z.string().trim().regex(/^[A-Za-z_][A-Za-z0-9_$#]{0,127}$/),
  columns: z.record(z.string().trim().regex(/^[A-Za-z_][A-Za-z0-9_$#]{0,127}$/), z.string().max(400)).default({}),
  where: z.string().trim().max(1000).optional(),
  latColumn: z.string().trim().regex(/^[A-Za-z_][A-Za-z0-9_$#]{0,127}$/).nullish(),
  lonColumn: z.string().trim().regex(/^[A-Za-z_][A-Za-z0-9_$#]{0,127}$/).nullish(),
  codePrefix: z.string().trim().max(10).regex(/^[A-Z0-9-]*$/).optional(),
  groups: z.array(z.enum(['A', 'B'])).max(2).optional(),
  passTypeCode: z.string().trim().max(40).optional(),
  maxRows: z.number().int().min(1).max(200000).optional(),
}).refine((m) => Object.keys(m.columns).length > 0, 'El mapping necesita al menos una columna');

export type OracleMapping = z.infer<typeof MappingSchema>;

export type ConnectorCfg = {
  id: string; name: string; host: string; port: number; service_kind: string;
  service_name: string; username: string; password_cipher: string;
  thick_mode: boolean; connect_extra: Record<string, unknown>;
  mappings: OracleMapping[];
};

const IDENT = /^[A-Za-z_][A-Za-z0-9_$#]{0,127}$/;

function col(name: string | null | undefined): string | null {
  return name && IDENT.test(name) ? name : null;
}

/** Clave de persona/externa normalizada a código LEXAIR (A-Z0-9-, 3–32). */
function toCode(prefix: string, key: string): string | null {
  const safe = key.toUpperCase().replace(/[^A-Z0-9-]/g, '-').replace(/^-+|-+$/g, '').slice(0, 24);
  if (!safe) return null;
  const full = `${prefix}${safe}`.slice(0, 32);
  return /^[A-Z0-9][A-Z0-9-]{2,31}$/.test(full) ? full : null;
}

function textOf(v: unknown, max = 160): string | null {
  if (v === null || v === undefined) return null;
  const s = String(v).trim();
  return s === '' ? null : s.slice(0, max);
}

function phoneOf(v: unknown): string | null {
  const s = textOf(v, 25);
  return s && /^[0-9 +()-]{5,25}$/.test(s) ? s : null;
}

function dateOf(v: unknown): Date | null {
  if (v === null || v === undefined) return null;
  if (v instanceof Date) return Number.isNaN(v.getTime()) ? null : v;
  const t = Date.parse(String(v));
  return Number.isNaN(t) ? null : new Date(t);
}

function numOrNull(v: unknown): number | null {
  const n = typeof v === 'number' ? v : v === null || v === undefined || v === '' ? NaN : Number(v);
  return Number.isFinite(n) ? n : null;
}

/** SELECT con ROWNUM (compatible con 11g). Los identificadores ya están validados. */
function buildSelect(m: OracleMapping, cap: number): { sql: string; cols: string[] } {
  const wanted = new Map<string, string>();
  const addCol = (name: string | null | undefined, alias: string) => {
    const c = col(name);
    if (c && !wanted.has(alias)) wanted.set(alias, c);
  };
  for (const [field, oracleCol] of Object.entries(m.columns)) addCol(oracleCol, field);
  addCol(m.keyColumn, '__key');
  addCol(m.latColumn, '__lat');
  addCol(m.lonColumn, '__lon');
  const selectList = [...wanted.entries()]
    .map(([alias, c]) => `${c} AS "${alias}"`).join(', ');
  const table = m.sourceTable;
  const where = m.where ? `WHERE ${m.where}` : '';
  return {
    sql: `SELECT * FROM (SELECT ${selectList} FROM ${table} ${where} ORDER BY ${col(m.keyColumn)}) WHERE ROWNUM <= ${cap}`,
    cols: [...wanted.keys()],
  };
}

type SyncCounters = {
  persons: number; inmates: number; personnel: number; passes: number; read: number; skipped: number;
};

async function upsertPersons(
  c: DbClient, m: OracleMapping, prefix: string, row: Record<string, unknown>, counters: SyncCounters,
): Promise<string | null> {
  const key = textOf(row['__key'], 64);
  const code = key ? toCode(prefix, key) : null;
  const given = textOf(m.columns['givenNames'] ? row['givenNames'] : null, 120);
  const family = textOf(m.columns['familyNames'] ? row['familyNames'] : null, 120);
  if (!code || !given || !family) { counters.skipped += 1; return null; }
  const phone = phoneOf(row['phone']);
  const lat = numOrNull(row['__lat']);
  const lon = numOrNull(row['__lon']);
  const { rows } = await c.query<{ id: string; existed: boolean }>(
    `INSERT INTO directory.persons (code, given_names, family_names, phone, data_source, consent_status)
     VALUES ($1,$2,$3,$4,$5,'not_required')
     ON CONFLICT (code) DO UPDATE SET
       given_names = EXCLUDED.given_names, family_names = EXCLUDED.family_names,
       phone = COALESCE(EXCLUDED.phone, directory.persons.phone),
       is_active = true
     RETURNING id, (xmax = 0) AS existed`,
    [code, given, family, phone, `oracle:${m.sourceTable}`],
  );
  const personId = rows[0]!.id;
  const groupIds = (m.groups ?? ['A']).map((g) => g === 'A' ? 1 : 2);
  await c.query(
    `INSERT INTO directory.person_memberships (person_id, group_id, source)
     SELECT $1, g, 'import' FROM unnest($2::smallint[]) g
     ON CONFLICT (person_id, group_id) DO NOTHING`, [personId, groupIds]);
  if (lat !== null && lon !== null && Math.abs(lat) <= 90 && Math.abs(lon) <= 180) {
    await c.query(
      `INSERT INTO geo.person_locations
         (person_id, geom, coord_source, precision_level, address_granularity, validation_status)
       VALUES ($1, ST_SetSRID(ST_MakePoint($3, $2), 4326)::geography, 'gps_once',
               'general_area', 'locality', 'pending')
       ON CONFLICT (person_id) DO UPDATE SET
         geom = EXCLUDED.geom, coord_source = 'gps_once', updated_at = now(),
         validation_status = 'pending', verified_at = NULL, verified_by = NULL`,
      [personId, lat, lon]);
  }
  counters.persons += 1;
  return personId;
}

async function upsertInmate(
  c: DbClient, m: OracleMapping, prefix: string, row: Record<string, unknown>, counters: SyncCounters,
): Promise<void> {
  // La persona destino puede venir por mapeo directo del código de persona…
  let personId: string | null = null;
  const personCodeRaw = m.columns['personCode'] ? textOf(row['personCode'], 64) : null;
  if (personCodeRaw) {
    const code = /^[A-Z0-9][A-Z0-9-]{2,31}$/.test(personCodeRaw) ? personCodeRaw : toCode(prefix, personCodeRaw);
    if (code) {
      const r = await c.query<{ id: string }>('SELECT id FROM directory.persons WHERE code = $1', [code]);
      personId = r.rows[0]?.id ?? null;
    }
  }
  if (!personId) { counters.skipped += 1; return; }
  const internCode = m.columns['internCode'] ? textOf(row['internCode'], 32)?.toUpperCase() : null;
  await c.query(
    `INSERT INTO directory.inmates (person_id, intern_code, facility, status, risk_level, cell_ref, notes, data_source)
     VALUES ($1,$2,$3,$4,$5,$6,$7,'oracle')
     ON CONFLICT (person_id) DO UPDATE SET
       intern_code = COALESCE($2, directory.inmates.intern_code),
       facility = COALESCE($3, directory.inmates.facility),
       status = COALESCE($4, directory.inmates.status),
       risk_level = COALESCE($5, directory.inmates.risk_level),
       cell_ref = COALESCE($6, directory.inmates.cell_ref),
       notes = COALESCE($7, directory.inmates.notes),
       is_active = true`,
    [personId, internCode, textOf(row['facility']), textOf(row['status'], 60),
      textOf(row['riskLevel'], 40), textOf(row['cellRef'], 60), textOf(row['notes'], 2000)],
  );
  counters.inmates += 1;
}

async function upsertPersonnel(
  c: DbClient, m: OracleMapping, prefix: string, row: Record<string, unknown>, counters: SyncCounters,
): Promise<void> {
  const key = textOf(row['__key'], 64);
  if (!key) { counters.skipped += 1; return; }
  const fullName = textOf(m.columns['fullName'] ? row['fullName'] : null, 160);
  if (!fullName || fullName.length < 3) { counters.skipped += 1; return; }
  const lat = numOrNull(row['__lat']);
  const lon = numOrNull(row['__lon']);
  const point = lat !== null && lon !== null && Math.abs(lat) <= 90 && Math.abs(lon) <= 180
    ? 'ST_SetSRID(ST_MakePoint(' + lon + ', ' + lat + '), 4326)::geography' : null;
  await c.query(
    `INSERT INTO directory.personnel (code, full_name, rank, unit, phone, phone_alt, address_text,
       geom, external_ref, data_source)
     VALUES ($1,$2,$3,$4,$5,$6,$7,${point ? point + '::geography' : 'NULL'},$8,'oracle')
     ON CONFLICT (external_ref) DO UPDATE SET
       full_name = EXCLUDED.full_name, rank = EXCLUDED.rank, unit = EXCLUDED.unit,
       phone = COALESCE(EXCLUDED.phone, directory.personnel.phone),
       phone_alt = COALESCE(EXCLUDED.phone_alt, directory.personnel.phone_alt),
       address_text = COALESCE(EXCLUDED.address_text, directory.personnel.address_text),
       geom = COALESCE(EXCLUDED.geom, directory.personnel.geom)`,
    [toCode(prefix, key), fullName, textOf(row['rank'], 80), textOf(row['unit']),
      phoneOf(row['phone']), phoneOf(row['phoneAlt']), textOf(row['addressText'], 300), `oracle:${key}`],
  );
  counters.personnel += 1;
}

async function upsertPasses(
  c: DbClient, m: OracleMapping, prefix: string, row: Record<string, unknown>, counters: SyncCounters,
): Promise<void> {
  const key = textOf(row['__key'], 64);
  const personCodeRaw = m.columns['personCode'] ? textOf(row['personCode'], 64) : null;
  const starts = dateOf(row['startsAt']);
  const ends = dateOf(row['endsAt']);
  if (!key || !personCodeRaw || !starts || !ends || ends <= starts) { counters.skipped += 1; return; }
  const code = /^[A-Z0-9][A-Z0-9-]{2,31}$/.test(personCodeRaw) ? personCodeRaw : toCode(prefix, personCodeRaw);
  const person = code
    ? await c.query<{ id: string }>('SELECT id FROM directory.persons WHERE code = $1', [code])
    : { rows: [] as Array<{ id: string }> };
  const personId = person.rows[0]?.id ?? null;
  if (!personId) { counters.skipped += 1; return; }
  const typeCode = m.passTypeCode ?? 'pase_ordinario';
  await c.query(
    `INSERT INTO directory.passes (person_id, intern_id, pass_type_id, facility, starts_at, ends_at,
       authorized_address, notes, external_ref, data_source)
     SELECT $1, i.person_id,
            (SELECT id FROM directory.pass_types WHERE code = $2 AND is_active LIMIT 1),
            $3, $4, $5, $6, $7, $8, 'oracle'
       FROM (SELECT person_id FROM directory.inmates WHERE person_id = $1) i
     ON CONFLICT (external_ref) DO UPDATE SET
       starts_at = EXCLUDED.starts_at, ends_at = EXCLUDED.ends_at,
       facility = COALESCE(EXCLUDED.facility, directory.passes.facility),
       authorized_address = COALESCE(EXCLUDED.authorized_address, directory.passes.authorized_address),
       notes = COALESCE(EXCLUDED.notes, directory.passes.notes)`,
    [personId, typeCode, textOf(row['facility']),
      starts.toISOString(), ends.toISOString(), textOf(row['authorizedAddress'], 300),
      textOf(row['notes'], 2000), `oracle:${key}`],
  );
  counters.passes += 1;
}

/** Ejecuta un mapping completo (una tabla Oracle → un objetivo). */
async function runMapping(
  conn: OracleConnection,
  c: DbClient,
  m: OracleMapping,
  counters: SyncCounters,
  dryRun: boolean,
): Promise<{ dryRows: number }> {
  const cap = m.maxRows ?? 20000;
  const { sql } = buildSelect(m, cap);
  const result = await conn.execute(sql, [], { outFormat: 4002, maxRows: cap });
  const rows = rowsOf(result);
  counters.read += rows.length;
  if (dryRun) return { dryRows: rows.length };
  const prefix = m.codePrefix ?? 'ORA-';
  for (const row of rows) {
    try {
      switch (m.type) {
        case 'persons': await upsertPersons(c, m, prefix, row, counters); break;
        case 'inmates': await upsertInmate(c, m, prefix, row, counters); break;
        case 'personnel': await upsertPersonnel(c, m, prefix, row, counters); break;
        case 'passes': await upsertPasses(c, m, prefix, row, counters); break;
      }
    } catch (e) {
      counters.skipped += 1;
      if (e instanceof AppError && e.code === 'QUERY_TIMEOUT') throw e;
    }
  }
  return { dryRows: rows.length };
}

/** Ejecuta todos los mappings del conector. Devuelve el resumen de la corrida. */
export async function runConnectorSync(opts: {
  connector: ConnectorCfg;
  db: DbClient;
  dryRun: boolean;
  key: Buffer;
  timeoutMs: number;
  req: FastifyRequest | null;
  userId: string | null;
}): Promise<{ runId: string; status: string; counters: SyncCounters; error?: string }> {
  const { connector, db, dryRun, key, timeoutMs, req, userId } = opts;
  // Contra corridas simultáneas del mismo conector (bloqueo consultivo).
  const lock = await db.query<{ ok: boolean }>(
    `SELECT pg_try_advisory_lock(hashtext($1)) AS ok`, [`lexair.oracle.run:${connector.id}`]);
  if (!lock.rows[0]?.ok) {
    throw new AppError(409, 'SYNC_IN_PROGRESS', 'Ya hay una sincronización en curso para este conector');
  }
  const { rows: runRows } = await db.query<{ id: string }>(
    `INSERT INTO directory.oracle_runs (connector_id, dry_run, triggered_by)
     VALUES ($1, $2, $3) RETURNING id`, [connector.id, dryRun, userId]);
  const runId = runRows[0]!.id;
  const counters: SyncCounters = { persons: 0, inmates: 0, personnel: 0, passes: 0, read: 0, skipped: 0 };
  let status = 'ok';
  let errorText: string | null = null;
  const connOpts: Record<string, unknown> = {
    user: connector.username,
    password: decryptSecret(connector.password_cipher, key),
    connectString: connectString(connector.host, connector.port,
      connector.service_kind, connector.service_name),
    ...connector.connect_extra,
    thickMode: connector.thick_mode,
  };
  try {
    await withOracle(connOpts, async (conn) => {
      for (const m of connector.mappings) {  
        try {
          await runMapping(conn, db, m, counters, dryRun);
        } catch (e) {
          // Un mapping que falla no aborta la corrida completa.
          if (e instanceof AppError && ['ORACLE_CLIENT_MISSING', 'ORACLE_DRIVER_MISSING',
            'ORACLE_PROTOCOL', 'QUERY_TIMEOUT'].includes(e.code)) throw e;
          counters.skipped += 1;
          errorText = errorText ? `${errorText}; ${e instanceof Error ? e.message : String(e)}`
            : (e instanceof Error ? e.message : String(e));
          status = 'partial';
        }
      }
    }, timeoutMs);
    if (counters.skipped > 0 && status === 'ok') status = counters.skipped >= counters.read && counters.read > 0 ? 'error' : 'partial';
    await db.query(
      `UPDATE directory.oracle_runs SET finished_at = now(), status = $2,
         persons_upserted = $3, inmates_upserted = $4, personnel_upserted = $5,
         passes_upserted = $6, rows_read = $7, rows_skipped = $8, error_text = $9
       WHERE id = $1`,
      [runId, status, counters.persons, counters.inmates, counters.personnel,
        counters.passes, counters.read, counters.skipped, errorText]);
    await db.query(
      `UPDATE directory.oracle_connectors SET last_run_at = now(), last_status = $2 WHERE id = $1`,
      [connector.id, status]);
    await writeAudit(db, req, { action: 'oracle.sync_run', entityType: 'oracle_connector',
      entityId: connector.id, details: { dryRun, status, ...counters } });
    return { runId, status, counters, error: errorText ?? undefined };
  } catch (e) {
    const msg = e instanceof Error ? e.message : String(e);
    await db.query(
      `UPDATE directory.oracle_runs SET finished_at = now(), status = 'error', error_text = $2,
         rows_read = $3, rows_skipped = $4 WHERE id = $1`,
      [runId, msg.slice(0, 2000), counters.read, counters.skipped]);
    await db.query(
      `UPDATE directory.oracle_connectors SET last_run_at = now(), last_status = 'error' WHERE id = $1`,
      [connector.id]);
    throw e;
  } finally {
    await db.query(`SELECT pg_advisory_unlock(hashtext($1))`, [`lexair.oracle.run:${connector.id}`]);
  }
}
