import { afterAll, beforeAll, describe, expect, it } from 'vitest';
import { auth, integrationEnabled, ORIGIN, setupHarness, teardown, type Harness } from './helpers.js';

/**
 * Búsqueda global unificada (/search): personas con fonética y corrección de
 * tipeo, direcciones (nombres antiguos incluidos), zonas y detección de tipo.
 * Catálogo y personas SINTÉTICOS (fuente test_fixture); los nombres no
 * representan personas ni calles reales.
 */
describe.skipIf(!integrationEnabled)('búsqueda global /search', () => {
  let h: Harness;
  beforeAll(async () => {
    h = await setupHarness();
    await h.db.query(`INSERT INTO geo.data_sources (code, name, license, attribution, is_synthetic)
      VALUES ('test_fixture', 'Fixture sintético', 'Interno', 'Datos sintéticos de prueba', true)
      ON CONFLICT (code) DO NOTHING`);
    await h.db.query(`INSERT INTO geo.municipalities (code, name, boundary, source_code) VALUES
      ('fx-buscador', 'Municipio Buscador', ST_Multi(ST_MakeEnvelope(-80.0, 22.35, -79.9, 22.45, 4326)), 'test_fixture')`);
    const muni = `(SELECT id FROM geo.municipalities WHERE code = 'fx-buscador')`;
    await h.db.query(`INSERT INTO geo.addresses (street_name, house_number, granularity, geom, municipality_id, source_code)
      SELECT s, n, CASE WHEN n IS NULL THEN 'street' ELSE 'dwelling' END,
             ST_SetSRID(ST_MakePoint(x, 22.40), 4326)::geography, ${muni}, 'test_fixture'
        FROM (VALUES ('Calle Sintética del Sol', NULL::text, -79.951), ('Calle Sintética del Sol', '45', -79.952)) v(s, n, x)`);
    await h.db.query(`INSERT INTO geo.street_aliases (alias, street_name, municipality_id)
      VALUES ('Camino Viejo del Sol', 'Calle Sintética del Sol', ${muni})`);
    await h.db.query(`INSERT INTO geo.zones (name, kind, geom, vertices, center_lat, center_lon, radius_m, data_source)
      VALUES ('Zona Sintética Buscador', 'circle',
              ST_Buffer(ST_SetSRID(ST_MakePoint(-79.95, 22.40), 4326)::geography, 500),
              '[]'::jsonb, 22.40, -79.95, 500, 'test_fixture')`);
    const post = (payload: Record<string, unknown>) =>
      h.app.inject({ method: 'POST', url: '/api/v1/persons', headers: auth(h.tokens.operator!),
        payload: { dataSource: 'pruebas automáticas', consentStatus: 'not_required', ...payload } });
    const p1 = await post({ code: 'SRC-101', givenNames: 'Judith', familyNames: 'Pena', groups: ['A'],
      phone: '+5350000001',
      location: { ...ORIGIN, coordSource: 'map_pick', precisionLevel: 'high', addressText: 'Calle Sintética del Sol 45' } });
    const p2 = await post({ code: 'SRC-102', givenNames: 'Marta', familyNames: 'Abreu', groups: ['A', 'B'] });
    const p3 = await post({ code: 'SRC-103', givenNames: 'Yudith', familyNames: 'Pena', groups: ['B'],
      phone: '+5350000002' });
    if (p1.statusCode !== 201 || p2.statusCode !== 201 || p3.statusCode !== 201) {
      throw new Error(`fixture persons: ${p1.statusCode} ${p2.statusCode} ${p3.statusCode} ${p1.body}`);
    }
  });
  afterAll(async () => teardown(h));

  const search = (q: string, extra = '') =>
    h.app.inject({ method: 'GET', url: `/api/v1/search?q=${encodeURIComponent(q)}${extra}`,
      headers: auth(h.tokens.operator!) });

  it('detecta el tipo de lo escrito automáticamente', async () => {
    expect((await search('92230102231')).json().detectado).toBe('identidad');
    expect((await search('+5350000001')).json().detectado).toBe('telefono');
    expect((await search('calle sintetica del sol 45')).json().detectado).toBe('direccion');
    expect((await search('marta')).json().detectado).toBe('texto');
  });

  it('encuentra persona por nombre (score alto), teléfono y prefijo de código', async () => {
    const nombre = (await search('marta abreu')).json();
    expect(nombre.persons[0].code).toBe('SRC-102');
    expect(nombre.persons[0].score).toBeGreaterThanOrEqual(7);

    const tel = (await search('+5350000001')).json();
    expect(tel.persons.map((p: { code: string }) => p.code)).toEqual(['SRC-101']);

    const pref = (await search('SRC-1')).json();
    expect(pref.persons.map((p: { code: string }) => p.code)).toEqual(['SRC-101', 'SRC-102', 'SRC-103']);
  });

  it('busca fonéticamente: «yudith pena» encuentra a Judith', async () => {
    const res = await search('yudith pena');
    const codes = (res.json().persons as Array<{ code: string }>).map((p) => p.code);
    expect(codes).toContain('SRC-101');
    expect(res.json().persons[0].score).toBeGreaterThanOrEqual(6.5);
  });

  it('con tipeo erróneo encuentra igualmente y sugiere «¿quisiste decir…?»', async () => {
    const res = await search('marta abrei');
    const d = res.json();
    expect(d.persons[0].code).toBe('SRC-102'); // lo encuentra por trigram
    expect(d.sugerencia).toBe('Marta Abreu');  // y sugiere la escritura correcta
  });

  it('encuentra viviendas con número y nombres antiguos de calles', async () => {
    const vivienda = (await search('calle sintetica del sol 45')).json();
    expect(vivienda.addresses[0].label).toBe('Calle Sintética del Sol 45');
    expect(vivienda.addresses[0].fuente).toBe('vivienda');
    expect(vivienda.addresses[0].lat).toBeCloseTo(22.40, 3);

    const antigua = (await search('camino viejo del sol')).json();
    expect(antigua.addresses[0].label).toBe('Calle Sintética del Sol');
    expect(antigua.addresses[0].fuente).toBe('antiguo');
  });

  it('incluye zonas en el resultado para roles con zones.read', async () => {
    const admin = await h.app.inject({ method: 'GET',
      url: '/api/v1/search?q=Zona%20Sintetica%20Buscador', headers: auth(h.tokens.admin!) });
    expect(admin.json().zones[0]?.name).toBe('Zona Sintética Buscador');
    const oper = (await search('Zona Sintetica Buscador')).json();
    expect(oper.zones[0]?.lat).toBeCloseTo(22.40, 3);
  });

  it('aplica visibilidad por grupos y filtros', async () => {
    const solo = (await search('pena', '&filtro=con_telefono')).json();
    expect(solo.persons.map((p: { code: string }) => p.code)).toEqual(['SRC-101', 'SRC-103']);

    const ro = await h.app.inject({ method: 'GET', url: '/api/v1/search?q=pena',
      headers: auth(h.tokens.readonly!) });
    expect(ro.json().persons.map((p: { code: string }) => p.code)).toEqual(['SRC-101']); // B oculto
  });

  it('limita resultados y rechaza consultas demasiado cortas', async () => {
    const res = await search('pena', '&limit=1');
    expect(res.json().persons).toHaveLength(1);
    expect(res.json().addresses.length).toBeLessThanOrEqual(1);
    const corta = await search('p');
    expect(corta.statusCode).toBe(400);
  });
});
