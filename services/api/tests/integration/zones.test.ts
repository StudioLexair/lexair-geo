import { afterAll, beforeAll, describe, expect, it } from 'vitest';
import { auth, integrationEnabled, ORIGIN, setupHarness, teardown, type Harness } from './helpers.js';

/**
 * Zonas dibujadas en el mapa (círculo, rectángulo, polígono), pertenencia de
 * personas por geometría y manual, y personal/pases asociados a un área.
 */

const circle = (radiusM: number, dLat = 0, dLon = 0) => ({
  kind: 'circle', lat: ORIGIN.lat + dLat, lon: ORIGIN.lon + dLon, radiusM,
});
const rectangle = (dLat = 0.002, dLon = 0.002) => ({
  kind: 'rectangle', south: ORIGIN.lat - dLat, north: ORIGIN.lat + dLat,
  west: ORIGIN.lon - dLon, east: ORIGIN.lon + dLon,
});
const polygonAround = (dLat = 0.003, dLon = 0.003) => ({
  kind: 'polygon',
  vertices: [
    { lat: ORIGIN.lat - dLat, lon: ORIGIN.lon - dLon },
    { lat: ORIGIN.lat - dLat, lon: ORIGIN.lon + dLon },
    { lat: ORIGIN.lat + dLat, lon: ORIGIN.lon },
  ],
});

