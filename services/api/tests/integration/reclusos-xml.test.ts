import { readFileSync } from 'node:fs';
import { fileURLToPath } from 'node:url';
import { afterAll, beforeAll, describe, expect, it } from 'vitest';
import { auth, integrationEnabled, setupHarness, teardown, type Harness } from './helpers.js';
import { composeAddress, parseReclusosXml } from '../../src/modules/imports/reclusos-xml-parser.js';

/**
 * Importación del libro de reclusos en pase (SpreadsheetML 2003). Se usa un
 * fichero de ejemplo con datos 100 % sintéticos (fixtures/reclusos_ejemplo.xml).
 */
describe.skipIf(!integrationEnabled)('importación de reclusos XML', () => {
  let h: Harness;
  let admin = '';
  const xml = readFileSync(fileURLToPath(new URL('./fixtures/reclusos_ejemplo.xml', import.meta.url)), 'utf8');

  beforeAll(async () => {
    h = await setupHarness();
    admin = h.tokens.admin!;
    // Municipios de prueba (el catálogo real de OSM no está cargado en tests).
    await h.db.query(`INSERT INTO geo.municipalities (code, name, boundary, source_code) VALUES
      ('fx-santa-clara', 'Santa Clara', ST_Multi(ST_MakeEnvelope(-79.99, 22.38, -79.93, 22.44, 4326)), 'test_fixture'),
      ('fx-placetas', 'Placetas', ST_Multi(ST_MakeEnvelope(-79.66, 22.28, -79.58, 22.34, 4326)), 'test_fixture')
      ON CONFLICT (code) DO NOTHING`);
  });
  afterAll(async () => teardown(h));

  const postXml = (token: string, query: string) =>
    h.app.inject({ method: 'POST', url: `/api/v1/imports/reclusos-xml${query}`,
      headers: { ...auth(token), 'content-type': 'application/xml' }, payload: xml });

  it('valida en seco sin escribir datos (dryRun)', async () => {
    const res = await postXml(admin, '?dryRun=true&filename=ejemplo.xml');
    expect(res.statusCode).toBe(200);
    const j = res.json();
    expect(j.sheet).toBe('BBDD_CON_DIRECCION');
    expect(j.totalRows).toBe(3);      // 2 válidas + 1 descartada por el parser
    expect(j.errorRows).toBe(1);      // la fila sin NIDENTIDAD se informa como error
    expect(j.okRows).toBe(2);
  });

  it('importa personas, internos y ubicación por municipio', async () => {
    const res = await postXml(admin, '?dryRun=false&filename=ejemplo.xml');
    expect(res.statusCode).toBe(201);
    const j = res.json();
    expect(j.okRows).toBe(2);
    expect(j.inmates).toBe(2);
    expect(j.located).toBe(2);
    const job = await h.app.inject({ method: 'GET', url: `/api/v1/imports/${j.jobId}`, headers: auth(admin) });
    expect(job.json().kind).toBe('reclusos_xml');
  });

  it('las personas importadas quedan consultables y sin duplicar al reimportar', async () => {
    const res = await postXml(admin, '?dryRun=false&filename=ejemplo-2.xml');
    expect(res.statusCode).toBe(201);
    expect(res.json().okRows).toBe(2);
    const list = await h.app.inject({ method: 'GET',
      url: '/api/v1/persons?pageSize=10', headers: auth(admin) });
    const items = list.json().items as { code: string; givenNames: string }[];
    const importadas = items.filter((p) => p.code === '00010100001');
    expect(importadas).toHaveLength(1);
    expect(importadas[0]!.givenNames).toBe('Ejemplo Uno');
    // La segunda importación actualiza (no duplica) las personas existentes.
  });

  it('la ficha de interno conserva unidad y fecha de ingreso', async () => {
    const list = await h.app.inject({ method: 'GET', url: '/api/v1/persons?pageSize=50', headers: auth(admin) });
    const items = list.json().items as { id: string; code: string }[];
    const p = items.find((x) => x.code === '00010100002')!;
    const passes = await h.app.inject({ method: 'GET',
      url: `/api/v1/persons/${p.id}/passes`, headers: auth(admin) });
    const inmate = passes.json().inmate;
    expect(inmate).not.toBeNull();
    expect(inmate.facility).toBe('CP Ejemplo VC');
    expect(inmate.notes).toContain('Ingreso real');
  });

  it('compone la dirección completa desde las columnas del registro', () => {
    const parsed = parseReclusosXml(xml);
    expect(composeAddress(parsed.rows[0]!))
      .toBe('Calle Ejemplo 101 entre A y B, CP Vigía Sur, CDR 12, Santa Clara, Villa Clara');
  });

  it('rechaza un XML que no sea un libro de Excel', async () => {
    const res = await h.app.inject({ method: 'POST', url: '/api/v1/imports/reclusos-xml?dryRun=true',
      headers: { ...auth(admin), 'content-type': 'application/xml' },
      payload: '<root>no es un libro</root>' });
    expect(res.statusCode).toBe(400);
    expect(res.json().error).toBe('BAD_REQUEST');
  });
});
