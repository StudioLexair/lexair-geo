import path from 'node:path';
import pg from 'pg';
import { runMigrations } from '../db/migrator.js';

/** Uso: DATABASE_URL=... MIGRATIONS_DIR=... node dist/cli/migrate.js */
async function main(): Promise<void> {
  const url = process.env.MIGRATION_DATABASE_URL ?? process.env.DATABASE_URL;
  if (!url) throw new Error('Defina MIGRATION_DATABASE_URL o DATABASE_URL');
  const dir = path.resolve(process.env.MIGRATIONS_DIR ?? '../../database/migrations');
  const client = new pg.Client({ connectionString: url, application_name: 'lexair-geo-migrate' });
  await client.connect();
  try {
    const res = await runMigrations(client, dir);
    console.log(JSON.stringify({ migrationsDir: dir, applied: res.applied, alreadyApplied: res.skipped.length }));
  } finally {
    await client.end();
  }
}

main().catch((err) => {
  console.error(err instanceof Error ? err.message : err);
  process.exit(1);
});
