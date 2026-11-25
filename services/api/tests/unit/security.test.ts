import { describe, expect, it } from 'vitest';
import { loadConfig } from '../../src/config.js';
import { sanitizeDetails } from '../../src/modules/audit/audit-writer.js';
import {
  checkPasswordPolicy, generateTemporaryPassword, hashPassword, verifyPassword,
} from '../../src/modules/auth/password.js';
import { csvCell } from '../../src/modules/exports/routes.js';
import { fromPgError } from '../../src/lib/errors.js';

describe('contraseñas', () => {
  it('hash argon2id verificable', async () => {
    const h = await hashPassword('Clave-De-Prueba-123');
    expect(h.startsWith('$argon2id$')).toBe(true);
    expect(await verifyPassword(h, 'Clave-De-Prueba-123')).toBe(true);
    expect(await verifyPassword(h, 'otra')).toBe(false);
    expect(await verifyPassword('basura', 'x')).toBe(false);
  });
  it('política de contraseñas', () => {
    expect(checkPasswordPolicy('corta', 'ana').ok).toBe(false);
    expect(checkPasswordPolicy('solominusculaslargas', 'ana').ok).toBe(false);
    expect(checkPasswordPolicy('Operador-2026-xyz', 'operador').ok).toBe(false);
    expect(checkPasswordPolicy('Buena-Clave-2026', 'ana').ok).toBe(true);
  });
  it('contraseñas temporales aleatorias y distintas', () => {
    const a = generateTemporaryPassword();
    expect(a).toMatch(/^[A-Za-z0-9]{6}-[A-Za-z0-9]{6}-[A-Za-z0-9]{6}!$/);
    expect(generateTemporaryPassword()).not.toBe(a);
  });
});

describe('auditoría', () => {
  it('elimina claves sensibles', () => {
    expect(sanitizeDetails({ password: 'x', lat: 1, lon: 2, token: 't', code: 'A1', fields: ['phone', 'lat'] }))
      .toEqual({ code: 'A1', fields: ['phone'] });
  });
});

describe('configuración', () => {
  it('exige secretos', () => {
    expect(() => loadConfig({ DATABASE_URL: 'postgres://x/y' })).toThrow(/JWT_SECRET/);
    expect(() => loadConfig({ DATABASE_URL: 'postgres://x/y', JWT_SECRET: 'corto' })).toThrow();
    const cfg = loadConfig({ DATABASE_URL: 'postgres://x/y', JWT_SECRET: 'z'.repeat(40) });
    expect(cfg.dbPoolMax).toBe(12);
    expect(cfg.port).toBe(3000);
  });
});

describe('exportación y errores', () => {
  it('neutraliza fórmulas CSV y escapa comillas', () => {
    expect(csvCell('=CMD()')).toBe("'=CMD()");
    expect(csvCell('a,"b"')).toBe('"a,""b"""');
    expect(csvCell(null)).toBe('');
  });
  it('traduce errores PostgreSQL', () => {
    expect(fromPgError({ code: '23505', constraint: 'x' })?.statusCode).toBe(409);
    expect(fromPgError({ code: '23514' })?.statusCode).toBe(400);
    expect(fromPgError({ code: '57014' })?.statusCode).toBe(503);
    expect(fromPgError({})).toBeNull();
  });
});
