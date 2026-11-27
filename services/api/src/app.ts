import Fastify, { type FastifyInstance } from 'fastify';
import fastifyJwt from '@fastify/jwt';
import rateLimit from '@fastify/rate-limit';
import { ZodError } from 'zod';
import type { AppConfig } from './config.js';
import type { Db } from './db/pool.js';
import { AppError, fromPgError } from './lib/errors.js';
import { SettingsService } from './modules/admin/settings-service.js';
import { adminRoutes } from './modules/admin/routes.js';
import { auditRoutes } from './modules/audit/routes.js';
import { authRoutes } from './modules/auth/routes.js';
import { exportRoutes } from './modules/exports/routes.js';
import { geocodingRoutes } from './modules/geocoding/routes.js';
import { healthRoutes } from './modules/health/routes.js';
import { importRoutes } from './modules/imports/routes.js';
import { oracleRoutes } from './modules/oracle/routes.js';
import { passRoutes } from './modules/passes/routes.js';
import { personnelRoutes } from './modules/personnel/routes.js';
import { locationRoutes } from './modules/locations/routes.js';
import { mapRoutes } from './modules/maps/routes.js';
import { tileProxy } from './modules/maps/tile-proxy.js';
import { personRoutes } from './modules/persons/routes.js';
import { searchRoutes } from './modules/search/routes.js';
import { userRoutes } from './modules/users/routes.js';
import { zoneRoutes } from './modules/zones/routes.js';
import type { GroupCode, GroupInfo } from './types.js';
import './types.js';

async function loadGroups(db: Db): Promise<GroupInfo[]> {
  const { rows } = await db.query<{ id: number; code: GroupCode; name: string; read_permission: string; color_hex: string }>(
    'SELECT id, code, name, read_permission, color_hex FROM directory.person_groups ORDER BY id',
  );
  return rows.map((r) => ({ id: r.id, code: r.code, name: r.name, readPermission: r.read_permission,
    colorHex: r.color_hex }));
}

export async function buildApp(cfg: AppConfig, db: Db): Promise<FastifyInstance> {
  const app = Fastify({
    logger: cfg.env === 'test' ? false : {
      level: cfg.logLevel,
      // Nunca registrar cabeceras de autorización ni cuerpos (contraseñas, coordenadas).
      redact: ['req.headers.authorization', 'req.headers.cookie'],
      serializers: {
        req: (r) => ({ method: r.method, url: r.url.split('?')[0], ip: r.ip }),
      },
    },
    trustProxy: cfg.trustProxy,
    bodyLimit: 1024 * 1024,
  });

  app.decorate('ctx', { cfg, db, settings: new SettingsService(db), groups: await loadGroups(db) });
  app.decorateRequest('auth', null);

  app.addContentTypeParser(['image/jpeg', 'image/png', 'image/webp'], { parseAs: 'buffer', bodyLimit: 4 * 1024 * 1024 },
  (_req, body, done) => done(null, body));
app.addContentTypeParser(['application/xml', 'text/xml'], { parseAs: 'string', bodyLimit: 30 * 1024 * 1024 },
    (_req, body, done) => done(null, body as string));
  app.addContentTypeParser('text/csv', { parseAs: 'string', bodyLimit: 20 * 1024 * 1024 },
    (_req, body, done) => done(null, body));

  await app.register(fastifyJwt, { secret: cfg.jwtSecret, sign: { algorithm: 'HS256' },
    verify: { algorithms: ['HS256'] } });
  await app.register(rateLimit, { global: true, max: cfg.rateLimitPerMinute, timeWindow: '1 minute' });

  app.setErrorHandler((err, req, reply) => {
    if (err instanceof ZodError) {
      return reply.code(400).send({ error: 'VALIDATION_ERROR', message: 'Datos no válidos',
        details: err.issues.map((i) => ({ path: i.path.join('.'), message: i.message })) });
    }
    const appErr = err instanceof AppError ? err : fromPgError(err);
    if (appErr) {
      return reply.code(appErr.statusCode).send({ error: appErr.code, message: appErr.message,
        details: appErr.details });
    }
    const e = err as { statusCode?: number; message?: string };
    if (e.statusCode && e.statusCode >= 400 && e.statusCode < 500) {
      return reply.code(e.statusCode).send({ error: 'REQUEST_ERROR', message: e.message });
    }
    req.log.error({ err }, 'Error no controlado');
    return reply.code(500).send({ error: 'INTERNAL_ERROR', message: 'Error interno del servidor' });
  });

  app.setNotFoundHandler((_req, reply) => reply.code(404).send({ error: 'NOT_FOUND', message: 'Ruta inexistente' }));

  await app.register(tileProxy, { tileServiceUrl: cfg.tileServiceUrl });

  await app.register(async (api) => {
    for (const mod of [healthRoutes, authRoutes, personRoutes, locationRoutes, searchRoutes, geocodingRoutes,
      mapRoutes, zoneRoutes, personnelRoutes, passRoutes, oracleRoutes, adminRoutes, userRoutes,
      importRoutes, exportRoutes, auditRoutes]) {
      await api.register(mod);
    }
  }, { prefix: '/api/v1' });

  return app;
}
