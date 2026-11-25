import { afterAll, beforeAll, describe, expect, it } from 'vitest';
import { auth, integrationEnabled, setupHarness, teardown, type Harness } from './helpers.js';

const CSV = [
  'code,given_names,family_names,data_source,lat,lon,precision_level',
  'IMP-001,Ficticia,Importada Uno,import pruebas,22.40,-79.95,approximate',
  'IMP-002,Ficticio,Importado Dos,import pruebas,,,',
  'IMP-003,Ficticio,Coordenada Mala,import pruebas,40.4,-3.7,',
  'IMP-001,Ficticia,Duplicada,import pruebas,,,',
  'x,Malo,Codigo,import pruebas,,,',
].join('\n');

describe.skipIf(!integrationEnabled)('importaciones, administración y salud', () => {
  let h: Harness;
  beforeAll(async () => { h = await setupHarness(); });
  afterAll(async () => teardown(h));

  const importCsv = (token: string, q: string, body = CSV) => h.app.inject({ method: 'POST',
    url: `/api/v1/imports/persons?${q}`, headers: { ...auth(token), 'content-type': 'text/csv' }, payload: body });

  it('valida sin escribir en modo simulación', async () => {
    const res = await importCsv(h.tokens.admin!, 'group=A&dryRun=true');
    expect(res.statusCode).toBe(200);
    const b = res.json();
    expect(b.totalRows).toBe(5);
    expect(b.okRows).toBe(2);
    expect(b.errorRows).toBe(3);
    const { rows } = await h.db.query("SELECT count(*)::int AS n FROM directory.persons WHERE code LIKE 'IMP-%'");
    expect(rows[0].n).toBe(0);
  });

  it('importa filas válidas y registra errores por línea', async () => {
    const res = await importCsv(h.tokens.admin!, 'group=A&dryRun=false&filename=prueba.csv');
    expect(res.statusCode).toBe(201);
    expect(res.json().status).toBe('completed_with_errors');
    expect(res.json().errors.map((e: { line: number }) => e.line)).toEqual([4, 5, 6]);
    const job = await h.app.inject({ method: 'GET', url: `/api/v1/imports/${res.json().jobId}`, headers: auth(h.tokens.admin!) });
    expect(job.json().errors).toHaveLength(3);
  });

  it('reimportar a otro grupo añade membresía sin duplicar identidad', async () => {
    const res = await importCsv(h.tokens.admin!, 'group=B&dryRun=false',
      'code,given_names,family_names,data_source\nIMP-001,Ficticia,Importada Uno,import pruebas');
    expect(res.json().okRows).toBe(1);
    const { rows } = await h.db.query(`SELECT count(DISTINCT p.id)::int AS persons, count(*)::int AS memberships
      FROM directory.persons p JOIN directory.person_memberships m ON m.person_id = p.id WHERE p.code = 'IMP-001'`);
    expect(rows[0]).toEqual({ persons: 1, memberships: 2 });
  });

  it('el operador no puede importar', async () => {
    expect((await importCsv(h.tokens.operator!, 'group=A')).statusCode).toBe(403);
  });

  it('panel: dashboard, estado, configuración validada y auditoría', async () => {
    const dash = await h.app.inject({ method: 'GET', url: '/api/v1/admin/dashboard', headers: auth(h.tokens.admin!) });
    expect(dash.json().persons_total).toBeGreaterThanOrEqual(2);
    const status = await h.app.inject({ method: 'GET', url: '/api/v1/admin/status', headers: auth(h.tokens.admin!) });
    expect(status.json().database.ok).toBe(true);
    expect(status.json().cartography.isSynthetic).toBe(true);
    const bad = await h.app.inject({ method: 'PUT', url: '/api/v1/admin/settings/proximity.max_results',
      headers: auth(h.tokens.admin!), payload: { value: -5 } });
    expect(bad.statusCode).toBe(400);
    const ok = await h.app.inject({ method: 'PUT', url: '/api/v1/admin/settings/proximity.max_results',
      headers: auth(h.tokens.admin!), payload: { value: 400 } });
    expect(ok.statusCode).toBe(200);
    const audit = await h.app.inject({ method: 'GET', url: '/api/v1/audit?action=settings', headers: auth(h.tokens.admin!) });
    expect(audit.json().items[0].action).toBe('settings.update');
    const denied = await h.app.inject({ method: 'GET', url: '/api/v1/audit', headers: auth(h.tokens.operator!) });
    expect(denied.statusCode).toBe(403);
  });

  it('solo el superadministrador modifica permisos de roles', async () => {
    const byAdmin = await h.app.inject({ method: 'PUT', url: '/api/v1/admin/roles/readonly/permissions',
      headers: auth(h.tokens.admin!), payload: { permissions: ['persons.read'] } });
    expect(byAdmin.statusCode).toBe(403);
    const bySuper = await h.app.inject({ method: 'PUT', url: '/api/v1/admin/roles/readonly/permissions',
      headers: auth(h.tokens.superadmin!), payload: { permissions: ['persons.read', 'groups.a.read'] } });
    expect(bySuper.statusCode).toBe(200);
  });

  it('health responde sin autenticación e indica el estado de cada servicio', async () => {
    const res = await h.app.inject({ method: 'GET', url: '/api/v1/health' });
    expect(res.statusCode).toBe(200);
    expect(res.json().services.database).toBe('ok');
    expect(res.json().services.tiles).toBe('down');
    expect(res.json().status).toBe('degraded');
  });

  it('estilos de mapa desde el manifiesto (fixture sintético marcado)', async () => {
    const res = await h.app.inject({ method: 'GET', url: '/api/v1/maps/styles', headers: auth(h.tokens.readonly!) });
    expect(res.json().isSynthetic).toBe(true);
    expect(res.json().styles[0].id).toBe('standard');
  });
});
