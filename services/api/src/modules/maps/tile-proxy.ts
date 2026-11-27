import type { FastifyInstance } from 'fastify';

// Los mosaicos son públicos (solo cartografía OSM, nunca datos personales).
// Se limitan rutas y cabeceras: el cliente no puede elegir el destino remoto.
export async function tileProxy(app: FastifyInstance): Promise<void> {
  app.route({
    method: ['GET', 'HEAD'],
    url: '/tiles/*',
    handler: async (req, reply) => {
      const tail = (req.params as { '*': string })['*'];
      if (!/^(?:[a-z0-9_]+\/)?\d{1,2}\/\d{1,7}\/\d{1,7}\.png$/.test(tail)
          && tail !== 'styles.json') {
        return reply.code(404).send();
      }
      try {
        const headers: Record<string, string> = {};
        if (req.headers['if-none-match']) headers['if-none-match'] = req.headers['if-none-match'];
        const upstream = await fetch(`${app.ctx.cfg.tileServiceUrl}/tiles/${tail}`, {
          method: req.method, headers, signal: AbortSignal.timeout(5000), redirect: 'error',
        });
        for (const h of ['content-type', 'cache-control', 'etag']) {
          const value = upstream.headers.get(h);
          if (value) reply.header(h, value);
        }
        reply.code(upstream.status);
        if (req.method === 'HEAD' || upstream.status === 304) return reply.send();
        return reply.send(Buffer.from(await upstream.arrayBuffer()));
      } catch {
        return reply.code(503).send({ error: 'MAP_UNAVAILABLE', message: 'Mapa no disponible' });
      }
    },
  });
}
