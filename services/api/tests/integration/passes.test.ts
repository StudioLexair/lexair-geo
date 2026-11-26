import { afterAll, beforeAll, describe, expect, it } from 'vitest';
import { auth, integrationEnabled, ORIGIN, setupHarness, teardown, type Harness } from './helpers.js';

/**
 * Internos (ficha), pases con estado calculado, marcadores del mapa y
 * personal de la fuerza cercano a un preso.
 */
describe.skipIf(!integrationEnabled)('internos y pases', () => {
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

  let personId = '';

  beforeAll(async () => {
    const res = await post(operator, '/api/v1/persons', {
      code: 'PAS-100', givenNames: 'Reo', familyNames: 'De Prueba', groups: ['B'],
      dataSource: 'pruebas', consentStatus: 'not_required',
      location: { ...ORIGIN, coordSource: 'map_pick', precisionLevel: 'high', addressGranularity: 'dwelling' },
    });
    personId = res.json().id;
  });

  it('los tipos de pase del catálogo son configurables', async () => {
    const res = await get(operator, '/api/v1/passes/types');
    expect(res.statusCode).toBe(200);
    const items = res.json().items as Array<{ code: string }>;
    expect(items.map((t) => t.code)).toContain('pase_ordinario');
    const unique = `pase_medico_${Date.now()}`;
    const created = await post(operator, '/api/v1/passes/types', {
      code: unique, name: 'Pase médico', defaultDays: 2, colorHex: '#2E7D32' });
    expect(created.statusCode).toBe(201);
    const dup = await post(operator, '/api/v1/passes/types', {
      code: unique, name: 'Duplicado' });
    expect(dup.statusCode).toBe(409);
  });

  it('exige registrar la ficha de interno antes de conceder un pase', async () => {
    const res = await post(operator, '/api/v1/passes', {
      personId, startsAt: new Date().toISOString(),
      endsAt: new Date(Date.now() + 86_400_000).toISOString(),
    });
    expect(res.statusCode).toBe(400);
    expect(res.json().message).toMatch(/interno/i);
  });

  it('registra la ficha de interno y concede el pase', async () => {
    const inmate = await post(operator, `/api/v1/persons/${personId}/inmate`, {
      internCode: 'PAS-INT-100', facility: 'Penal Central de Prueba', status: 'En pase', riskLevel: 'Medio' });
    expect(inmate.statusCode).toBe(201);
    const pass = await post(operator, '/api/v1/passes', {
      personId, passTypeId: null, facility: 'Penal Central de Prueba',
      startsAt: new Date(Date.now() - 3_600_000).toISOString(),
      endsAt: new Date(Date.now() + 6 * 86_400_000).toISOString(),
    });
    expect(pass.statusCode).toBe(201);
    const detail = await get(operator, `/api/v1/persons/${personId}/passes`);
    expect(detail.json().inmate!.internCode).toBe('PAS-INT-100');
    expect(detail.json().passes).toHaveLength(1);
    expect(detail.json().passes[0]!.state).toBe('active');
  });

  it('respeta el máximo de pases activos por interno (configurable)', async () => {
    const res = await post(operator, '/api/v1/passes', {
      personId, startsAt: new Date().toISOString(),
      endsAt: new Date(Date.now() + 86_400_000).toISOString(),
    });
    expect(res.statusCode).toBe(409);
    expect(res.json().message).toMatch(/activo/i);
  });

  it('el listado por estado y el filtro de personas en pase funcionan', async () => {
    const active = await get(operator, '/api/v1/passes?state=active');
    expect((active.json().items as Array<{ personId: string }>).some((p) => p.personId === personId)).toBe(true);
    const onPass = await get(operator, '/api/v1/persons?onPass=true');
    expect((onPass.json().items as Array<{ id: string }>).map((p) => p.id)).toContain(personId);
    const off = await get(operator, '/api/v1/persons?onPass=false');
    expect((off.json().items as Array<{ id: string }>).map((p) => p.id)).not.toContain(personId);
  });

  it('los marcadores del mapa entregan coordenadas solo con permiso exacto', async () => {
    const bbox = `${ORIGIN.lon - 0.05},${ORIGIN.lat - 0.05},${ORIGIN.lon + 0.05},${ORIGIN.lat + 0.05}`;
    const asOperator = await get(operator, `/api/v1/passes/map?bbox=${bbox}`);
    expect(asOperator.json().mode).toBe('points');
    const marker = (asOperator.json().items as Array<{ personId: string }>).find((m) => m.personId === personId);
    expect(marker).toBeDefined();
    // readonly no tiene locations.exact.read: el API oculta las coordenadas.
    const asReadonly = await get(h.tokens.readonly!, `/api/v1/passes/map?bbox=${bbox}`);
    expect(asReadonly.statusCode).toBe(403); // sin groups.b.read para el grupo B
    // El consultor ve el mapa de pases pero SIN coordenadas exactas: solo recuento.
    const asConsultant = await get(h.tokens.consultant!, `/api/v1/passes/map?bbox=${bbox}`);
    expect(asConsultant.json().mode).toBe('hidden');
    expect(asConsultant.json().count).toBeGreaterThanOrEqual(1);
  });

  it('el personal que vive cerca del preso se ordena por distancia', async () => {
    const near = await post(operator, '/api/v1/personnel', {
      fullName: 'Teniente Cercano', rank: 'Teniente', phone: '+53 5111-1111' });
    const nearId = near.json().id as string;
    const far = await post(operator, '/api/v1/personnel', {
      fullName: 'Sargento Lejano', rank: 'Sargento', phone: '+53 5222-2222' });
    const farId = far.json().id as string;
    // ~111 m al norte; el lejano a ~11 km al sur.
    await h.app.inject({ method: 'PUT', url: `/api/v1/personnel/${nearId}/location`,
      headers: auth(operator), payload: { lat: ORIGIN.lat + 0.001, lon: ORIGIN.lon } });
    await h.app.inject({ method: 'PUT', url: `/api/v1/personnel/${farId}/location`,
      headers: auth(operator), payload: { lat: ORIGIN.lat - 0.1, lon: ORIGIN.lon } });
    const res = await get(operator, `/api/v1/persons/${personId}/nearby-personnel?radius=5000`);
    expect(res.statusCode).toBe(200);
    const items = res.json().items as Array<{ id: string; distanceM: number; phone: string }>;
    const ids = items.map((p) => p.id);
    expect(ids).toContain(nearId);
    expect(ids).not.toContain(farId);
    expect(items[0]!.distanceM).toBeLessThanOrEqual(5000);
    expect(items[0]!.phone).toContain('5111');
  });

  it('devolver y cancelar cerrar el pase y liberar el cupo', async () => {
    const activeList = await get(operator, '/api/v1/passes?state=active');
    const firstActive = (activeList.json().items as Array<{ id: string }>)[0]!;
    const ret = await post(operator, `/api/v1/passes/${firstActive.id}/return`, {});
    expect(ret.statusCode).toBe(200);
    const again = await post(operator, '/api/v1/passes', {
      personId, startsAt: new Date().toISOString(),
      endsAt: new Date(Date.now() + 86_400_000).toISOString(),
    });
    expect(again.statusCode).toBe(201);
    const cancel = await post(operator, `/api/v1/passes/${again.json().id}/cancel`);
    expect(cancel.statusCode).toBe(200);
    const list = await get(operator, `/api/v1/passes?state=active&personId=${personId}`);
    expect(list.json().items).toHaveLength(0);
  });

  it('un pase ya cerrado no se reabre ni modifica', async () => {
    const pass = await post(operator, '/api/v1/passes', {
      personId, startsAt: new Date().toISOString(),
      endsAt: new Date(Date.now() + 86_400_000).toISOString(),
    });
    const id = pass.json().id as string;
    await post(operator, `/api/v1/passes/${id}/cancel`);
    const patch = await h.app.inject({ method: 'PATCH', url: `/api/v1/passes/${id}`,
      headers: auth(operator), payload: { notes: 'cambio' } });
    expect(patch.statusCode).toBe(400);
  });

  it('un consultor puede leer pases pero no crearlos', async () => {
    const read = await get(h.tokens.consultant!, '/api/v1/passes?state=all');
    expect(read.statusCode).toBe(200);
    const write = await post(h.tokens.consultant!, '/api/v1/passes', { personId });
    expect(write.statusCode).toBe(403);
  });
});
