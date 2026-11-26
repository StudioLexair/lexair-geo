import { afterAll, beforeAll, describe, expect, it } from 'vitest';
import { auth, integrationEnabled, ORIGIN, setupHarness, teardown, type Harness } from './helpers.js';

/** CRUD del personal de la fuerza (militares) con residencia y búsqueda. */
describe.skipIf(!integrationEnabled)('personal de la fuerza', () => {
  let h: Harness;
  let operator = '';
  beforeAll(async () => {
    h = await setupHarness();
    operator = h.tokens.operator!;
  });
  afterAll(async () => teardown(h));

  const post = (token: string, url: string, payload?: Record<string, unknown>) =>
    h.app.inject({ method: 'POST', url, headers: auth(token), payload });
  const get = (token: string, url: string) =>
    h.app.inject({ method: 'GET', url, headers: auth(token) });

  let firstId = '';

  it('crea personal con grado, unidad y teléfonos', async () => {
    const res = await post(operator, '/api/v1/personnel', {
      code: 'PERS-01', fullName: 'Mayor General de Prueba', rank: 'Mayor', unit: 'UM-23',
      phone: '+53 5300-0001', phoneAlt: '43-0770', addressText: 'Calle sintética #1',
    });
    expect(res.statusCode).toBe(201);
    firstId = res.json().id;
    expect(res.json().phone).toBe('+53 5300-0001');
    expect(res.json().location).toBeNull();
  });

  it('rechaza duplicar el código o teléfonos mal formados', async () => {
    const dup = await post(operator, '/api/v1/personnel', { code: 'PERS-01', fullName: 'Otro de Prueba' });
    expect(dup.statusCode).toBe(400);
    const bad = await post(operator, '/api/v1/personnel', { fullName: 'Teléfono Malo', phone: 'no-tiene-números' });
    expect(bad.statusCode).toBe(400);
  });

  it('exige al menos un dato de contexto (grado, unidad o dirección)', async () => {
    const res = await post(operator, '/api/v1/personnel', { fullName: 'Nada de Nada' });
    expect(res.statusCode).toBe(400);
  });

  it('registra la residencia y deduce el municipio si hay catálogo', async () => {
    const res = await h.app.inject({ method: 'PUT', url: `/api/v1/personnel/${firstId}/location`,
      headers: auth(operator), payload: { lat: ORIGIN.lat, lon: ORIGIN.lon } });
    expect(res.statusCode).toBe(200);
    expect(res.json().location.lat).toBeCloseTo(ORIGIN.lat, 6);
  });

  it('busca por nombre normalizado (sin tildes) y por teléfono', async () => {
    await post(operator, '/api/v1/personnel', {
      fullName: 'Coronel Árbol Sintético', rank: 'Coronel', phone: '+53 5400-1234' });
    const name = await get(operator, '/api/v1/personnel?q=arbol');
    expect((name.json().items as Array<{ fullName: string }>).map((p) => p.fullName))
      .toContain('Coronel Árbol Sintético');
    const phone = await get(operator, '/api/v1/personnel?q=5400');
    expect((phone.json().items as Array<{ fullName: string }>).map((p) => p.fullName))
      .toContain('Coronel Árbol Sintético');
  });

  it('consulta personal cercano a un punto del mapa', async () => {
    const res = await get(operator,
      `/api/v1/personnel/near?lat=${ORIGIN.lat + 0.002}&lon=${ORIGIN.lon}&radius=2000`);
    expect(res.statusCode).toBe(200);
    const items = res.json().items as Array<{ fullName: string }>;
    expect(items.map((p) => p.fullName)).toContain('Mayor General de Prueba');
  });

  it('un consultor lee la ficha completa pero no puede editarla', async () => {
    const read = await get(h.tokens.consultant!, `/api/v1/personnel/${firstId}`);
    expect(read.statusCode).toBe(200);
    expect(read.json().phone).toBe('+53 5300-0001');
    const edit = await h.app.inject({ method: 'PATCH', url: `/api/v1/personnel/${firstId}`,
      headers: auth(h.tokens.consultant!), payload: { rank: 'General' } });
    expect(edit.statusCode).toBe(403);
  });

  it('edita, desactiva y elimina', async () => {
    const patch = await h.app.inject({ method: 'PATCH', url: `/api/v1/personnel/${firstId}`,
      headers: auth(operator), payload: { rank: 'General', isActive: false } });
    expect(patch.json().rank).toBe('General');
    expect(patch.json().isActive).toBe(false);
    const list = await get(operator, '/api/v1/personnel?status=active');
    expect((list.json().items as Array<{ id: string }>).map((p) => p.id)).not.toContain(firstId);
    const del = await h.app.inject({ method: 'DELETE', url: `/api/v1/personnel/${firstId}`, headers: auth(operator) });
    expect(del.statusCode).toBe(200);
    const gone = await get(operator, `/api/v1/personnel/${firstId}`);
    expect(gone.statusCode).toBe(404);
  });
});
