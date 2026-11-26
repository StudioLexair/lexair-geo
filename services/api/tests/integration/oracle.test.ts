import { afterAll, beforeAll, describe, expect, it } from 'vitest';
import { auth, integrationEnabled, setupHarness, teardown, type Harness } from './helpers.js';
import { decryptSecret, deriveKey, encryptSecret } from '../../src/modules/oracle/crypto.js';

/**
 * Conectores Oracle 11g: CRUD, cifrado de contraseña y manejo de errores sin
 * driver/biblioteca. La sincronización real se ejecuta en el servidor con
 * acceso a la base Oracle; aquí se prueba que la integración falla de forma
 * controlada y deja la bitácora consistente.
 */
describe.skipIf(!integrationEnabled)('conectores Oracle', () => {
  let h: Harness;
  let admin = '';
  beforeAll(async () => {
    h = await setupHarness();
    admin = h.tokens.admin!;
  });
  afterAll(async () => teardown(h));

  const post = (token: string, url: string, payload?: Record<string, unknown>) =>
    h.app.inject({ method: 'POST', url, headers: auth(token), payload });

  let connectorId = '';

  it('cifra y descifra la contraseña con clave derivada (AES-256-GCM)', () => {
    const key = deriveKey('secreto-de-servidor-con-32-caracteres-min');
    const stored = encryptSecret('Clave-Oracle-2026!', key);
    expect(stored.startsWith('v1:')).toBe(true);
    expect(stored).not.toContain('Clave');
    expect(decryptSecret(stored, key)).toBe('Clave-Oracle-2026!');
    expect(() => decryptSecret(stored, deriveKey('otra-clave-distinta-de-32-caracteres!!!')))
      .toThrow();
  });

  it('crea un conector con mappings configurables y nunca devuelve la contraseña', async () => {
    const res = await post(admin, '/api/v1/oracle/connectors', {
      name: 'Oracle 11g central', host: '10.0.0.5', port: 1521, serviceKind: 'sid',
      serviceName: 'ORCL', username: 'minint_ro', password: 'Clave-Segura-2026',
      thickMode: true,
      mappings: [
        { type: 'persons', sourceTable: 'RH.PRESOS_V', keyColumn: 'EXPEDIENTE',
          columns: { givenNames: 'NOMBRE', familyNames: 'APELLIDOS', phone: 'TELEFONO' },
          latColumn: 'LATITUD', lonColumn: 'LONGITUD', codePrefix: 'OR-', groups: ['A'] },
        { type: 'personnel', sourceTable: 'MILITARES', keyColumn: 'CARNET',
          columns: { fullName: 'NOMBRE_COMPLETO', rank: 'GRADO', phone: 'TEL' } },
      ],
    });
    expect(res.statusCode).toBe(201);
    connectorId = res.json().id;
    expect(res.json().mappings).toHaveLength(2);
    expect(JSON.stringify(res.json())).not.toContain('Clave-Segura');
    const { rows } = await h.db.query<{ password_cipher: string }>(
      'SELECT password_cipher FROM directory.oracle_connectors WHERE id = $1', [connectorId]);
    expect(rows[0]!.password_cipher).not.toContain('Clave');
  });

  it('rechaza mappings con identificadores Oracle peligrosos', async () => {
    const res = await post(admin, '/api/v1/oracle/connectors', {
      name: 'Inyección', host: '10.0.0.5', username: 'u', password: 'x',
      mappings: [{ type: 'persons', sourceTable: 'TABLA; DROP TABLE x', keyColumn: 'ID',
        columns: { givenNames: 'N' } }],
    });
    expect(res.statusCode).toBe(400);
  });

  it('probar conexión sin driver instalado devuelve error controlado', async () => {
    const res = await post(admin, `/api/v1/oracle/connectors/${connectorId}/test`);
    expect([502, 503]).toContain(res.statusCode);
    expect(['ORACLE_DRIVER_MISSING', 'ORACLE_CLIENT_MISSING', 'ORACLE_ERROR', 'ORACLE_PROTOCOL'])
      .toContain(res.json().error);
  });

  it('corrida fallida queda registrada en la bitácora con estado error', async () => {
    const res = await post(admin, `/api/v1/oracle/connectors/${connectorId}/run`, { dryRun: false });
    expect([502, 503]).toContain(res.statusCode);
    const runs = await h.app.inject({ method: 'GET', url: `/api/v1/oracle/runs?connectorId=${connectorId}`,
      headers: auth(admin) });
    const items = runs.json().items as Array<{ status: string; errorText: string | null }>;
    expect(items.length).toBeGreaterThanOrEqual(1);
    expect(items[0]!.status).toBe('error');
    expect(items[0]!.errorText).toBeTruthy();
    const conn = await h.app.inject({ method: 'GET', url: '/api/v1/oracle/connectors', headers: auth(admin) });
    expect(conn.json().items[0]!.lastStatus).toBe('error');
  });

  it('la edición no exige la contraseña y acepta mappings nuevos', async () => {
    const patch = await h.app.inject({ method: 'PATCH', url: `/api/v1/oracle/connectors/${connectorId}`,
      headers: auth(admin), payload: { mappings: [
        { type: 'inmates', sourceTable: 'PENAL_INTERNOS', keyColumn: 'ID',
          columns: { personCode: 'CODIGO_PERSONA', internCode: 'EXPEDIENTE', facility: 'PENAL' } },
      ] } });
    expect(patch.statusCode).toBe(200);
    const list = await h.app.inject({ method: 'GET', url: '/api/v1/oracle/connectors', headers: auth(admin) });
    expect(list.json().items[0]!.mappings[0]!.type).toBe('inmates');
  });

  it('un operador sin permiso oracle.sync no administra conectores', async () => {
    const res = await h.app.inject({ method: 'GET', url: '/api/v1/oracle/connectors',
      headers: auth(h.tokens.operator!) });
    expect(res.statusCode).toBe(403);
  });

  it('elimina el conector y la bitácora en cascada', async () => {
    const del = await h.app.inject({ method: 'DELETE', url: `/api/v1/oracle/connectors/${connectorId}`,
      headers: auth(admin) });
    expect(del.statusCode).toBe(200);
    const runs = await h.app.inject({ method: 'GET', url: `/api/v1/oracle/runs?connectorId=${connectorId}`,
      headers: auth(admin) });
    expect(runs.json().items).toHaveLength(0);
  });
});
