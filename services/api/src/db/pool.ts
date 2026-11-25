import pg from 'pg';
import type { AppConfig } from '../config.js';

// numeric/bigint como number cuando es seguro (conteos, distancias).
pg.types.setTypeParser(pg.types.builtins.INT8, (v) => Number(v));
pg.types.setTypeParser(pg.types.builtins.NUMERIC, (v) => Number(v));

export type Db = pg.Pool;
export type DbClient = pg.PoolClient | pg.Pool;

/**
 * Pool limitado: con 30 puestos y consultas cortas bastan ~12 conexiones.
 * Un pool pequeño protege la memoria de PostgreSQL (cada backend ≈ 5–10 MB).
 */
export function createPool(cfg: AppConfig): Db {
  return new pg.Pool({
    connectionString: cfg.databaseUrl,
    max: cfg.dbPoolMax,
    idleTimeoutMillis: 30_000,
    connectionTimeoutMillis: 5_000,
    statement_timeout: cfg.dbStatementTimeoutMs,
    application_name: 'lexair-geo-api',
  });
}

export async function withTransaction<T>(db: Db, fn: (c: pg.PoolClient) => Promise<T>): Promise<T> {
  const client = await db.connect();
  try {
    await client.query('BEGIN');
    const result = await fn(client);
    await client.query('COMMIT');
    return result;
  } catch (err) {
    await client.query('ROLLBACK').catch(() => undefined);
    throw err;
  } finally {
    client.release();
  }
}
