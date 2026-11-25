import { withTransaction, type Db } from '../../db/pool.js';
import type { ImportRow } from './csv-validation.js';

const BATCH = 500;

/**
 * Inserta o actualiza por código (una identidad por persona) y añade la
 * membresía al grupo destino sin eliminar otras. Lotes de 500 filas en
 * transacciones independientes para no bloquear la base de datos.
 */
export async function importRows(db: Db, rows: ImportRow[], groupId: number, userId: string): Promise<number> {
  let done = 0;
  for (let i = 0; i < rows.length; i += BATCH) {
    const batch = rows.slice(i, i + BATCH);
    await withTransaction(db, async (c) => {
      const data = JSON.stringify(batch);
      await c.query(
        `WITH src AS (
           SELECT * FROM jsonb_to_recordset($1::jsonb) AS x(code text, given_names text, family_names text,
             data_source text, phone text, notes text, consent_status text)
         ), up AS (
           INSERT INTO directory.persons (code, given_names, family_names, data_source, phone, notes,
             consent_status, consent_recorded_at, created_by)
           SELECT code, given_names, family_names, data_source, phone, notes,
                  coalesce(consent_status, 'pending'),
                  CASE WHEN consent_status = 'granted' THEN now() END, $3
             FROM src
           ON CONFLICT (code) DO UPDATE SET given_names = EXCLUDED.given_names,
             family_names = EXCLUDED.family_names, data_source = EXCLUDED.data_source,
             phone = coalesce(EXCLUDED.phone, directory.persons.phone),
             notes = coalesce(EXCLUDED.notes, directory.persons.notes)
           RETURNING id
         )
         INSERT INTO directory.person_memberships (person_id, group_id, source, added_by)
         SELECT id, $2, 'import', $3 FROM up
         ON CONFLICT (person_id, group_id) DO NOTHING`,
        [data, groupId, userId],
      );
      await c.query(
        `INSERT INTO geo.person_locations AS pl (person_id, geom, address_text, municipality_id,
           coord_source, precision_level, address_granularity, validation_status, updated_by)
         SELECT p.id, ST_SetSRID(ST_MakePoint(x.lon, x.lat), 4326)::geography, x."address_text",
                x."municipalityId", 'manual_coordinates', coalesce(x.precision_level, 'unverified'),
                'unknown', 'pending', $2
           FROM jsonb_to_recordset($1::jsonb) AS x(code text, lat float8, lon float8, address_text text,
                "municipalityId" int, precision_level text)
           JOIN directory.persons p ON p.code = x.code
          WHERE x.lat IS NOT NULL AND x.lon IS NOT NULL
         ON CONFLICT (person_id) DO UPDATE SET geom = EXCLUDED.geom, address_text = EXCLUDED.address_text,
           municipality_id = EXCLUDED.municipality_id, coord_source = EXCLUDED.coord_source,
           precision_level = EXCLUDED.precision_level, validation_status = 'pending',
           verified_at = NULL, verified_by = NULL, updated_at = now(), updated_by = EXCLUDED.updated_by`,
        [data, userId],
      );
    });
    done += batch.length;
  }
  return done;
}
