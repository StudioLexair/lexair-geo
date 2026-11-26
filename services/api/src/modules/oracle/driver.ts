import { AppError } from '../../lib/errors.js';

/**
 * Carga perezosa del driver Oracle (oracledb). Es una dependencia OPCIONAL:
 * el API arranca sin ella y los endpoints devuelven un error claro si falta.
 *
 * Modos:
 *  * THIN (por defecto): sin bibliotecas nativas, soporta Oracle 12.1+.
 *  * THICK (connector.thick_mode = true): requiere Oracle Instant Client y
 *    soporta Oracle 11g (11.2). La ruta del Instant Client se indica con la
 *    variable de entorno ORACLE_INSTANT_CLIENT (o ya está en el PATH/LD_LIBRARY_PATH).
 */
type OracleModule = Record<string, unknown> & {
  getConnection: (opts: Record<string, unknown>) => Promise<OracleConnection>;
  initOracleClient?: (opts?: { libDir?: string }) => void;
  thinModeInitialized?: () => boolean;
};

export type OracleConnection = {
  execute: (sql: string, binds?: unknown[], opts?: Record<string, unknown>) => Promise<{
    rows?: unknown[][] | Record<string, unknown>[];
    metaData?: { name: string }[];
  }>;
  close: () => Promise<void>;
  break?: () => Promise<void>;
};

let clientInitAttempted = false;

export function resetDriverCache(): void {
  clientInitAttempted = false;
}

function driverMissing(): AppError {
  return new AppError(503, 'ORACLE_DRIVER_MISSING',
    'El controlador de Oracle no está instalado en el servidor. '
    + 'Ejecute «npm ci» en services/api (incluye oracledb) o instale el paquete oracledb.');
}

/** Ruta del Instant Client para modo THICK (obligatorio para Oracle 11g). */
export function instantClientPath(): string | null {
  return process.env['ORACLE_INSTANT_CLIENT']?.trim() || null;
}

export async function getOracledb(thickMode: boolean): Promise<OracleModule> {
  let mod: OracleModule;
  try {
    // El paquete oracledb no exporta ESM con nombre; import dinámico de CJS.
    // Bajo ESM el namespace puede envolver el módulo en `default`.
    const imported = (await import('oracledb')) as unknown as OracleModule & { default?: OracleModule };
    mod = (imported.default ?? imported) as OracleModule;
  } catch {
    throw driverMissing();
  }
  if (thickMode && !clientInitAttempted) {
    if (!mod.initOracleClient) throw new AppError(503, 'ORACLE_DRIVER_OLD',
      'El paquete oracledb instalado no soporta modo THICK; actualícelo.');
    const libDir = instantClientPath();
    try {
      mod.initOracleClient(libDir ? { libDir } : undefined);
    } catch (e) {
      const msg = e instanceof Error ? e.message : String(e);
      throw new AppError(503, 'ORACLE_CLIENT_MISSING',
        `No se pudo iniciar el Instant Client (modo THICK para Oracle 11g): ${msg}. `
        + 'Defina ORACLE_INSTANT_CLIENT con la ruta del Instant Client de 64 bits.');
    }
    clientInitAttempted = true;
  }
  return mod;
}

export function connectString(host: string, port: number, kind: string, name: string): string {
  return kind === 'sid'
    ? `${host}:${port}:${name}`
    : `${host}:${port}/${name}`;
}

export async function withOracle<T>(
  connOpts: Record<string, unknown>,
  fn: (conn: OracleConnection) => Promise<T>,
  timeoutMs: number,
): Promise<T> {
  const mod = await getOracledb(Boolean(connOpts['thickMode']));
  let conn: OracleConnection | null = null;
  const timer = setTimeout(() => { void conn?.break?.(); }, timeoutMs);
  try {
    conn = await mod.getConnection(connOpts);
    return await fn(conn);
  } catch (e) {
    const msg = e instanceof Error ? e.message : String(e);
    if (/ORA-28040|ORA-03278|no matching authentication/i.test(msg)) {
      throw new AppError(502, 'ORACLE_PROTOCOL',
        'Oracle rechazó la conexión por versión de protocolo. Para Oracle 11g active '
        + 'el modo THICK en el conector y configure ORACLE_INSTANT_CLIENT.');
    }
    if (/DPI-1047|NJS-519/i.test(msg)) {
      throw new AppError(503, 'ORACLE_CLIENT_MISSING',
        `Falta la biblioteca cliente de Oracle: ${msg}. `
        + 'Para Oracle 11g instale el Instant Client y defina ORACLE_INSTANT_CLIENT.');
    }
    throw e instanceof AppError ? e : new AppError(502, 'ORACLE_ERROR', `Error de Oracle: ${msg}`);
  } finally {
    clearTimeout(timer);
    if (conn) await conn.close().catch(() => undefined);
  }
}

export function rowsOf(result: { rows?: unknown[][] | Record<string, unknown>[]; metaData?: { name: string }[] },
): Array<Record<string, unknown>> {
  if (!result.rows) return [];
  if (result.metaData) return result.rows as Array<Record<string, unknown>>;
  return result.rows as Array<Record<string, unknown>>;
}
