import type { DbClient } from '../../db/pool.js';
import { assertCoordinate, type BBox } from '../../lib/geo.js';
import type { LocationInput } from '../persons/schemas.js';

/**
 * Registra o sustituye la ubicación FIJA de una persona. No se conserva
 * historial de coordenadas (sin trayectorias); la auditoría solo anota el
 * cambio. Si no se indica municipio se deduce del límite OSM cargado.
 */
export async function upsertLocation(
  db: DbClient,
  personId: string,
  input: LocationInput,
  userId: string | null,
  allowed: BBox,
): Promise<void> {
  assertCoordinate(input.lat, input.lon, allowed);
  await db.query(
    `INSERT INTO geo.person_locations AS pl
       (person_id, geom, address_text, municipality_id, locality_id, coord_source,
        precision_level, address_granularity, validation_status, geocode_confidence,
        updated_at, updated_by)
     VALUES ($1, ST_SetSRID(ST_MakePoint($3, $2), 4326)::geography, $4,
        COALESCE($5, (SELECT m.id FROM geo.municipalities m
                       WHERE m.boundary IS NOT NULL
                         AND ST_Contains(m.boundary, ST_SetSRID(ST_MakePoint($3, $2), 4326))
                       LIMIT 1)),
        $6, $7, $8, $9, 'pending', $10, now(), $11)
     ON CONFLICT (person_id) DO UPDATE SET
        geom = EXCLUDED.geom, address_text = EXCLUDED.address_text,
        municipality_id = EXCLUDED.municipality_id, locality_id = EXCLUDED.locality_id,
        coord_source = EXCLUDED.coord_source, precision_level = EXCLUDED.precision_level,
        address_granularity = EXCLUDED.address_granularity, validation_status = 'pending',
        geocode_confidence = EXCLUDED.geocode_confidence, updated_at = now(),
        updated_by = EXCLUDED.updated_by, verified_at = NULL, verified_by = NULL`,
    [
      personId,
      input.lat,
      input.lon,
      input.addressText ?? null,
      input.municipalityId ?? null,
      input.localityId ?? null,
      input.coordSource,
      input.precisionLevel,
      input.addressGranularity,
      input.geocodeConfidence ?? null,
      userId,
    ],
  );
}

export async function verifyLocation(
  db: DbClient,
  personId: string,
  userId: string,
  status: 'validated' | 'rejected',
  precisionLevel: string,
): Promise<boolean> {
  const res = await db.query(
    `UPDATE geo.person_locations
        SET validation_status = $2,
            precision_level = CASE WHEN $2 = 'validated' THEN $3 ELSE 'unverified' END,
            verified_at = now(), verified_by = $4
      WHERE person_id = $1`,
    [personId, status, precisionLevel, userId],
  );
  return (res.rowCount ?? 0) > 0;
}
