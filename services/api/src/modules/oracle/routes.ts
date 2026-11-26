import type { FastifyInstance } from 'fastify';
import { z } from 'zod';
import { withTransaction } from '../../db/pool.js';
import { badRequest, notFound } from '../../lib/errors.js';
import { guard, requireUser } from '../../plugins/auth.js';
import { writeAudit } from '../audit/audit-writer.js';
import { decryptSecret, deriveKey, encryptSecret } from './crypto.js';
import { rowsOf, withOracle } from './driver.js';
import { MappingSchema, runConnectorSync, type ConnectorCfg } from './sync.js';

const IdParams = z.object({ id: z.uuid() });

/**
 * Conectores Oracle 11g. La contraseña se guarda cifrada y jamás sale por el
 * API; los mappings (tabla Oracle → objetivo local) son configurables.
 */
const ConnectorBody = z.object({
  name: z.string().trim().min(2).max(120),
  host: z.string().trim().min(1).max(255),
  port: z.number().int().min(1).max(65535).default(1521),
  serviceKind: z.enum(['service', 'sid']).default('service'),
  serviceName: z.string().trim().min(1).max(64),
  username: z.string().trim().min(1).max(64),
  password: z.string().min(1).max(200).optional(),
  thickMode: z.boolean().default(false),
  mappings: z.array(MappingSchema).max(12).default([]),
  enabled: z.boolean().default(true),
});

function connectorDto(r: Record<string, unknown>) {
  return {
    id: r['id'],
    name: r['name'],
    host: r['host'],
    port: r['port'],
    serviceKind: r['service_kind'],
    serviceName: r['service_name'],
    username: r['username'],
    thickMode: r['thick_mode'],
    mappings: r['mappings'] ?? [],
    enabled: r['enabled'],
    lastRunAt: (r['last_run_at'] as Date | null)?.toISOString() ?? null,
    lastStatus: r['last_status'],
    createdAt: (r['created_at'] as Date)?.toISOString(),
  };
}

const CONNECTOR_COLUMNS = `id, name, host, port, service_kind, service_name, username,
       thick_mode, mappings, enabled, last_run_at, last_status, created_at`;

function keyOf(cfg: { jwtSecret: string }): Buffer {
  return deriveKey(process.env['ORACLE_ENCRYPTION_KEY']?.trim() || cfg.jwtSecret);
}

function connectorOptions(connector: ConnectorCfg, key: Buffer): Record<string, unknown> {
  return {
    user: connector.username,
    password: decryptSecret(connector.password_cipher, key),
    connectString: `${connector.host}:${connector.port}/${connector.service_kind === 'sid'
      ? ':' + connector.service_name : connector.service_name}`,
    ...connector.connect_extra,
    thickMode: connector.thick_mode,
  };
}

