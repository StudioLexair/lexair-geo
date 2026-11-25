import { after, before, test } from 'node:test';
import assert from 'node:assert/strict';
import { execFileSync } from 'node:child_process';
import { mkdtempSync, rmSync } from 'node:fs';
import { tmpdir } from 'node:os';
import path from 'node:path';
import { createTileServer } from '../src/server.mjs';
import { tileIntersects, validTileCoords } from '../src/mbtiles.mjs';

let dir;
let server;
let base;

before(async () => {
  dir = mkdtempSync(path.join(tmpdir(), 'lexair-tiles-'));
  execFileSync(process.execPath, ['tools/make-synthetic-mbtiles.mjs', dir], {
    env: { ...process.env, SYNTH_MAXZ: '3' },
  });
  server = createTileServer(dir);
  await new Promise((r) => server.listen(0, '127.0.0.1', r));
  base = `http://127.0.0.1:${server.address().port}`;
});

after(() => {
  server.close();
  rmSync(dir, { recursive: true, force: true });
});

test('sirve un PNG válido con caché y ETag', async () => {
  const res = await fetch(`${base}/tiles/standard/2/1/1.png`);
  assert.equal(res.status, 200);
  assert.equal(res.headers.get('content-type'), 'image/png');
  const buf = Buffer.from(await res.arrayBuffer());
  assert.deepEqual([...buf.subarray(0, 4)], [0x89, 0x50, 0x4e, 0x47]);
  const etag = res.headers.get('etag');
  const again = await fetch(`${base}/tiles/standard/2/1/1.png`, { headers: { 'if-none-match': etag } });
  assert.equal(again.status, 304);
});

test('ruta sin estilo usa el estilo por defecto', async () => {
  const res = await fetch(`${base}/tiles/0/0/0.png`);
  assert.equal(res.status, 200);
});

test('rechaza estilos desconocidos, zoom fuera de rango y rutas maliciosas', async () => {
  assert.equal((await fetch(`${base}/tiles/satelite/1/0/0.png`)).status, 404);
  assert.equal((await fetch(`${base}/tiles/standard/9/0/0.png`)).status, 404);
  assert.equal((await fetch(`${base}/tiles/standard/1/5/0.png`)).status, 404);
  assert.equal((await fetch(`${base}/tiles/..%2f..%2fetc/1/0/0.png`)).status, 404);
  assert.equal((await fetch(`${base}/tiles/standard/1/0/0.png`, { method: 'POST' })).status, 405);
});

test('styles.json y health describen el paquete sintético', async () => {
  const styles = await (await fetch(`${base}/tiles/styles.json`)).json();
  assert.equal(styles.isSynthetic, true);
  assert.deepEqual(styles.styles.map((s) => s.id), ['standard', 'dark', 'high_contrast']);
  const health = await (await fetch(`${base}/health`)).json();
  assert.equal(health.status, 'ok');
  assert.ok(health.rssMb < 200);
});

test('validación de coordenadas de mosaico e intersección con límites', () => {
  assert.equal(validTileCoords(3, 7, 7, 0, 3), true);
  assert.equal(validTileCoords(3, 8, 0, 0, 3), false);
  assert.equal(validTileCoords(1.5, 0, 0, 0, 3), false);
  const vc = [-80.79, 21.92, -78.79, 23.47];
  // Mosaico z10 que contiene Santa Clara (x=284, y=446) frente a uno en Europa.
  assert.equal(tileIntersects(10, 284, 446, vc), true);
  assert.equal(tileIntersects(10, 512, 340, vc), false);
});

test('lee MBTiles deduplicados (map/images + vista tiles) como los genera render_mbtiles.py', async () => {
  const { DatabaseSync } = await import('node:sqlite');
  const { MBTiles } = await import('../src/mbtiles.mjs');
  const file = path.join(dir, 'dedup.mbtiles');
  const db = new DatabaseSync(file);
  db.exec(`CREATE TABLE metadata (name TEXT PRIMARY KEY, value TEXT);
    CREATE TABLE images (tile_id TEXT PRIMARY KEY, tile_data BLOB);
    CREATE TABLE map (zoom_level INTEGER, tile_column INTEGER, tile_row INTEGER, tile_id TEXT);
    CREATE VIEW tiles AS SELECT map.zoom_level, map.tile_column, map.tile_row, images.tile_data
      FROM map JOIN images ON images.tile_id = map.tile_id;
    INSERT INTO metadata VALUES ('format', 'png');
    INSERT INTO images VALUES ('a', X'89504E47');
    INSERT INTO map VALUES (2, 1, 2, 'a'), (2, 2, 2, 'a');`);
  db.close();
  const m = new MBTiles(file);
  // TMS fila 2 en z2 = XYZ y 1
  assert.deepEqual([...m.getTile(2, 1, 1)], [0x89, 0x50, 0x4e, 0x47]);
  assert.deepEqual(m.getTile(2, 2, 1), m.getTile(2, 1, 1));
  assert.equal(m.getTile(2, 0, 0), null);
  m.close();
});
