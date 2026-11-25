import type { AppConfig } from './config.js';
import type { Db } from './db/pool.js';
import type { SettingsService } from './modules/admin/settings-service.js';

export type GroupCode = 'A' | 'B';

export type GroupInfo = {
  id: number;
  code: GroupCode;
  name: string;
  readPermission: string;
  colorHex: string;
};

export type AuthUser = {
  id: string;
  username: string;
  displayName: string;
  role: string;
  rank: number;
  permissions: Set<string>;
  mustChangePassword: boolean;
  sessionId: string;
};

export type AppContext = {
  cfg: AppConfig;
  db: Db;
  settings: SettingsService;
  groups: GroupInfo[];
};

declare module 'fastify' {
  interface FastifyInstance {
    ctx: AppContext;
  }
  interface FastifyRequest {
    auth: AuthUser | null;
  }
}

declare module '@fastify/jwt' {
  interface FastifyJWT {
    payload: { sid: string; sub: string };
  }
}
