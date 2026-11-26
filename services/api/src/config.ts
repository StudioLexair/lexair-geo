import { z } from 'zod';

/**
 * Configuración por variables de entorno. Ningún secreto tiene valor por
 * defecto: si falta JWT_SECRET o DATABASE_URL el proceso no arranca.
 */
const EnvSchema = z.object({
  NODE_ENV: z.enum(['development', 'test', 'production']).default('production'),
  HOST: z.string().default('0.0.0.0'),
  PORT: z.coerce.number().int().min(1).max(65535).default(3000),
  DATABASE_URL: z.string().min(10),
  DB_POOL_MAX: z.coerce.number().int().min(2).max(40).default(12),
  DB_STATEMENT_TIMEOUT_MS: z.coerce.number().int().min(500).max(60000).default(8000),
  JWT_SECRET: z.string().min(32, 'JWT_SECRET debe tener al menos 32 caracteres'),
  LOG_LEVEL: z.enum(['fatal', 'error', 'warn', 'info', 'debug', 'trace']).default('info'),
  TRUST_PROXY: z
    .string()
    .default('127.0.0.1')
    .transform((v) => v.split(',').map((s) => s.trim()).filter(Boolean)),
  MAP_MANIFEST_PATH: z.string().default('/srv/lexair-geo/maps/current/manifest.json'),
  TILE_SERVICE_URL: z.string().default('http://127.0.0.1:8081'),
  BACKUP_DIR: z.string().default('/srv/lexair-geo/backups'),
  MIGRATIONS_DIR: z.string().default('../../database/migrations'),
  APP_VERSION: z.string().default('0.1.0'),
  RATE_LIMIT_PER_MINUTE: z.coerce.number().int().min(30).max(100000).default(600),
  LOGIN_RATE_LIMIT_PER_MINUTE: z.coerce.number().int().min(3).max(100000).default(10),
  // Oracle: clave de cifrado de contraseñas de conectores y ruta del Instant
  // Client (necesario para el modo THICK con Oracle 11g). Ambas opcionales.
  ORACLE_ENCRYPTION_KEY: z.string().min(32).optional(),
  ORACLE_INSTANT_CLIENT: z.string().optional(),
});

export type AppConfig = {
  env: 'development' | 'test' | 'production';
  host: string;
  port: number;
  databaseUrl: string;
  dbPoolMax: number;
  dbStatementTimeoutMs: number;
  jwtSecret: string;
  logLevel: string;
  trustProxy: string[];
  mapManifestPath: string;
  tileServiceUrl: string;
  backupDir: string;
  migrationsDir: string;
  appVersion: string;
  rateLimitPerMinute: number;
  loginRateLimitPerMinute: number;
  oracleEncryptionKey: string | undefined;
  oracleInstantClient: string | undefined;
};

export function loadConfig(env: NodeJS.ProcessEnv = process.env): AppConfig {
  const parsed = EnvSchema.safeParse(env);
  if (!parsed.success) {
    const issues = parsed.error.issues.map((i) => `${i.path.join('.')}: ${i.message}`);
    throw new Error(`Configuración inválida:\n - ${issues.join('\n - ')}`);
  }
  const e = parsed.data;
  return {
    env: e.NODE_ENV,
    host: e.HOST,
    port: e.PORT,
    databaseUrl: e.DATABASE_URL,
    dbPoolMax: e.DB_POOL_MAX,
    dbStatementTimeoutMs: e.DB_STATEMENT_TIMEOUT_MS,
    jwtSecret: e.JWT_SECRET,
    logLevel: e.LOG_LEVEL,
    trustProxy: e.TRUST_PROXY,
    mapManifestPath: e.MAP_MANIFEST_PATH,
    tileServiceUrl: e.TILE_SERVICE_URL,
    backupDir: e.BACKUP_DIR,
    migrationsDir: e.MIGRATIONS_DIR,
    appVersion: e.APP_VERSION,
    rateLimitPerMinute: e.RATE_LIMIT_PER_MINUTE,
    loginRateLimitPerMinute: e.LOGIN_RATE_LIMIT_PER_MINUTE,
    oracleEncryptionKey: e.ORACLE_ENCRYPTION_KEY,
    oracleInstantClient: e.ORACLE_INSTANT_CLIENT,
  };
}
