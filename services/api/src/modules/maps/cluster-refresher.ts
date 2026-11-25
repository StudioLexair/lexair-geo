import type { FastifyBaseLogger } from 'fastify';
import type { Db } from '../../db/pool.js';
import type { SettingsService } from '../admin/settings-service.js';

/**
 * Refresca periódicamente geo.map_cluster_cells (migración 0010) cuando hay
 * cambios. La función SQL es idempotente y usa un bloqueo consultivo, así que
 * varias instancias o un refresco manual simultáneo no se pisan.
 * Intervalo: ajuste `map.cluster_refresh_s` (por defecto 60 s; 0 = desactivado).
 */
export function startClusterRefresher(db: Db, settings: SettingsService, log: FastifyBaseLogger): () => void {
  let timer: NodeJS.Timeout | undefined;
  let stopped = false;

  const schedule = async () => {
    if (stopped) return;
    const seconds = await settings.number('map.cluster_refresh_s', 60).catch(() => 60);
    timer = setTimeout(() => void tick(), Math.max(seconds, 10) * 1000);
    timer.unref();
  };

  const tick = async () => {
    try {
      const enabled = (await settings.number('map.cluster_refresh_s', 60)) > 0;
      if (enabled) {
        const t0 = Date.now();
        const { rows } = await db.query<{ refreshed: boolean }>(
          'SELECT geo.refresh_map_clusters(false) AS refreshed');
        if (rows[0]?.refreshed) log.info({ ms: Date.now() - t0 }, 'Agregados del mapa actualizados');
      }
    } catch (err) {
      log.warn({ err }, 'No se pudieron actualizar los agregados del mapa');
    } finally {
      await schedule();
    }
  };

  void schedule();
  return () => {
    stopped = true;
    if (timer) clearTimeout(timer);
  };
}
