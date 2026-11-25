import { createServer } from 'node:http';
import { readFileSync } from 'node:fs';
import path from 'node:path';
import { MBTiles, tileIntersects, validTileCoords } from './mbtiles.mjs';
import { encodePng, hexToRgb } from './png.mjs';

/**
 * LEXAIR GEO · servicio de mosaicos.
 * Sirve PNG pre-renderizados desde MBTiles locales. No renderiza nada en el
 * servidor de producción: el consumo típico es < 80 MB de RAM.
 *   GET /tiles/{style}/{z}/{x}/{y}.png   · GET /tiles/{z}/{x}/{y}.png (estilo por defecto)
 *   GET /tiles/styles.json               · GET /health
 */
const BG = { standard: '#f2efe9', dark: '#1d2026', high_contrast: '#ffffff', topographic: '#f4f1e6' };

export function loadPackage(mapDir) {
  const manifest = JSON.parse(readFileSync(path.join(mapDir, 'manifest.json'), 'utf8'));
  const styles = new Map();
  for (const s of manifest.styles) {
    if (!/^[a-z0-9_]+$/.test(s.id) || s.file.includes('..') || path.isAbsolute(s.file)) {
      throw new Error(`Estilo inválido en manifiesto: ${s.id}`);
    }
    const bg = /^#[0-9a-fA-F]{6}$/.test(s.background ?? '') ? s.background : (BG[s.kind] ?? BG.standard);
    const blank = encodePng(256, 256, () => hexToRgb(bg));
    styles.set(s.id, { meta: s, mbtiles: new MBTiles(path.join(mapDir, s.file)), blank });
  }
  if (styles.size === 0) throw new Error('El manifiesto no declara estilos');
  return { manifest, styles, defaultStyle: manifest.styles[0].id };
}

const TILE_RE = /^\/tiles\/(?:([a-z0-9_]+)\/)?(\d{1,2})\/(\d{1,7})\/(\d{1,7})\.png$/;

export function createTileServer(mapDir) {
  let pkg = loadPackage(mapDir);
  let served = 0;
  const startedAt = Date.now();

  const send = (res, code, body, headers = {}) => {
    res.writeHead(code, { 'X-Content-Type-Options': 'nosniff', ...headers });
    res.end(body);
  };
  const json = (res, code, obj) =>
    send(res, code, JSON.stringify(obj), { 'Content-Type': 'application/json; charset=utf-8', 'Cache-Control': 'no-cache' });

  const server = createServer((req, res) => {
    if (req.method !== 'GET' && req.method !== 'HEAD') return send(res, 405, '');
    const url = (req.url ?? '/').split('?')[0];
    if (url === '/health' || url === '/tiles/health') {
      const mem = process.memoryUsage();
      return json(res, 200, {
        status: 'ok', package: pkg.manifest.name, version: pkg.manifest.version,
        isSynthetic: pkg.manifest.isSynthetic, styles: [...pkg.styles.keys()], tilesServed: served,
        uptimeS: Math.round((Date.now() - startedAt) / 1000), rssMb: Math.round(mem.rss / 1048576),
      });
    }
    if (url === '/tiles/styles.json') {
      const m = pkg.manifest;
      return json(res, 200, {
        name: m.name, version: m.version, attribution: m.attribution, isSynthetic: m.isSynthetic,
        bounds: m.bounds, minzoom: m.minzoom, maxzoom: m.maxzoom,
        styles: m.styles.map((s) => ({ id: s.id, name: s.name, kind: s.kind,
          tiles: [`/tiles/${s.id}/{z}/{x}/{y}.png`] })),
      });
    }
    const m = TILE_RE.exec(url);
    if (!m) return send(res, 404, 'not found');
    const styleId = m[1] ?? pkg.defaultStyle;
    const style = pkg.styles.get(styleId);
    if (!style) return send(res, 404, 'unknown style');
    const [z, x, y] = [Number(m[2]), Number(m[3]), Number(m[4])];
    if (!validTileCoords(z, x, y, pkg.manifest.minzoom, pkg.manifest.maxzoom)) return send(res, 404, 'out of range');
    const etag = `"${pkg.manifest.version}-${styleId}-${z}-${x}-${y}"`;
    if (req.headers['if-none-match'] === etag) return send(res, 304, '', { ETag: etag });
    let tile = style.mbtiles.getTile(z, x, y);
    if (!tile) {
      // Fuera de cobertura: fondo neutro, nunca un mapa externo.
      if (!tileIntersects(z, x, y, pkg.manifest.bounds)) return send(res, 404, 'outside bounds');
      tile = style.blank;
    }
    served++;
    return send(res, 200, req.method === 'HEAD' ? '' : tile, {
      'Content-Type': 'image/png', 'Content-Length': String(tile.length),
      'Cache-Control': 'public, max-age=86400', ETag: etag,
    });
  });

  server.reload = () => {
    const next = loadPackage(mapDir);
    for (const s of pkg.styles.values()) s.mbtiles.close();
    pkg = next;
  };
  server.on('close', () => { for (const s of pkg.styles.values()) s.mbtiles.close(); });
  return server;
}

if (import.meta.url === `file://${process.argv[1]}`) {
  const mapDir = process.env.MAP_DIR ?? '/srv/lexair-geo/maps/current';
  const port = Number(process.env.PORT ?? 8081);
  const host = process.env.HOST ?? '0.0.0.0';
  const server = createTileServer(mapDir);
  process.on('SIGHUP', () => {
    try { server.reload(); console.log('Paquete cartográfico recargado'); }
    catch (err) { console.error('Recarga fallida; se mantiene el paquete anterior:', err.message); }
  });
  process.on('SIGTERM', () => server.close(() => process.exit(0)));
  server.listen(port, host, () => console.log(`LEXAIR GEO tiles en http://${host}:${port} (${mapDir})`));
}
