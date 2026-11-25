import type { FastifyInstance } from 'fastify';
import { readManifest } from '../maps/manifest.js';
import { tileServiceHealth } from '../admin/status.js';

/**
 * Health checks públicos (sin datos personales): los usan el instalador,
 * Nginx, docker compose y el indicador de conexión de los clientes.
 */
export async function healthRoutes(app: FastifyInstance): Promise<void> {
  const { ctx } = app;

  app.get('/health/live', { config: { rateLimit: false } }, async () => ({ status: 'ok' }));

  app.get('/health', { config: { rateLimit: false } }, async (_req, reply) => {
    let dbOk: boolean;
    try {
      await ctx.db.query('SELECT 1');
      dbOk = true;
    } catch {
      dbOk = false;
    }
    const [tiles, manifest] = await Promise.all([
      tileServiceHealth(ctx.cfg.tileServiceUrl),
      readManifest(ctx.cfg.mapManifestPath),
    ]);
    const status = dbOk ? (tiles.ok ? 'ok' : 'degraded') : 'down';
    reply.code(dbOk ? 200 : 503);
    return {
      status,
      version: ctx.cfg.appVersion,
      time: new Date().toISOString(),
      services: {
        api: 'ok',
        database: dbOk ? 'ok' : 'down',
        tiles: tiles.ok ? 'ok' : 'down',
        search: dbOk ? 'ok' : 'down',
      },
      mapData: manifest
        ? { version: manifest.version, generatedAt: manifest.generatedAt,
            sourceTimestamp: manifest.source.timestamp ?? null, isSynthetic: manifest.isSynthetic }
        : null,
    };
  });
}
