import type { Db } from '../../db/pool.js';
import type { BBox } from '../../lib/geo.js';

export type SettingRow = { key: string; value: unknown; description: string; updated_at: string };

/** Lectura de catalog.system_settings con caché corta (30 s). */
export class SettingsService {
  private cache: Map<string, unknown> | null = null;
  private loadedAt = 0;

  constructor(private readonly db: Db, private readonly ttlMs = 30_000) {}

  invalidate(): void {
    this.cache = null;
  }

  async all(): Promise<Map<string, unknown>> {
    if (this.cache && Date.now() - this.loadedAt < this.ttlMs) return this.cache;
    const { rows } = await this.db.query<SettingRow>('SELECT key, value FROM catalog.system_settings');
    this.cache = new Map(rows.map((r) => [r.key, r.value]));
    this.loadedAt = Date.now();
    return this.cache;
  }

  async number(key: string, fallback: number): Promise<number> {
    const v = (await this.all()).get(key);
    return typeof v === 'number' && Number.isFinite(v) ? v : fallback;
  }

  async numberList(key: string, fallback: number[]): Promise<number[]> {
    const v = (await this.all()).get(key);
    return Array.isArray(v) && v.every((n) => typeof n === 'number') ? (v as number[]) : fallback;
  }

  /** Territorio permitido para coordenadas (geo.allowed_bbox). */
  async allowedBBox(): Promise<BBox> {
    const v = (await this.all()).get('geo.allowed_bbox') as Partial<BBox> | undefined;
    if (v && [v.west, v.south, v.east, v.north].every((n) => typeof n === 'number')) {
      return v as BBox;
    }
    return { west: -85.2, south: 19.5, east: -74.0, north: 23.6 };
  }
}
