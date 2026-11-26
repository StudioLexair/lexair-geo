/**
 * Declaración mínima del paquete OPCIONAL `oracledb`. Se instala con
 * `npm ci` en el servidor; el API funciona sin él (los endpoints de Oracle
 * devuelven ORACLE_DRIVER_MISSING). Para Oracle 11g se requiere el modo
 * THICK con Oracle Instant Client (ver docs/ORACLE_SYNC.md).
 */
declare module 'oracledb' {
  export const OUT_FORMAT_ARRAY: number;
  export const OUT_FORMAT_OBJECT: number;
  export function initOracleClient(opts?: { libDir?: string }): void;
  export function getConnection(opts: {
    user: string; password: string; connectString: string;
    [key: string]: unknown;
  }): Promise<Connection>;
  export type Connection = {
    execute(
      sql: string,
      binds?: unknown[],
      opts?: { outFormat?: number; maxRows?: number; [key: string]: unknown },
    ): Promise<{ rows?: unknown[]; metaData?: { name: string }[] }>;
    close(): Promise<void>;
    break(): Promise<void>;
  };
}
