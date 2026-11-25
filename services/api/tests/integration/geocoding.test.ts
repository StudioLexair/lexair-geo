import { afterAll, beforeAll, describe, expect, it } from 'vitest';
import { auth, integrationEnabled, setupHarness, teardown, type Harness } from './helpers.js';

/**
 * Catálogo de direcciones SINTÉTICO (fuente test_fixture, is_synthetic = true).
 * Los nombres y posiciones no representan calles reales de Villa Clara.
 */
describe.skipIf(!integrationEnabled)('geocodificación local', () => {
  let h: Harness;
  beforeAll(async () => {
    h = await setupHarness();
    await h.db.query(`INSERT INTO geo.data_sources (code, name, license, attribution, is_synthetic)
      VALUES ('test_fixture', 'Fixture sintético', 'Interno', 'Datos sintéticos de prueba', true)
      ON CONFLICT (code) DO NOTHING`);
    await h.db.query(`INSERT INTO geo.municipalities (code, name, boundary, source_code) VALUES
      ('fx-norte', 'Municipio Ficticio Norte', ST_Multi(ST_MakeEnvelope(-80.0, 22.35, -79.9, 22.45, 4326)), 'test_fixture')`);
    await h.db.query(`INSERT INTO geo.localities (municipality_id, name, kind, centroid, source_code)
      SELECT id, 'Reparto Ficticio Alameda', 'reparto', ST_SetSRID(ST_MakePoint(-79.95, 22.40), 4326)::geography, 'test_fixture'
        FROM geo.municipalities WHERE code = 'fx-norte'`);
    await h.db.query(`INSERT INTO geo.addresses (street_name, house_number, granularity, geom, municipality_id, source_code)
      SELECT s, n, CASE WHEN n IS NULL THEN 'street' ELSE 'dwelling' END,
             ST_SetSRID(ST_MakePoint(x, 22.40), 4326)::geography, (SELECT id FROM geo.municipalities WHERE code = 'fx-norte'),
             'test_fixture'
        FROM (VALUES ('Calle Ficticia Gardenia', NULL, -79.951), ('Calle Ficticia Gardenia', '45', -79.952),
                     ('Avenida Sintética Central', NULL, -79.949)) v(s, n, x)`);
    await h.db.query(`INSERT INTO geo.street_aliases (alias, street_name) VALUES ('La Gardenia', 'Calle Ficticia Gardenia')`);
  });
  afterAll(async () => teardown(h));

  const search = (q: string) => h.app.inject({ method: 'GET', url: `/api/v1/geocoding/search?q=${encodeURIComponent(q)}`,
    headers: auth(h.tokens.operator!) });

  it('encuentra una vivienda con número exacto y confianza alta', async () => {
    const res = await search('calle ficticia gardenia #45');
    const top = res.json().items[0];
    expect(top.granularity).toBe('dwelling');
    expect(top.suggestedPrecision).toBe('high');
    expect(top.isSynthetic).toBe(true);
  });

  it('número inexistente: devuelve la calle e indica que no es la vivienda', async () => {
    const res = await search('Calle Ficticia Gardenia 999');
    const top = res.json().items[0];
    expect(top.granularity).toBe('street');
    expect(top.note).toMatch(/no la vivienda/);
  });

  it('tolera tildes y errores leves', async () => {
    const res = await search('avenida sintetica centrall');
    expect(res.json().items[0].label).toBe('Avenida Sintética Central');
  });

  it('resuelve alias de calle', async () => {
    const res = await search('la gardenia');
    expect(res.json().items.some((i: { label: string }) => i.label.includes('Gardenia'))).toBe(true);
  });

  it('encuentra localidades (repartos)', async () => {
    const res = await search('reparto ficticio alameda');
    expect(res.json().items[0].kind).toBe('locality');
    expect(res.json().items[0].suggestedPrecision).toBe('general_area');
  });

  it('sin coincidencias no inventa coordenadas', async () => {
    const res = await search('zzqxw inexistente');
    expect(res.json().found).toBe(false);
    expect(res.json().items).toEqual([]);
  });

  it('geocodificación inversa devuelve municipio por límite', async () => {
    const res = await h.app.inject({ method: 'GET', url: '/api/v1/geocoding/reverse?lat=22.4&lon=-79.95',
      headers: auth(h.tokens.operator!) });
    expect(res.json().municipality.name).toBe('Municipio Ficticio Norte');
    expect(res.json().nearestAddress).not.toBeNull();
  });

  it('una ubicación sin municipio lo deduce del límite', async () => {
    const res = await h.app.inject({ method: 'POST', url: '/api/v1/persons', headers: auth(h.tokens.operator!), payload: {
      code: 'GEO-001', givenNames: 'Ficticio', familyNames: 'Geo', groups: ['A'], dataSource: 'pruebas',
      location: { lat: 22.41, lon: -79.95, coordSource: 'map_pick' } } });
    expect(res.json().location.municipality).toBe('Municipio Ficticio Norte');
  });
  it('lista solo direcciones administradas localmente y exige geocoding.manage', async () => {
    const created = await h.app.inject({ method: 'POST', url: '/api/v1/geocoding/addresses',
      headers: auth(h.tokens.admin!), payload: { streetName: 'Calle Ficticia Local', houseNumber: '7', lat: 22.401, lon: -79.951 } });
    expect(created.statusCode).toBe(201);
    const list = await h.app.inject({ method: 'GET', url: '/api/v1/geocoding/addresses', headers: auth(h.tokens.admin!) });
    expect(list.statusCode).toBe(200);
    const names = list.json().items.map((i: { streetName: string }) => i.streetName);
    expect(names).toContain('Calle Ficticia Local');
    expect(names).not.toContain('Calle Ficticia Gardenia');
    const denied = await h.app.inject({ method: 'GET', url: '/api/v1/geocoding/addresses', headers: auth(h.tokens.operator!) });
    expect(denied.statusCode).toBe(403);
  });
});
