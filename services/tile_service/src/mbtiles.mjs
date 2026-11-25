import { DatabaseSync } from 'node:sqlite';

/** Lector MBTiles de solo lectura (esquema TMS: fila invertida). */
export class MBTiles {
  constructor(file) {
    this.file = file;
    this.db = new DatabaseSync(file, { readOnly: true });
    this.stmt = this.db.prepare(
      'SELECT tile_data FROM tiles WHERE zoom_level = ? AND tile_column = ? AND tile_row = ?',
    );
    const rows = this.db.prepare('SELECT name, value FROM metadata').all();
    this.metadata = Object.fromEntries(rows.map((r) => [r.name, r.value]));
  }

  /** z/x/y en esquema XYZ (el de Leaflet y flutter_map). */
  getTile(z, x, y) {
    const tmsY = (1 << z) - 1 - y;
    const row = this.stmt.get(z, x, tmsY);
    return row ? Buffer.from(row.tile_data) : null;
  }

  close() {
    this.db.close();
  }
}

export function validTileCoords(z, x, y, minzoom, maxzoom) {
  if (![z, x, y].every(Number.isInteger)) return false;
  if (z < minzoom || z > maxzoom) return false;
  const n = 1 << z;
  return x >= 0 && y >= 0 && x < n && y < n;
}

/** ¿Intersecta el mosaico XYZ con los límites [oeste, sur, este, norte]? */
export function tileIntersects(z, x, y, bounds) {
  const n = 2 ** z;
  const lon1 = (x / n) * 360 - 180;
  const lon2 = ((x + 1) / n) * 360 - 180;
  const lat = (t) => (Math.atan(Math.sinh(Math.PI * (1 - (2 * t) / n))) * 180) / Math.PI;
  const latTop = lat(y);
  const latBottom = lat(y + 1);
  const [w, s, e, nn] = bounds;
  return lon2 >= w && lon1 <= e && latTop >= s && latBottom <= nn;
}
