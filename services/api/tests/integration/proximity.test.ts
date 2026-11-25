import { afterAll, beforeAll, describe, expect, it } from 'vitest';
import { auth, integrationEnabled, north, ORIGIN, setupHarness, teardown, type Harness } from './helpers.js';

describe.skipIf(!integrationEnabled)('proximidad (PostGIS)', () => {
  let h: Harness;
  let originId = '';
  const ids: Record<number, string> = {};

  beforeAll(async () => {
    h = await setupHarness();
    const mk = async (code: string, loc: { lat: number; lon: number }, groups: string[]) => {
      const res = await h.app.inject({ method: 'POST', url: '/api/v1/persons', headers: auth(h.tokens.admin!), payload: {
        code, givenNames: 'Sintético', familyNames: code, groups, dataSource: 'pruebas', consentStatus: 'not_required',
        location: { ...loc, coordSource: 'manual_coordinates', precisionLevel: 'high' } } });
      if (res.statusCode !== 201) throw new Error(res.body);
      return res.json().id as string;
    };
    originId = await mk('PRX-000', ORIGIN, ['A']);
    for (const m of [80, 240, 480, 900, 1900, 4800, 9000]) ids[m] = await mk(`PRX-${m}`, north(m), m === 480 ? ['B'] : ['A']);
  });
  afterAll(async () => teardown(h));

  const nearby = (token: string, q: string) =>
    h.app.inject({ method: 'GET', url: `/api/v1/persons/${originId}/nearby?${q}`, headers: auth(token) });

  it.each([
    [100, ['PRX-80']],
    [250, ['PRX-80', 'PRX-240']],
    [500, ['PRX-80', 'PRX-240', 'PRX-480']],
    [1000, ['PRX-80', 'PRX-240', 'PRX-480', 'PRX-900']],
    [5000, ['PRX-80', 'PRX-240', 'PRX-480', 'PRX-900', 'PRX-1900', 'PRX-4800']],
  ])('radio %i m devuelve exactamente los esperados, ordenados por distancia', async (radius, expected) => {
    const res = await nearby(h.tokens.operator!, `radius=${radius}`);
    expect(res.statusCode).toBe(200);
    expect(res.json().items.map((p: { code: string }) => p.code)).toEqual(expected);
  });

  it('calcula distancias geodésicas correctas (±1 %)', async () => {
    const res = await nearby(h.tokens.operator!, 'radius=5000');
    for (const p of res.json().items as Array<{ code: string; distanceM: number }>) {
      const m = Number(p.code.split('-')[1]);
      expect(Math.abs(p.distanceM - m) / m).toBeLessThan(0.01);
    }
  });

  it('filtra por grupo', async () => {
    const res = await nearby(h.tokens.operator!, 'radius=1000&groups=B');
    expect(res.json().items.map((p: { code: string }) => p.code)).toEqual(['PRX-480']);
  });

  it('pagina resultados', async () => {
    const p1 = await nearby(h.tokens.operator!, 'radius=5000&pageSize=2&page=1');
    const p2 = await nearby(h.tokens.operator!, 'radius=5000&pageSize=2&page=2');
    expect(p1.json().items.map((p: { code: string }) => p.code)).toEqual(['PRX-80', 'PRX-240']);
    expect(p2.json().items.map((p: { code: string }) => p.code)).toEqual(['PRX-480', 'PRX-900']);
    expect(p1.json().total).toBe(6);
  });

  it('radio personalizado requiere permiso y respeta el máximo', async () => {
    expect((await nearby(h.tokens.operator!, 'radius=750')).statusCode).toBe(403);
    expect((await nearby(h.tokens.admin!, 'radius=750')).statusCode).toBe(200);
    expect((await nearby(h.tokens.admin!, 'radius=20000')).statusCode).toBe(400);
  });

  it('sin permiso exacto las distancias se redondean a 50 m y no hay coordenadas', async () => {
    const res = await nearby(h.tokens.consultant!, 'radius=250');
    const body = res.json();
    expect(body.distancesRounded).toBe(true);
    for (const p of body.items) {
      expect(p.distanceM % 50).toBe(0);
      expect(p.location.lat).toBeNull();
    }
  });

  it('solo lectura no puede consultar proximidad', async () => {
    expect((await nearby(h.tokens.readonly!, 'radius=500')).statusCode).toBe(403);
  });

  it('la consulta usa el índice GiST', async () => {
    await h.db.query('ANALYZE geo.person_locations');
    const { rows } = await h.db.query(`EXPLAIN (FORMAT JSON)
      SELECT person_id FROM geo.person_locations
       WHERE ST_DWithin(geom, ST_SetSRID(ST_MakePoint(-79.95, 22.4), 4326)::geography, 500)`,
    );
    await h.db.query('SET enable_seqscan = off');
    const forced = await h.db.query(`EXPLAIN SELECT person_id FROM geo.person_locations
       WHERE ST_DWithin(geom, ST_SetSRID(ST_MakePoint(-79.95, 22.4), 4326)::geography, 500)`);
    await h.db.query('RESET enable_seqscan');
    expect(JSON.stringify(rows) + JSON.stringify(forced.rows)).toContain('person_locations_geom_gix');
  });

  it('agrupa marcadores a zoom bajo y devuelve puntos a zoom alto', async () => {
    await h.apiDb.query('SELECT geo.refresh_map_clusters(true)');
    const low = await h.app.inject({ method: 'GET', url: '/api/v1/maps/points?bbox=-80.6,22.0,-79.3,22.9&zoom=9',
      headers: auth(h.tokens.admin!) });
    expect(low.json().mode).toBe('clusters');
    const total = low.json().items.reduce((s: number, c: { count: number }) => s + c.count, 0);
    expect(total).toBe(8);
    const high = await h.app.inject({ method: 'GET', url: '/api/v1/maps/points?bbox=-79.96,22.39,-79.94,22.41&zoom=16',
      headers: auth(h.tokens.admin!) });
    expect(high.json().mode).toBe('points');
    const consultant = await h.app.inject({ method: 'GET', url: '/api/v1/maps/points?bbox=-79.96,22.39,-79.94,22.41&zoom=16',
      headers: auth(h.tokens.consultant!) });
    expect(consultant.json().mode).toBe('clusters');
  });

  it('los agregados precalculados respetan grupos y avisan de cambios pendientes', async () => {
    await h.apiDb.query('SELECT geo.refresh_map_clusters(true)');
    const bbox = '-80.6,22.0,-79.3,22.9';
    for (const groups of ['A', 'B', 'A,B']) {
      const res = await h.app.inject({ method: 'GET', url: `/api/v1/maps/points?bbox=${bbox}&zoom=11&groups=${groups}`,
        headers: auth(h.tokens.admin!) });
      expect(res.json().pendingChanges).toBe(false);
      const total = res.json().items.reduce((s: number, c: { count: number }) => s + c.count, 0);
      const { rows } = await h.db.query<{ n: number }>(
        `SELECT count(DISTINCT p.id)::int AS n FROM directory.persons p
           JOIN geo.person_locations l ON l.person_id = p.id
           JOIN directory.person_memberships m ON m.person_id = p.id
           JOIN directory.person_groups g ON g.id = m.group_id
          WHERE p.is_active AND g.code = ANY($1::text[])
            AND l.geom && ST_MakeEnvelope(-80.6, 22.0, -79.3, 22.9, 4326)::geography`, [groups.split(',')]);
      expect(total).toBe(rows[0]!.n);
    }
    await h.db.query(`UPDATE geo.person_locations SET updated_at = updated_at WHERE false`);
    const after = await h.app.inject({ method: 'GET', url: `/api/v1/maps/points?bbox=${bbox}&zoom=11`,
      headers: auth(h.tokens.admin!) });
    expect(after.json().pendingChanges).toBe(true);
    expect(await h.apiDb.query('SELECT geo.refresh_map_clusters(false) AS r').then((r) => r.rows[0].r)).toBe(true);
    expect(await h.apiDb.query('SELECT geo.refresh_map_clusters(false) AS r').then((r) => r.rows[0].r)).toBe(false);
  });
});
