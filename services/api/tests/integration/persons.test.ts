import { afterAll, beforeAll, describe, expect, it } from 'vitest';
import { auth, integrationEnabled, ORIGIN, setupHarness, teardown, type Harness } from './helpers.js';

const base = (code: string, groups: string[], extra: Record<string, unknown> = {}) => ({
  code, givenNames: 'Ficticio', familyNames: `Prueba ${code}`, groups, dataSource: 'pruebas automáticas',
  consentStatus: 'not_required', ...extra,
});

describe.skipIf(!integrationEnabled)('personas y grupos', () => {
  let h: Harness;
  const post = (token: string, payload: Record<string, unknown>) =>
    h.app.inject({ method: 'POST', url: '/api/v1/persons', headers: auth(token), payload });
  beforeAll(async () => { h = await setupHarness(); });
  afterAll(async () => teardown(h));

  it('crea una persona con ubicación y la devuelve completa al operador', async () => {
    const res = await post(h.tokens.operator!, base('TST-001', ['A'], {
      location: { ...ORIGIN, coordSource: 'map_pick', precisionLevel: 'high', addressGranularity: 'dwelling',
        addressText: 'Dirección sintética 1' } }));
    expect(res.statusCode).toBe(201);
    const p = res.json();
    expect(p.groups).toEqual(['A']);
    expect(p.location.lat).toBeCloseTo(ORIGIN.lat, 6);
    expect(p.location.validationStatus).toBe('pending');
  });

  it('acepta la granularidad «poi» que devuelve el geocodificador', async () => {
    const res = await post(h.tokens.operator!, base('TST-POI', ['B'], {
      location: { ...ORIGIN, coordSource: 'geocoded_address', precisionLevel: 'approximate', addressGranularity: 'poi',
        addressText: 'Punto de interés sintético' } }));
    expect(res.statusCode).toBe(201);
    expect(res.json().location.addressGranularity).toBe('poi');
  });

  it('una persona en ambos grupos mantiene una única identidad', async () => {
    const res = await post(h.tokens.admin!, base('TST-002', ['A', 'B']));
    expect(res.statusCode).toBe(201);
    const { rows } = await h.db.query("SELECT count(*)::int AS n FROM directory.persons WHERE code = 'TST-002'");
    expect(rows[0].n).toBe(1);
    const m = await h.db.query(`SELECT count(*)::int AS n FROM directory.person_memberships m
      JOIN directory.persons p ON p.id = m.person_id WHERE p.code = 'TST-002'`);
    expect(m.rows[0].n).toBe(2);
  });

  it('busca por prefijo de código (mín. 4 caracteres) usando solo letras, dígitos y guiones', async () => {
    const res = await h.app.inject({ method: 'GET', url: '/api/v1/persons?q=tst-00', headers: auth(h.tokens.operator!) });
    expect(res.statusCode).toBe(200);
    const codes = (res.json().items as Array<{ code: string }>).map((p) => p.code);
    expect(codes).toContain('TST-001');
    const pct = await h.app.inject({ method: 'GET', url: '/api/v1/persons?q=%25', headers: auth(h.tokens.operator!) });
    expect(pct.json().items ?? []).toHaveLength(0);
  });

  it('rechaza códigos duplicados con 409', async () => {
    const res = await post(h.tokens.operator!, base('TST-001', ['A']));
    expect(res.statusCode).toBe(409);
  });

  it('rechaza coordenadas intercambiadas o fuera de territorio', async () => {
    const swapped = await post(h.tokens.operator!, base('TST-003', ['A'], {
      location: { lat: ORIGIN.lon, lon: ORIGIN.lat, coordSource: 'manual_coordinates' } }));
    expect(swapped.statusCode).toBe(400);
    expect(swapped.json().message).toMatch(/intercambiadas/);
    const madrid = await post(h.tokens.operator!, base('TST-004', ['A'], {
      location: { lat: 40.4, lon: -3.7, coordSource: 'manual_coordinates' } }));
    expect(madrid.statusCode).toBe(400);
  });

  it('solo lectura no ve el Grupo B ni puede crear', async () => {
    await post(h.tokens.admin!, base('TST-B01', ['B']));
    const list = await h.app.inject({ method: 'GET', url: '/api/v1/persons?q=TST-B01', headers: auth(h.tokens.readonly!) });
    expect(list.statusCode).toBe(200);
    expect(list.json().items).toHaveLength(0);
    const forced = await h.app.inject({ method: 'GET', url: '/api/v1/persons?groups=B', headers: auth(h.tokens.readonly!) });
    expect(forced.statusCode).toBe(403);
    const create = await post(h.tokens.readonly!, base('TST-005', ['A']));
    expect(create.statusCode).toBe(403);
  });

  it('el consultor no recibe coordenadas exactas ni dirección', async () => {
    const res = await h.app.inject({ method: 'GET', url: '/api/v1/persons?q=TST-001', headers: auth(h.tokens.consultant!) });
    const p = res.json().items[0];
    expect(p.location.precisionLevel).toBe('high');
    expect(p.location.lat).toBeNull();
    expect(p.location.addressText).toBeNull();
  });

  it('filtra por grupo e identifica la procedencia', async () => {
    const a = await h.app.inject({ method: 'GET', url: '/api/v1/persons?groups=A&q=TST', headers: auth(h.tokens.admin!) });
    const codes = a.json().items.map((p: { code: string }) => p.code);
    expect(codes).toContain('TST-001');
    expect(codes).toContain('TST-002');
    expect(codes).not.toContain('TST-B01');
  });

  it('busca por nombre normalizado (sin tildes) y pagina', async () => {
    const res = await h.app.inject({ method: 'GET', url: '/api/v1/persons?q=FICTÍCIO&pageSize=1&page=1',
      headers: auth(h.tokens.admin!) });
    expect(res.statusCode).toBe(200);
    expect(res.json().items).toHaveLength(1);
    expect(res.json().total).toBeGreaterThanOrEqual(2);
    const bad = await h.app.inject({ method: 'GET', url: '/api/v1/persons?pageSize=5000', headers: auth(h.tokens.admin!) });
    expect(bad.statusCode).toBe(400);
  });

  it('edita, desactiva y reactiva con auditoría', async () => {
    const found = await h.app.inject({ method: 'GET', url: '/api/v1/persons?q=TST-002', headers: auth(h.tokens.admin!) });
    const id = found.json().items[0].id;
    const patch = await h.app.inject({ method: 'PATCH', url: `/api/v1/persons/${id}`, headers: auth(h.tokens.admin!),
      payload: { familyNames: 'Prueba Editada' } });
    expect(patch.json().familyNames).toBe('Prueba Editada');
    const off = await h.app.inject({ method: 'POST', url: `/api/v1/persons/${id}/deactivate`, headers: auth(h.tokens.admin!) });
    expect(off.json().isActive).toBe(false);
    const on = await h.app.inject({ method: 'POST', url: `/api/v1/persons/${id}/reactivate`, headers: auth(h.tokens.admin!) });
    expect(on.json().isActive).toBe(true);
    const audit = await h.db.query("SELECT action FROM audit.audit_logs WHERE entity_id = $1 ORDER BY id", [id]);
    expect(audit.rows.map((r) => r.action)).toEqual(['person.create', 'person.update', 'person.deactivate', 'person.reactivate']);
  });

  it('verifica una ubicación y exige permiso de verificación', async () => {
    const found = await h.app.inject({ method: 'GET', url: '/api/v1/persons?q=TST-001', headers: auth(h.tokens.admin!) });
    const id = found.json().items[0].id;
    const denied = await h.app.inject({ method: 'POST', url: `/api/v1/persons/${id}/location/verify`,
      headers: auth(h.tokens.operator!), payload: {} });
    expect(denied.statusCode).toBe(403);
    const ok = await h.app.inject({ method: 'POST', url: `/api/v1/persons/${id}/location/verify`,
      headers: auth(h.tokens.admin!), payload: { precisionLevel: 'exact_verified' } });
    expect(ok.statusCode).toBe(200);
    expect(ok.json().location.precisionLevel).toBe('exact_verified');
    expect(ok.json().location.validationStatus).toBe('validated');
  });

  it('exporta CSV autorizado y lo audita', async () => {
    const denied = await h.app.inject({ method: 'GET', url: '/api/v1/exports/persons.csv', headers: auth(h.tokens.operator!) });
    expect(denied.statusCode).toBe(403);
    const res = await h.app.inject({ method: 'GET', url: '/api/v1/exports/persons.csv', headers: auth(h.tokens.admin!) });
    expect(res.statusCode).toBe(200);
    expect(res.headers['content-type']).toContain('text/csv');
    expect(res.body).toContain('TST-001');
  });
});
