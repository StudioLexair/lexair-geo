import { parseArgs } from 'node:util';
import pg from 'pg';

/**
 * Datos de DEMOSTRACIÓN para el módulo de operación de pases (todo sintético,
 * marcado is_synthetic, sin teléfonos reales): internos, pases activos,
 * personal de la fuerza con residencia y zonas dibujadas de ejemplo.
 *
 * Uso: node dist/cli/seed-ops.js [--zone-radius 900] [--inmates 12] [--personnel 10]
 */
async function main(): Promise<void> {
  const { values } = parseArgs({ options: {
    inmates: { type: 'string', default: '12' },
    personnel: { type: 'string', default: '10' },
    'zone-radius': { type: 'string', default: '900' },
  } });
  const inmates = Number(values.inmates);
  const personnel = Number(values.personnel);
  const radius = Number(values['zone-radius']);
  const client = new pg.Client({ connectionString: process.env.DATABASE_URL });
  await client.connect();
  try {
    // Zonas de ejemplo alrededor del centro configurado (o Santa Clara).
    const center = await client.query<{ value?: { lat: number; lon: number } }>(
      "SELECT value FROM catalog.system_settings WHERE key = 'map.default_center'");
    const lat = center.rows[0]?.value?.lat ?? 22.4067;
    const lon = center.rows[0]?.value?.lon ?? -79.9653;
    const zoneDefs = [
      { name: 'Residencia autorizada (demo)', kind: 'circle', dLat: 0, dLon: 0, cat: 1, label: 'Permanecer dentro del área' },
      { name: 'Zona de vigilancia (demo)', kind: 'circle', dLat: 0.012, dLon: 0.008, cat: 2, label: 'Observación reforzada' },
      { name: 'Punto de control norte (demo)', kind: 'rectangle', dLat: 0.004, dLon: 0.004, cat: 3, label: 'Checkpoint' },
    ] as const;
    const zoneIds: string[] = [];
    for (const z of zoneDefs) {
      const verts = z.kind === 'circle'
        ? JSON.stringify([{ lat, lon }])
        : JSON.stringify([
            { lat: lat - z.dLat, lon: lon - z.dLon }, { lat: lat - z.dLat, lon: lon + z.dLon },
            { lat: lat + z.dLat, lon: lon + z.dLon }, { lat: lat + z.dLat, lon: lon - z.dLon }]);
      const wkt = z.kind === 'circle'
        ? `ST_Buffer(ST_GeomFromText('POINT(${lon + (z.dLon as number)} ${lat + (z.dLat as number)})', 4326)::geography, ${radius})::geometry`
        : `ST_MakeEnvelope(${lon - z.dLon}, ${lat - z.dLat}, ${lon + z.dLon}, ${lat + z.dLat}, 4326)`;
      const { rows } = await client.query<{ id: string }>(
        `INSERT INTO geo.zones (name, kind, geom, vertices, center_lat, center_lon, radius_m,
           label_text, show_label, category_id, is_synthetic, data_source)
         VALUES ($1,$2,${wkt}::geography,$3::jsonb,$4,$5,$6,$7,true,$8,true,'seed_ops')
         RETURNING id`,
        [z.name, z.kind, verts, lat + (z.dLat as number), lon + (z.dLon as number),
          z.kind === 'circle' ? radius : null, z.label, z.cat]);
      zoneIds.push(rows[0]!.id);
    }
    console.log(JSON.stringify({ zones: zoneIds.length }));

    // Personas sintéticas con ubicación → internos → pases activos.
    const { rows: persons } = await client.query<{ id: string; code: string; name: string }>(
      `SELECT p.id, p.code, p.given_names || ' ' || p.family_names AS name
         FROM directory.persons p
         JOIN geo.person_locations l ON l.person_id = p.id
        WHERE p.is_synthetic AND p.is_active
        ORDER BY p.code LIMIT $1`, [inmates]);
    let passes = 0;
    for (const [i, p] of persons.entries()) {
      const internCode = `SYN-${p.code.replace('SYN-', '')}`;
      await client.query(
        `INSERT INTO directory.inmates (person_id, intern_code, facility, status, risk_level, data_source)
         VALUES ($1,$2,'Penal Sintético de Demostración','En pase',$3,'seed_ops')
         ON CONFLICT (person_id) DO NOTHING`,
        [p.id, internCode, ['Bajo', 'Medio', 'Alto'][i % 3] ?? 'Medio']);
      const res = await client.query<{ id: string }>(
        `INSERT INTO directory.passes (person_id, intern_id, pass_type_id, facility, starts_at, ends_at,
           authorized_zone_id, authorized_address, notes, data_source)
         VALUES ($1, $1, (SELECT id FROM directory.pass_types WHERE code = 'pase_ordinario'),
           'Penal Sintético de Demostración', now() - interval '2 hours',
           now() + ($3::text || ' days')::interval, $2, 'Dirección sintética de pase', 'Pase de demostración', 'seed_ops')
         RETURNING id`,
        [p.id, zoneIds[i % zoneIds.length]!, String(3 + (i % 5))]);
      if (res.rowCount) passes += 1;
      await client.query(
        `INSERT INTO geo.zone_members (zone_id, person_id, source)
         VALUES ($1, $2, 'geometry') ON CONFLICT DO NOTHING`, [zoneIds[i % zoneIds.length]!, p.id]);
    }
    console.log(JSON.stringify({ inmates: persons.length, passes }));

    // Personal de la fuerza alrededor del mismo centro.
    const ranks = ['Teniente', 'Sargento', 'Capitán', 'Primer Teniente', 'Suboficial'];
    let personnelCount = 0;
    for (let i = 0; i < personnel; i++) {
      const a = (i / Math.max(personnel, 1)) * 2 * Math.PI;
      const plat = lat + 0.004 * Math.cos(a) + (i % 3) * 0.002;
      const plon = lon + 0.004 * Math.sin(a);
      const res = await client.query(
        `INSERT INTO directory.personnel (code, full_name, rank, unit, address_text, geom,
           zone_id, role_note, is_synthetic, data_source)
         VALUES ($1,$2,$3,'UM-Demo-' || $4, 'Residencia sintética ' || $4,
           ST_SetSRID(ST_MakePoint($5, $6), 4326)::geography, $7, 'Cobertura de área (demo)', true, 'seed_ops')`,
        [`SYN-P${String(i + 1).padStart(3, '0')}`, `Colaborador Sintético ${i + 1}`,
          ranks[i % ranks.length], String(i + 1), plon, plat, zoneIds[i % zoneIds.length]!]);
      personnelCount += res.rowCount ?? 0;
    }
    console.log(JSON.stringify({ personnel: personnelCount, seed: 'ops demo listo' }));
  } finally {
    await client.end();
  }
}

main().catch((err) => {
  console.error(err instanceof Error ? err.message : err);
  process.exit(1);
});
