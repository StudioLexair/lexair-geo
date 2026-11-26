import { afterAll, beforeAll, describe, expect, it } from 'vitest';
import { auth, integrationEnabled, setupHarness, teardown, type Harness } from './helpers.js';

describe.skipIf(!integrationEnabled)('fotografía de la persona', () => {
  let h: Harness;
  beforeAll(async () => { h = await setupHarness(); });
  afterAll(async () => teardown(h));

  let seq = 0;
  const crear = async () => {
    seq += 1;
    const res = await h.app.inject({
      method: 'POST', url: '/api/v1/persons',
      headers: { ...auth(h.tokens.admin!), 'content-type': 'application/json' },
      payload: { code: `FOT-${String(seq).padStart(4, '0')}`, givenNames: 'Foto', familyNames: 'Prueba', groups: ['A'], dataSource: 'pruebas' },
    });
    expect(res.statusCode).toBe(201);
    return res.json().id as string;
  };

  it('sin foto responde 404', async () => {
    const id = await crear();
    const res = await h.app.inject({
      method: 'GET', url: `/api/v1/persons/${id}/photo`, headers: auth(h.tokens.admin!),
    });
    expect(res.statusCode).toBe(404);
  });

  it('sube, sirve y borra la foto', async () => {
    const id = await crear();
    const bytes = Buffer.from('0123456789'.repeat(10), 'utf8');
    const up = await h.app.inject({
      method: 'PUT', url: `/api/v1/persons/${id}/photo`,
      headers: { ...auth(h.tokens.admin!), 'content-type': 'image/png' }, payload: bytes,
    });
    expect(up.statusCode).toBe(200);
    expect(up.json().bytes).toBe(bytes.length);

    const get = await h.app.inject({
      method: 'GET', url: `/api/v1/persons/${id}/photo`, headers: auth(h.tokens.admin!),
    });
    expect(get.statusCode).toBe(200);
    expect(get.headers['content-type']).toBe('image/png');
    expect(get.rawPayload).toEqual(bytes);

    const del = await h.app.inject({
      method: 'DELETE', url: `/api/v1/persons/${id}/photo`, headers: auth(h.tokens.admin!),
    });
    expect(del.statusCode).toBe(200);
    const get2 = await h.app.inject({
      method: 'GET', url: `/api/v1/persons/${id}/photo`, headers: auth(h.tokens.admin!),
    });
    expect(get2.statusCode).toBe(404);
  });

  it('rechaza formatos no admitidos', async () => {
    const id = await crear();
    const res = await h.app.inject({
      method: 'PUT', url: `/api/v1/persons/${id}/photo`,
      headers: { ...auth(h.tokens.admin!), 'content-type': 'application/pdf' },
      payload: Buffer.from('0123456789'.repeat(10)),
    });
    expect(res.statusCode).toBe(415);
  });
});
