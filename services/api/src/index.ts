import { buildApp } from './app.js';
import { loadConfig } from './config.js';
import { createPool } from './db/pool.js';
import { startClusterRefresher } from './modules/maps/cluster-refresher.js';

async function main(): Promise<void> {
  const cfg = loadConfig();
  const db = createPool(cfg);
  const app = await buildApp(cfg, db);
  const stopRefresher = startClusterRefresher(db, app.ctx.settings, app.log);
  const shutdown = async (signal: string) => {
    app.log.info({ signal }, 'Cerrando LEXAIR GEO API');
    stopRefresher();
    await app.close();
    await db.end();
    process.exit(0);
  };
  process.on('SIGTERM', () => void shutdown('SIGTERM'));
  process.on('SIGINT', () => void shutdown('SIGINT'));
  await app.listen({ host: cfg.host, port: cfg.port });
}

main().catch((err) => {
  console.error('No se pudo iniciar el API:', err instanceof Error ? err.message : err);
  process.exit(1);
});
