import { afterAll, beforeAll, describe, expect, it } from 'vitest';
import { auth, integrationEnabled, login, PASSWORD, setupHarness, teardown, type Harness } from './helpers.js';

describe.skipIf(!integrationEnabled)('auth', () => {
  let h: Harness;
  beforeAll(async () => { h = await setupHarness(); });
  afterAll(async () => teardown(h));

  it('rechaza credenciales incorrectas sin revelar si el usuario existe', async () => {
    const a = await h.app.inject({ method: 'POST', url: '/api/v1/auth/login', payload: { username: 't_operator', password: 'mal' } });
    const b = await h.app.inject({ method: 'POST', url: '/api/v1/auth/login', payload: { username: 'noexiste', password: 'mal' } });
    expect(a.statusCode).toBe(401);
    expect(b.statusCode).toBe(401);
    expect(a.json().message).toBe(b.json().message);
  });

  it('devuelve el perfil con permisos y grupos', async () => {
    const res = await h.app.inject({ method: 'GET', url: '/api/v1/auth/me', headers: auth(h.tokens.consultant!) });
    expect(res.statusCode).toBe(200);
    const me = res.json();
    expect(me.role).toBe('consultant');
    expect(me.permissions).toContain('proximity.query');
    expect(me.permissions).not.toContain('locations.exact.read');
    expect(me.groups.map((g: { code: string }) => g.code)).toEqual(['A', 'B']);
  });

  it('sin token responde 401', async () => {
    const res = await h.app.inject({ method: 'GET', url: '/api/v1/persons' });
    expect(res.statusCode).toBe(401);
  });

  it('logout revoca la sesión', async () => {
    const token = await login(h.app, 't_readonly', PASSWORD);
    const out = await h.app.inject({ method: 'POST', url: '/api/v1/auth/logout', headers: auth(token) });
    expect(out.statusCode).toBe(200);
    const again = await h.app.inject({ method: 'GET', url: '/api/v1/auth/me', headers: auth(token) });
    expect(again.statusCode).toBe(401);
  });

  it('bloquea temporalmente tras intentos fallidos', async () => {
    for (let i = 0; i < 5; i++) {
      await h.app.inject({ method: 'POST', url: '/api/v1/auth/login', payload: { username: 't_admin', password: `x${i}` } });
    }
    const res = await h.app.inject({ method: 'POST', url: '/api/v1/auth/login', payload: { username: 't_admin', password: PASSWORD } });
    expect(res.statusCode).toBe(401);
    await h.db.query("UPDATE identity.users SET locked_until = NULL, failed_attempts = 0 WHERE username = 't_admin'");
  });

  it('obliga a cambiar la contraseña temporal y aplica la política', async () => {
    const created = await h.app.inject({ method: 'POST', url: '/api/v1/users', headers: auth(h.tokens.superadmin!),
      payload: { username: 't_nuevo', displayName: 'Nuevo', role: 'operator' } });
    expect(created.statusCode).toBe(201);
    const temp = created.json().temporaryPassword as string;
    const token = await login(h.app, 't_nuevo', temp);
    const blocked = await h.app.inject({ method: 'GET', url: '/api/v1/persons', headers: auth(token) });
    expect(blocked.statusCode).toBe(403);
    const weak = await h.app.inject({ method: 'POST', url: '/api/v1/auth/change-password', headers: auth(token),
      payload: { currentPassword: temp, newPassword: 'corta' } });
    expect(weak.statusCode).toBe(400);
    const ok = await h.app.inject({ method: 'POST', url: '/api/v1/auth/change-password', headers: auth(token),
      payload: { currentPassword: temp, newPassword: 'Otra-Clave-Segura-99' } });
    expect(ok.statusCode).toBe(200);
    const nowOk = await h.app.inject({ method: 'GET', url: '/api/v1/persons', headers: auth(token) });
    expect(nowOk.statusCode).toBe(200);
  });

  it('un administrador no puede crear superadministradores', async () => {
    const res = await h.app.inject({ method: 'POST', url: '/api/v1/users', headers: auth(h.tokens.admin!),
      payload: { username: 't_escalada', displayName: 'X', role: 'superadmin' } });
    expect(res.statusCode).toBe(403);
  });

  it('registra el login en auditoría sin la contraseña', async () => {
    const { rows } = await h.db.query("SELECT details::text AS d FROM audit.audit_logs WHERE action LIKE 'auth.%'");
    expect(rows.length).toBeGreaterThan(0);
    for (const r of rows) expect(r.d).not.toContain(PASSWORD);
  });
});