describe.skipIf(!integrationEnabled)('zonas dibujadas', () => {
  let h: Harness;
  beforeAll(async () => { h = await setupHarness(); });
  afterAll(async () => teardown(h));

  const post = (token: string, url: string, payload?: Record<string, unknown>) =>
    h.app.inject({ method: 'POST', url, headers: auth(token), payload });
  const get = (token: string, url: string) =>
    h.app.inject({ method: 'GET', url, headers: auth(token) });

  let operator = '';
  let zoneId = '';

  beforeAll(async () => { operator = h.tokens.operator!; });

  it('crea una zona circular con centro, radio y etiqueta', async () => {
    const res = await post(operator, '/api/v1/zones', {
      name: 'Residencia autorizada A', kind: 'irrelevant', geometry: circle(800),
      labelText: 'Zona del interno TST-001', categoryId: 1,
    });
    expect(res.statusCode).toBe(201);
    const z = res.json();
    zoneId = z.id;
    expect(z.kind).toBe('circle');
    expect(z.radiusM).toBe(800);
    expect(z.center.lat).toBeCloseTo(ORIGIN.lat, 6);
    expect(z.label).toBe('Zona del interno TST-001');
    expect(z.areaKm2).toBeGreaterThan(1.5);
    const { rows } = await h.db.query(
      'SELECT ST_GeometryType(geom::geometry) AS t, ST_NumGeometries(geom::geometry) AS n FROM geo.zones WHERE id = $1',
      [zoneId]);
    expect(rows[0].t).toBe('ST_Polygon');
  });

  it('crea un rectángulo y un polígono y los devuelve con sus vértices', async () => {
    const r = await post(operator, '/api/v1/zones', { name: 'Rectángulo de vigilancia', geometry: rectangle() });
    expect(r.statusCode).toBe(201);
    expect(r.json().vertices).toHaveLength(4);
    const p = await post(operator, '/api/v1/zones', { name: 'Polígono de control', geometry: polygonAround() });
    expect(p.statusCode).toBe(201);
    expect(p.json().vertices).toHaveLength(3);
    const db = await h.db.query(
      'SELECT ST_IsClosed(ST_ExteriorRing(geom::geometry)) AS closed FROM geo.zones WHERE id = $1',
      [p.json().id]);
    expect(db.rows[0].closed).toBe(true);
  });

  it('rechaza un círculo por encima del radio máximo configurado', async () => {
    // La configuración se cambia por el API (el servicio cachea 30 s).
    const set = await h.app.inject({ method: 'PUT', url: '/api/v1/admin/settings/zones.max_radius_m',
      headers: auth(h.tokens.admin!), payload: { value: 1000 } });
    expect(set.statusCode).toBe(200);
    try {
      const res = await post(operator, '/api/v1/zones', { name: 'Inmenso', geometry: circle(5000) });
      expect(res.statusCode).toBe(400);
    } finally {
      await h.app.inject({ method: 'PUT', url: '/api/v1/admin/settings/zones.max_radius_m',
        headers: auth(h.tokens.admin!), payload: { value: 100000 } });
    }
  });

  it('rechaza coordenadas fuera del territorio permitido', async () => {
    const res = await post(operator, '/api/v1/zones', {
      name: 'Fuera', geometry: { kind: 'circle', lat: 48.85, lon: 2.35, radiusM: 500 } });
    expect(res.statusCode).toBe(400);
  });

  it('reporta las zonas que contienen un punto del mapa', async () => {
    const res = await get(operator, `/api/v1/zones/containing?lat=${ORIGIN.lat}&lon=${ORIGIN.lon}`);
    expect(res.statusCode).toBe(200);
    const names = (res.json().items as Array<{ name: string }>).map((z) => z.name);
    expect(names).toContain('Residencia autorizada A');
    expect(names).toContain('Rectángulo de vigilancia');
    const outside = await get(operator, `api/v1/zones/containing?lat=20.5&lon=-78.0`.replace('api/', '/api/'));
    expect((outside.json().items as unknown[])).toHaveLength(0);
  });

  it('a zoom bajo la lista se filtra por bbox', async () => {
    const inside = await get(operator, `/api/v1/zones?bbox=${ORIGIN.lon - 0.1},${ORIGIN.lat - 0.1},${ORIGIN.lon + 0.1},${ORIGIN.lat + 0.1}`);
    expect((inside.json().items as unknown[]).length).toBeGreaterThanOrEqual(3);
    const far = await get(operator, '/api/v1/zones?bbox=-84.0,20.0,-83.0,21.0');
    expect(far.json().items).toHaveLength(0);
  });

  describe('personas dentro de la zona', () => {
    let insideId = ''; let outsideId = '';

    beforeAll(async () => {
      const ins = await post(operator, '/api/v1/persons', {
        code: 'ZN-IN-01', givenNames: 'Dentro', familyNames: 'Del Área', groups: ['A'],
        dataSource: 'pruebas', consentStatus: 'not_required',
        location: { ...ORIGIN, coordSource: 'map_pick', precisionLevel: 'high', addressGranularity: 'dwelling' },
      });
      insideId = ins.json().id;
      const out = await post(operator, '/api/v1/persons', {
        code: 'ZN-OUT-01', givenNames: 'Fuera', familyNames: 'Del Área', groups: ['A'],
        dataSource: 'pruebas', consentStatus: 'not_required',
        location: { lat: ORIGIN.lat + 0.2, lon: ORIGIN.lon + 0.2, coordSource: 'map_pick',
          precisionLevel: 'high', addressGranularity: 'locality' },
      });
      outsideId = out.json().id;
    });

    it('el recálculo por geometría asigna solo a quien vive dentro', async () => {
      const res = await post(operator, `/api/v1/zones/${zoneId}/recompute`);
      expect(res.statusCode).toBe(200);
      expect(res.json().added).toBe(1);
      const list = await get(operator, `/api/v1/zones/${zoneId}/persons`);
      const items = list.json().items as Array<{ id: string; viaGeometry: boolean; viaManual: boolean }>;
      expect(items.map((p) => p.id)).toContain(insideId);
      expect(items.map((p) => p.id)).not.toContain(outsideId);
      expect(items.find((p) => p.id === insideId)?.viaGeometry).toBe(true);
    });

    it('la asignación manual incluye a alguien que vive fuera', async () => {
      const res = await h.app.inject({
        method: 'PUT', url: `/api/v1/zones/${zoneId}/persons`,
        headers: auth(operator), payload: { add: [outsideId] } });
      expect(res.statusCode).toBe(200);
      expect(res.json().added).toBe(1);
      const list = await get(operator, `/api/v1/zones/${zoneId}/persons`);
      const item = (list.json().items as Array<{ id: string; viaManual: boolean; viaGeometry: boolean }>)
        .find((p) => p.id === outsideId);
      expect(item?.viaManual).toBe(true);
      expect(item?.viaGeometry).toBe(false);
    });

    it('desasigna al quitar la persona de la zona', async () => {
      const res = await h.app.inject({
        method: 'PUT', url: `/api/v1/zones/${zoneId}/persons`,
        headers: auth(operator), payload: { remove: [outsideId] } });
      expect(res.json().removed).toBe(1);
    });

    it('un consultor sin permiso zones.write no puede crear zonas', async () => {
      const res = await post(h.tokens.consultant!, '/api/v1/zones', { name: 'X', geometry: circle(300) });
      expect(res.statusCode).toBe(403);
    });

    it('elimina la zona y su pertenencia en cascada', async () => {
      const r = await post(operator, '/api/v1/zones', { name: 'Temporal', geometry: rectangle(0.001, 0.001) });
      const id = r.json().id as string;
      await h.app.inject({ method: 'PUT', url: `/api/v1/zones/${id}/persons`,
        headers: auth(operator), payload: { add: [insideId] } });
      const del = await h.app.inject({ method: 'DELETE', url: `/api/v1/zones/${id}`, headers: auth(operator) });
      expect(del.statusCode).toBe(200);
      const { rows } = await h.db.query('SELECT count(*)::int AS n FROM geo.zone_members WHERE zone_id = $1', [id]);
      expect(rows[0].n).toBe(0);
    });
  });

  describe('personal y pases asociados a la zona', () => {
    let personId = ''; let inmatePassId = ''; let personnelId = '';

    beforeAll(async () => {
      const p = await post(operator, '/api/v1/persons', {
        code: 'ZN-PAS-01', givenNames: 'Interno', familyNames: 'En Pase', groups: ['B'],
        dataSource: 'pruebas', consentStatus: 'not_required',
        location: { ...ORIGIN, coordSource: 'map_pick', precisionLevel: 'high', addressGranularity: 'dwelling' },
      });
      personId = p.json().id;
      await post(operator, `/api/v1/persons/${personId}/inmate`, { internCode: 'ZN-INT-01', facility: 'Penal de prueba' });
      const pass = await post(operator, '/api/v1/passes', {
        personId, startsAt: new Date().toISOString(),
        endsAt: new Date(Date.now() + 3 * 86_400_000).toISOString(),
        authorizedZoneId: zoneId, facility: 'Penal de prueba',
      });
      expect(pass.statusCode).toBe(201);
      inmatePassId = pass.json().id;
      const pe = await post(operator, '/api/v1/personnel', {
        fullName: 'Capitán de Prueba Zona', rank: 'Capitán', unit: 'UM-01',
        phone: '+53 500-0000', roleNote: 'Cobertura de área',
      });
      personnelId = pe.json().id;
      await h.app.inject({ method: 'PUT', url: `/api/v1/personnel/${personnelId}/location`,
        headers: auth(operator), payload: { lat: ORIGIN.lat, lon: ORIGIN.lon } });
    });

    it('la zona lista el pase activo de un interno que vive dentro', async () => {
      const res = await get(operator, `/api/v1/zones/${zoneId}/passes`);
      const items = res.json().items as Array<{ state: string; authorizedHere: boolean }>;
      const active = items.filter((p) => p.state === 'active');
      expect(active.length).toBeGreaterThanOrEqual(1);
      expect(active.some((p) => p.authorizedHere)).toBe(true);
    });

    it('la zona lista el personal asignado y el que vive dentro', async () => {
      await h.app.inject({ method: 'PATCH', url: `/api/v1/personnel/${personnelId}`,
        headers: auth(operator), payload: { zoneId } });
      const res = await get(operator, `/api/v1/zones/${zoneId}/personnel`);
      const items = res.json().items as Array<{ id: string; assigned: boolean; insideZone: boolean; phone: string }>;
      const found = items.find((p) => p.id === personnelId);
      expect(found).toBeDefined();
      expect(found!.assigned).toBe(true);
      expect(found!.phone).toContain('500');
    });
  });
});
