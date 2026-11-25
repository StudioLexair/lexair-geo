import { afterAll, beforeAll, describe, expect, it } from 'vitest';
import { integrationEnabled, setupHarness, teardown, type Harness } from './helpers.js';

describe.skipIf(!integrationEnabled)('restricciones de base de datos', () => {
  let h: Harness;
  let pid = '';
  beforeAll(async () => {
    h = await setupHarness();
    const { rows } = await h.db.query(`INSERT INTO directory.persons (code, given_names, family_names, data_source)
      VALUES ('DB-001', 'Ficticio', 'Restricciones', 'pruebas') RETURNING id`);
    pid = rows[0].id;
  });
  afterAll(async () => teardown(h));

  const insertLoc = (lon: number, lat: number, extra = '') => h.db.query(
    `INSERT INTO geo.person_locations (person_id, geom, coord_source ${extra ? ', precision_level, validation_status' : ''})
     VALUES ($1, ST_SetSRID(ST_MakePoint($2, $3), 4326)::geography, 'manual_coordinates' ${extra})`, [pid, lon, lat]);

  it('rechaza coordenadas fuera de Cuba', async () => {
    await expect(insertLoc(-3.7, 40.4)).rejects.toThrow(/person_locations_in_cuba/);
  });

  it('exact_verified exige verificación', async () => {
    await expect(insertLoc(-79.95, 22.4, ", 'exact_verified', 'pending'")).rejects.toThrow(/exact_requires_verification/);
  });

  it('rechaza códigos con formato inválido', async () => {
    await expect(h.db.query(`INSERT INTO directory.persons (code, given_names, family_names, data_source)
      VALUES ('x', 'a', 'b', 'pruebas')`)).rejects.toThrow(/check/i);
  });

  it('rechaza contraseñas que no sean hash argon2id', async () => {
    await expect(h.db.query(`INSERT INTO identity.users (username, display_name, password_hash, role_id)
      VALUES ('t_plano', 'x', 'textoplano', 1)`)).rejects.toThrow(/check/i);
  });

  it('la auditoría es de solo inserción', async () => {
    await h.db.query(`INSERT INTO audit.audit_logs (action, entity_type) VALUES ('test.insert', 'test')`);
    await expect(h.db.query('DELETE FROM audit.audit_logs')).rejects.toThrow(/solo inserción/);
    await expect(h.db.query("UPDATE audit.audit_logs SET action = 'x.y'")).rejects.toThrow(/solo inserción/);
  });

  it('una sola ubicación fija por persona', async () => {
    await insertLoc(-79.95, 22.4);
    await expect(insertLoc(-79.96, 22.41)).rejects.toThrow(/duplicate key|person_locations_pkey/);
  });

  it('existen los índices espaciales y trigram', async () => {
    const { rows } = await h.db.query(`SELECT indexname FROM pg_indexes WHERE schemaname IN ('geo','directory')`);
    const names = rows.map((r) => r.indexname);
    for (const n of ['person_locations_geom_gix', 'addresses_geom_gix', 'persons_name_trgm', 'addresses_search_trgm']) {
      expect(names).toContain(n);
    }
  });

  it('normalize_text coincide con la versión TypeScript', async () => {
    const { normalizeText } = await import('../../src/lib/text.js');
    const samples = ['Calle Martí #45', '  ÁVILA   Ñañez ', 'Reparto José Martí, Santa Clara'];
    for (const s of samples) {
      const { rows } = await h.db.query('SELECT catalog.normalize_text($1) AS n', [s]);
      expect(rows[0].n).toBe(normalizeText(s));
    }
  });
});
