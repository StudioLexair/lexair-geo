import { createHash } from 'node:crypto';
import { readdir, readFile } from 'node:fs/promises';
import path from 'node:path';
import type pg from 'pg';

export type MigrationResult = { applied: string[]; skipped: string[] };

const LOCK_KEY = 74_201_157; // pg_advisory_lock: evita dos migradores a la vez

/**
 * Aplica en orden los ficheros NNNN_*.sql que aún no constan en
 * public.schema_migrations. Si un fichero ya aplicado cambió (SHA-256
 * distinto) se aborta: las migraciones publicadas son inmutables.
 */
export async function runMigrations(client: pg.ClientBase, dir: string): Promise<MigrationResult> {
  const files = (await readdir(dir)).filter((f) => /^\d{4}_[a-z0-9_]+\.sql$/.test(f)).sort();
  const result: MigrationResult = { applied: [], skipped: [] };
  await client.query('SELECT pg_advisory_lock($1)', [LOCK_KEY]);
  try {
    await client.query(`CREATE TABLE IF NOT EXISTS public.schema_migrations (
      filename text PRIMARY KEY, sha256 text NOT NULL, applied_at timestamptz NOT NULL DEFAULT now())`);
    const { rows } = await client.query<{ filename: string; sha256: string }>(
      'SELECT filename, sha256 FROM public.schema_migrations',
    );
    const done = new Map(rows.map((r) => [r.filename, r.sha256]));
    for (const file of files) {
      const sql = await readFile(path.join(dir, file), 'utf8');
      const sha = createHash('sha256').update(sql).digest('hex');
      const prev = done.get(file);
      if (prev) {
        if (prev !== sha) throw new Error(`La migración ${file} fue modificada tras aplicarse`);
        result.skipped.push(file);
        continue;
      }
      await client.query('BEGIN');
      try {
        await client.query(sql);
        await client.query('INSERT INTO public.schema_migrations (filename, sha256) VALUES ($1, $2)', [
          file,
          sha,
        ]);
        await client.query('COMMIT');
        result.applied.push(file);
      } catch (err) {
        await client.query('ROLLBACK');
        throw new Error(`Error en migración ${file}: ${(err as Error).message}`, { cause: err });
      }
    }
  } finally {
    await client.query('SELECT pg_advisory_unlock($1)', [LOCK_KEY]);
  }
  return result;
}
