import { mkdirSync, rmSync, writeFileSync } from 'node:fs';
import { createHash } from 'node:crypto';
import { readFileSync } from 'node:fs';
import path from 'node:path';
import { DatabaseSync } from 'node:sqlite';
import { encodePng } from '../src/png.mjs';

/**
 * Genera un paquete cartográfico SINTÉTICO (z0–z6) para pruebas y CI.
 * Los mosaicos son cuadrículas de colores: NO es cartografía de Villa Clara.
 * Uso: node tools/make-synthetic-mbtiles.mjs <directorio-salida>
 */
const out = process.argv[2] ?? 'synthetic-maps';
const MAXZ = Number(process.env.SYNTH_MAXZ ?? 6);
const STYLES = [
  { id: 'standard', name: 'Estándar (SINTÉTICO)', kind: 'standard', a: [230, 226, 218], b: [205, 220, 235] },
  { id: 'dark', name: 'Oscuro (SINTÉTICO)', kind: 'dark', a: [40, 44, 52], b: [60, 70, 90] },
  { id: 'high_contrast', name: 'Alto contraste (SINTÉTICO)', kind: 'high_contrast', a: [255, 255, 255], b: [0, 0, 0] },
];

rmSync(out, { recursive: true, force: true });
mkdirSync(out, { recursive: true });
const bounds = [-80.79, 21.92, -78.79, 23.47];
const manifestStyles = [];
for (const s of STYLES) {
  const file = `${s.id}.mbtiles`;
  const db = new DatabaseSync(path.join(out, file));
  db.exec(`CREATE TABLE metadata (name text, value text);
    CREATE TABLE tiles (zoom_level integer, tile_column integer, tile_row integer, tile_data blob);
    CREATE UNIQUE INDEX tile_index ON tiles (zoom_level, tile_column, tile_row);`);
  const meta = db.prepare('INSERT INTO metadata VALUES (?, ?)');
  for (const [k, v] of Object.entries({ name: s.name, format: 'png', minzoom: '0', maxzoom: String(MAXZ),
    bounds: bounds.join(','), attribution: 'SINTÉTICO — no es cartografía real', type: 'baselayer' })) meta.run(k, v);
  const ins = db.prepare('INSERT INTO tiles VALUES (?, ?, ?, ?)');
  db.exec('BEGIN');
  for (let z = 0; z <= MAXZ; z++) {
    const n = 1 << z;
    for (let x = 0; x < n; x++) for (let y = 0; y < n; y++) {
      const png = encodePng(256, 256, (px, py) => (((px >> 5) + (py >> 5) + x + y + z) % 2 ? s.a : s.b));
      ins.run(z, x, n - 1 - y, png);
    }
  }
  db.exec('COMMIT');
  db.close();
  const sha256 = createHash('sha256').update(readFileSync(path.join(out, file))).digest('hex');
  manifestStyles.push({ id: s.id, name: s.name, file, sha256, kind: s.kind });
}
const manifest = {
  name: 'lexair-synthetic', version: `synthetic-${new Date().toISOString().slice(0, 10)}`,
  generatedAt: new Date().toISOString(), isSynthetic: true,
  source: { name: 'Generador sintético de LEXAIR GEO', timestamp: null },
  attribution: 'Datos SINTÉTICOS de prueba — no es cartografía real',
  license: 'Interno', bounds, center: [-79.96, 22.41], minzoom: 0, maxzoom: MAXZ, styles: manifestStyles,
  missingFeatures: ['Paquete sintético: no contiene calles, localidades ni límites reales'],
};
writeFileSync(path.join(out, 'manifest.json'), JSON.stringify(manifest, null, 2));
console.log(`Paquete sintético creado en ${out} (z0–z${MAXZ}, ${STYLES.length} estilos)`);