export async function oracleRoutes(app: FastifyInstance): Promise<void> {
  const { ctx } = app;

  app.get('/oracle/connectors', { preHandler: guard('oracle.sync') }, async () => {
    const { rows } = await ctx.db.query(`SELECT ${CONNECTOR_COLUMNS} FROM directory.oracle_connectors ORDER BY name`);
    return { items: rows.map(connectorDto) };
  });

  app.post('/oracle/connectors', { preHandler: guard('oracle.sync') }, async (req, reply) => {
    const user = requireUser(req);
    const b = ConnectorBody.parse(req.body);
    if (!b.password) throw badRequest('Indique la contraseña del usuario Oracle');
    const cipher = encryptSecret(b.password, keyOf(ctx.cfg));
    const id = await withTransaction(ctx.db, async (c) => {
      const { rows } = await c.query<{ id: string }>(
        `INSERT INTO directory.oracle_connectors
           (name, host, port, service_kind, service_name, username, password_cipher,
            thick_mode, mappings, enabled, created_by)
         VALUES ($1,$2,$3,$4,$5,$6,$7,$8,$9::jsonb,$10,$11) RETURNING id`,
        [b.name, b.host, b.port, b.serviceKind, b.serviceName, b.username, cipher,
          b.thickMode, JSON.stringify(b.mappings), b.enabled, user.id],
      );
      await writeAudit(c, req, { action: 'oracle_connector.create', entityType: 'oracle_connector',
        entityId: rows[0]!.id, details: { name: b.name, host: b.host, mappings: b.mappings.length } });
      return rows[0]!.id;
    });
    reply.code(201);
    const { rows } = await ctx.db.query(`SELECT ${CONNECTOR_COLUMNS} FROM directory.oracle_connectors WHERE id = $1`, [id]);
    return connectorDto(rows[0]!);
  });

  app.patch('/oracle/connectors/:id', { preHandler: guard('oracle.sync') }, async (req) => {
    const { id } = IdParams.parse(req.params);
    const b = ConnectorBody.omit({ name: true }).partial()
      .refine((o) => Object.keys(o).length > 0, 'Sin cambios').parse(req.body);
    const map: Array<[string, string]> = [['host', 'host'], ['port', 'port'], ['serviceKind', 'service_kind'],
      ['serviceName', 'service_name'], ['username', 'username'], ['thickMode', 'thick_mode'], ['enabled', 'enabled']];
    const sets: string[] = [];
    const params: unknown[] = [id];
    for (const [k, col] of map) {
      const v = (b as Record<string, unknown>)[k];
      if (v !== undefined) { params.push(v); sets.push(`${col} = $${params.length}`); }
    }
    if (b.password) { params.push(encryptSecret(b.password, keyOf(ctx.cfg))); sets.push(`password_cipher = $${params.length}`); }
    if (b.mappings) { params.push(JSON.stringify(b.mappings)); sets.push(`mappings = $${params.length}::jsonb`); }
    await withTransaction(ctx.db, async (c) => {
      const res = await c.query(
        `UPDATE directory.oracle_connectors SET ${sets.join(', ')} WHERE id = $1`, params);
      if ((res.rowCount ?? 0) === 0) throw notFound('Conector no encontrado');
      await writeAudit(c, req, { action: 'oracle_connector.update', entityType: 'oracle_connector', entityId: id,
        details: { fields: Object.keys(b).filter((f) => f !== 'password') } });
    });
    return { ok: true };
  });

  app.delete('/oracle/connectors/:id', { preHandler: guard('oracle.sync') }, async (req) => {
    const { id } = IdParams.parse(req.params);
    await withTransaction(ctx.db, async (c) => {
      const res = await c.query('DELETE FROM directory.oracle_connectors WHERE id = $1', [id]);
      if ((res.rowCount ?? 0) === 0) throw notFound('Conector no encontrado');
      await writeAudit(c, req, { action: 'oracle_connector.delete', entityType: 'oracle_connector', entityId: id });
    });
    return { ok: true };
  });

  /** Prueba ad-hoc de conexión con los campos del diálogo (no guarda nada). */
  app.post('/oracle/test-connection', { preHandler: guard('oracle.sync') }, async (req) => {
    const b = z.object({
      host: z.string().trim().min(1).max(200),
      port: z.coerce.number().int().min(1).max(65535),
      serviceName: z.string().trim().min(1).max(100),
      serviceKind: z.enum(['service', 'sid']).default('service'),
      username: z.string().trim().min(1).max(100),
      password: z.string().min(1).max(200),
      thickMode: z.boolean().default(false),
    }).parse(req.body ?? {});
    const timeoutMs = await ctx.settings.number('oracle.timeout_ms', 30000);
    const started = Date.now();
    const opts = {
      user: b.username,
      password: b.password,
      connectString: b.serviceKind === 'sid'
        ? `${b.host}:${b.port}/:${b.serviceName}`
        : `${b.host}:${b.port}/${b.serviceName}`,
      thickMode: b.thickMode,
    };
    const result = await withOracle(opts, async (conn) => {
      let banner: string | null;
      try {
        const r = await conn.execute('SELECT banner FROM v$version WHERE ROWNUM = 1', [], { outFormat: 4002 });
        banner = String((rowsOf(r)[0] as Record<string, unknown> | undefined)?.['banner'] ?? '') || null;
      } catch {
        banner = null; // v$version puede requerir privilegios: no es fatal.
      }
      return { banner };
    }, timeoutMs);
    await writeAudit(ctx.db, req, { action: 'oracle_connection.test', entityType: 'oracle_connector',
      entityId: null, success: true, details: { ms: Date.now() - started } });
    return { ok: true, elapsedMs: Date.now() - started, ...result };
  });

  /** Prueba de conexión: banner de la base y conteo por mapping (limitado). */
  app.post('/oracle/connectors/:id/test', { preHandler: guard('oracle.sync') }, async (req) => {
    const { id } = IdParams.parse(req.params);
    const { rows } = await ctx.db.query<ConnectorCfg>(
      'SELECT id, name, host, port, service_kind, service_name, username, password_cipher, thick_mode, connect_extra, mappings FROM directory.oracle_connectors WHERE id = $1',
      [id]);
    const connector = rows[0];
    if (!connector) throw notFound('Conector no encontrado');
    const timeoutMs = await ctx.settings.number('oracle.timeout_ms', 30000);
    const started = Date.now();
    const result = await withOracle(await connectorOptions(connector, keyOf(ctx.cfg)), async (conn) => {
      let banner: string | null;
      try {
        const b = await conn.execute('SELECT banner FROM v$version WHERE ROWNUM = 1', [], { outFormat: 4002 });
        banner = String((rowsOf(b)[0] as Record<string, unknown> | undefined)?.['banner'] ?? '') || null;
      } catch {
        banner = null; // v$version puede requerir privilegios: no es fatal.
      }
      const counts: Array<{ mapping: string; table: string; rows: number }> = [];
      for (const m of connector.mappings ?? []) {
        try {
          const table = m.sourceTable;
          const where = m.where ? `WHERE ${m.where}` : '';
          const r = await conn.execute(
            `SELECT COUNT(*) AS N FROM ${table} ${where}`, [], { outFormat: 4002 });
          counts.push({ mapping: m.type, table, rows: Number((rowsOf(r)[0] as Record<string, unknown>)?.['N'] ?? 0) });
        } catch (e) {
          throw badRequest(`La tabla «${m.sourceTable}» no es accesible: ${e instanceof Error ? e.message : String(e)}`);
        }
      }
      return { banner, counts };
    }, timeoutMs);
    await writeAudit(ctx.db, req, { action: 'oracle_connector.test', entityType: 'oracle_connector', entityId: id,
      success: true, details: { ms: Date.now() - started } });
    return { ok: true, elapsedMs: Date.now() - started, ...result };
  });

  /** Corrida de sincronización (real o dry-run). Protegida contra solaparse. */
  app.post('/oracle/connectors/:id/run', { preHandler: guard('oracle.sync') }, async (req) => {
    const { id } = IdParams.parse(req.params);
    const b = z.object({ dryRun: z.boolean().default(false) }).parse(req.body ?? {});
    const user = requireUser(req);
    const { rows } = await ctx.db.query<ConnectorCfg>(
      'SELECT id, name, host, port, service_kind, service_name, username, password_cipher, thick_mode, connect_extra, mappings FROM directory.oracle_connectors WHERE id = $1 AND enabled',
      [id]);
    const connector = rows[0];
    if (!connector) throw notFound('Conector no encontrado o deshabilitado');
    const timeoutMs = await ctx.settings.number('oracle.timeout_ms', 30000);
    const run = await runConnectorSync({
      connector, db: ctx.db, dryRun: b.dryRun, key: keyOf(ctx.cfg), timeoutMs, req, userId: user.id,
    });
    return { runId: run.runId, status: run.status, ...run.counters, error: run.error ?? null };
  });

  app.get('/oracle/runs', { preHandler: guard('oracle.sync') }, async (req) => {
    const q = z.object({
      connectorId: z.uuid().optional(),
      limit: z.coerce.number().int().min(1).max(200).default(50),
    }).parse(req.query);
    const params: unknown[] = [];
    let where = '';
    if (q.connectorId) { params.push(q.connectorId); where = 'WHERE r.connector_id = $1'; }
    const { rows } = await ctx.db.query(
      `SELECT r.id, r.connector_id AS "connectorId", c.name AS "connectorName", r.started_at AS "startedAt",
              r.finished_at AS "finishedAt", r.dry_run AS "dryRun", r.status,
              r.persons_upserted AS "persons", r.inmates_upserted AS "inmates",
              r.personnel_upserted AS "personnel", r.passes_upserted AS "passes",
              r.rows_read AS "rowsRead", r.rows_skipped AS "rowsSkipped", r.error_text AS "errorText",
              u.username AS "triggeredBy"
         FROM directory.oracle_runs r
         JOIN directory.oracle_connectors c ON c.id = r.connector_id
         LEFT JOIN identity.users u ON u.id = r.triggered_by
        ${where}
        ORDER BY r.started_at DESC
        LIMIT $${params.length + 1}`,
      [...params, q.limit],
    );
    return { items: rows };
  });
}
