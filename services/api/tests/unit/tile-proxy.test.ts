import { afterAll, beforeAll, describe, expect, it } from 'vitest';
import { createServer, type Server } from 'node:http';
import Fastify from 'fastify';
import { tileProxy } from '../../src/modules/maps/tile-proxy.js';

describe('proxy de mosaicos', () => {
  let upstream: Server;
  const app = Fastify();
  beforeAll(async () => {
    upstream = createServer((req, res) => {
      if (req.headers['if-none-match'] === '"test"') { res.writeHead(304); res.end(); return; }
      res.writeHead(200, { 'content-type': 'image/png', etag: '"test"', 'cache-control': 'public, max-age=86400' });
      res.end(Buffer.from([137, 80, 78, 71]));
    });
    await new Promise<void>((resolve) => upstream.listen(0, '127.0.0.1', resolve));
    const addr = upstream.address();
    if (!addr || typeof addr === 'string') throw new Error('Puerto de pruebas no disponible');
    app.decorate('ctx', { cfg: { tileServiceUrl: `http://127.0.0.1:${addr.port}` } });
    await app.register(tileProxy);
    await app.ready();
  });
  afterAll(async () => { await app.close(); await new Promise<void>((r) => upstream.close(() => r())); });
  it('entrega PNG y respeta caché', async () => {
    const r = await app.inject('/tiles/standard/10/284/446.png');
    expect(r.statusCode).toBe(200);
    expect(r.headers['content-type']).toBe('image/png');
    expect([...r.rawPayload]).toEqual([137, 80, 78, 71]);
    const cached = await app.inject({ url: '/tiles/standard/10/284/446.png', headers: { 'if-none-match': '"test"' } });
    expect(cached.statusCode).toBe(304);
  });
  it('rechaza rutas arbitrarias', async () => {
    const r = await app.inject('/tiles/standard/../../health');
    expect(r.statusCode).toBe(404);
  });
});
