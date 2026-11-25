import { writeFile } from 'node:fs/promises';
import { parseArgs } from 'node:util';

/**
 * Prueba de carga sin dependencias: N usuarios virtuales concurrentes
 * ejecutan una mezcla realista de operaciones durante D segundos contra el
 * API real. Mide p50/p95/p99 por escenario y muestrea la memoria del API.
 *
 * Uso: LEXAIR_PERF_PASSWORD=... node dist/cli/load-test.js --base http://127.0.0.1:3000 \
 *        --user perf --users 30 --duration 120 --out perf.json
 */
type Sample = { scenario: string; ms: number; ok: boolean };

function pct(sorted: number[], p: number): number {
  if (sorted.length === 0) return 0;
  return sorted[Math.min(sorted.length - 1, Math.ceil((p / 100) * sorted.length) - 1)]!;
}

async function main(): Promise<void> {
  const { values } = parseArgs({ options: {
    base: { type: 'string', default: 'http://127.0.0.1:3000' },
    user: { type: 'string', default: 'perf' },
    users: { type: 'string', default: '30' },
    duration: { type: 'string', default: '60' },
    out: { type: 'string', default: 'perf-results.json' },
  } });
  const base = `${values.base}/api/v1`;
  const password = process.env.LEXAIR_PERF_PASSWORD;
  if (!password) throw new Error('Defina LEXAIR_PERF_PASSWORD');
  const login = await fetch(`${base}/auth/login`, { method: 'POST', headers: { 'content-type': 'application/json' },
    body: JSON.stringify({ username: values.user, password, clientKind: 'api' }) });
  if (!login.ok) throw new Error(`Login falló: HTTP ${login.status}`);
  const { token } = (await login.json()) as { token: string };
  const headers = { authorization: `Bearer ${token}` };
  const get = async (path: string) => {
    const r = await fetch(`${base}${path}`, { headers });
    await r.arrayBuffer();
    return r.ok;
  };

  // Muestra de personas con ubicación de una página aleatoria (no depende de la búsqueda).
  const sample = await fetch(`${base}/persons?pageSize=200&hasLocation=true&page=${1 + Math.floor(Math.random() * 50)}`, { headers });
  const sampleJson = (await sample.json()) as { items: Array<{ id: string; code: string; givenNames: string }> };
  const people = sampleJson.items;
  if (people.length === 0) throw new Error('No hay personas sintéticas; ejecute seed:synthetic');
  const radii = [100, 250, 500, 1000, 2000, 5000];
  const pick = <T>(a: T[]): T => a[Math.floor(Math.random() * a.length)]!;
  const views = [
    { z: 10, bbox: '-80.6,22.0,-79.3,22.9' },
    { z: 13, bbox: '-80.02,22.36,-79.90,22.45' },
    { z: 16, bbox: '-79.975,22.40,-79.955,22.415' },
  ];
  const scenarios: Array<[string, number, () => Promise<boolean>]> = [
    ['proximity', 30, () => get(`/persons/${pick(people).id}/nearby?radius=${pick(radii)}&pageSize=50`)],
    ['search_name', 15, () => get(`/persons?q=${encodeURIComponent(pick(people).givenNames.slice(0, 5))}&pageSize=25`)],
    ['search_code', 15, () => get(`/persons?q=${pick(people).code}`)],
    ['person_detail', 10, () => get(`/persons/${pick(people).id}`)],
    ['geocode', 10, () => get(`/geocoding/search?q=${encodeURIComponent(pick(['marti', 'independencia', 'parque', 'central', 'santa clara', 'calle 5']))}`)],
    ['map_points', 15, () => { const v = pick(views); return get(`/maps/points?bbox=${v.bbox}&zoom=${v.z}`); }],
    ['group_filter', 5, () => get(`/persons?groups=${pick(['A', 'B', 'A,B'])}&pageSize=50`)],
  ];
  const weightTotal = scenarios.reduce((s, x) => s + x[1], 0);
  const choose = () => {
    let r = Math.random() * weightTotal;
    for (const s of scenarios) { r -= s[1]; if (r <= 0) return s; }
    return scenarios[0]!;
  };

  const samples: Sample[] = [];
  const memory: Array<{ t: number; rssMb: number; heapUsedMb: number; pool: unknown }> = [];
  const end = Date.now() + Number(values.duration) * 1000;
  const memTimer = setInterval(async () => {
    try {
      const r = await fetch(`${base}/admin/status`, { headers });
      const j = (await r.json()) as { api: { memory: { rssMb: number; heapUsedMb: number }; pool: unknown } };
      memory.push({ t: Date.now(), ...j.api.memory, pool: j.api.pool });
    } catch { /* el muestreo no debe abortar la prueba */ }
  }, 5000);
  const worker = async () => {
    while (Date.now() < end) {
      const [name, , fn] = choose();
      const t = performance.now();
      let ok: boolean;
      try { ok = await fn(); } catch { ok = false; }
      samples.push({ scenario: name, ms: performance.now() - t, ok });
    }
  };
  const vus = Number(values.users);
  const t0 = Date.now();
  await Promise.all(Array.from({ length: vus }, worker));
  clearInterval(memTimer);
  const elapsed = (Date.now() - t0) / 1000;

  const byScenario = Object.fromEntries(scenarios.map(([name]) => {
    const s = samples.filter((x) => x.scenario === name);
    const ms = s.map((x) => x.ms).sort((a, b) => a - b);
    return [name, { requests: s.length, errors: s.filter((x) => !x.ok).length,
      p50: +pct(ms, 50).toFixed(1), p95: +pct(ms, 95).toFixed(1), p99: +pct(ms, 99).toFixed(1),
      max: +(ms[ms.length - 1] ?? 0).toFixed(1) }];
  }));
  const result = { virtualUsers: vus, durationS: elapsed, totalRequests: samples.length,
    rps: +(samples.length / elapsed).toFixed(1), errors: samples.filter((x) => !x.ok).length,
    scenarios: byScenario, apiMemory: memory, finishedAt: new Date().toISOString() };
  await writeFile(values.out!, JSON.stringify(result, null, 2));
  console.log(JSON.stringify({ ...result, apiMemory: `${memory.length} muestras` }, null, 2));
}

main().catch((err) => {
  console.error(err instanceof Error ? err.message : err);
  process.exit(1);
});
