import { readdir, stat } from 'node:fs/promises';
import path from 'node:path';
import type { AppContext } from '../../types.js';
import { readManifest } from '../maps/manifest.js';

export type BackupInfo = { file: string; sizeBytes: number; modifiedAt: string };

export async function listBackups(dir: string): Promise<BackupInfo[]> {
  try {
    const files = (await readdir(dir)).filter((f) => /^lexair_geo_.*\.(dump|tar\.gz)$/.test(f));
    const infos = await Promise.all(files.map(async (f) => {
      const s = await stat(path.join(dir, f));
      return { file: f, sizeBytes: s.size, modifiedAt: s.mtime.toISOString() };
    }));
    return infos.sort((a, b) => b.modifiedAt.localeCompare(a.modifiedAt)).slice(0, 50);
  } catch {
    return [];
  }
}

export async function tileServiceHealth(url: string): Promise<{ ok: boolean; detail: unknown }> {
  try {
    const res = await fetch(`${url}/health`, { signal: AbortSignal.timeout(1500) });
    return { ok: res.ok, detail: res.ok ? await res.json() : `HTTP ${res.status}` };
  } catch (err) {
    return { ok: false, detail: (err as Error).message };
  }
}

/** Estado agregado para la pantalla «Estado del servidor». */
export async function serverStatus(ctx: AppContext) {
  const mem = process.memoryUsage();
  const started = Date.now();
  let database: Record<string, unknown>;
  try {
    const { rows } = await ctx.db.query(`SELECT version() AS version, postgis_lib_version() AS postgis,
        pg_database_size(current_database())::bigint AS size_bytes,
        (SELECT count(*)::int FROM pg_stat_activity WHERE datname = current_database()) AS connections,
        current_setting('shared_buffers') AS shared_buffers, current_setting('work_mem') AS work_mem,
        current_setting('max_connections') AS max_connections,
        (SELECT max(applied_at) FROM public.schema_migrations) AS last_migration`);
    database = { ok: true, latencyMs: Date.now() - started, ...rows[0] };
  } catch (err) {
    database = { ok: false, error: (err as Error).message };
  }
  const [manifest, tiles, backups] = await Promise.all([
    readManifest(ctx.cfg.mapManifestPath),
    tileServiceHealth(ctx.cfg.tileServiceUrl),
    listBackups(ctx.cfg.backupDir),
  ]);
  return {
    api: {
      version: ctx.cfg.appVersion,
      node: process.version,
      uptimeS: Math.round(process.uptime()),
      memory: { rssMb: Math.round(mem.rss / 1048576), heapUsedMb: Math.round(mem.heapUsed / 1048576) },
      pool: { total: ctx.db.totalCount, idle: ctx.db.idleCount, waiting: ctx.db.waitingCount },
    },
    database,
    tiles,
    cartography: manifest
      ? { installed: true, name: manifest.name, version: manifest.version, generatedAt: manifest.generatedAt,
          sourceTimestamp: manifest.source.timestamp ?? null, isSynthetic: manifest.isSynthetic,
          styles: manifest.styles.map((s) => s.id), missingFeatures: manifest.missingFeatures }
      : { installed: false },
    backups: { dir: ctx.cfg.backupDir, latest: backups[0] ?? null, items: backups },
  };
}
