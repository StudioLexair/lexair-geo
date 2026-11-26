import type { AuthUser } from '../../types.js';

export type PersonRow = {
  id: string;
  code: string;
  given_names: string;
  family_names: string;
  phone: string | null;
  notes: string | null;
  cdr: string | null;
  defense_zone: string | null;
  is_active: boolean;
  is_synthetic: boolean;
  visibility: string;
  consent_status: string;
  data_source: string;
  retention_until: string | null;
  created_at: Date;
  updated_at: Date;
  groups: string[];
  lat: number | null;
  lon: number | null;
  address_text: string | null;
  precision_level: string | null;
  validation_status: string | null;
  address_granularity: string | null;
  coord_source: string | null;
  loc_updated_at: Date | null;
  municipality_id: number | null;
  municipality: string | null;
  locality: string | null;
  distance_m?: number;
  score?: number;
  total?: number;
};

/** Columnas comunes; $1 debe ser el array de grupos permitidos (smallint[]). */
export const PERSON_SELECT = `
  SELECT p.id, p.code, p.given_names, p.family_names, p.phone, p.notes, p.cdr, p.defense_zone, p.is_active,
         p.is_synthetic, p.visibility, p.consent_status, p.data_source, p.retention_until::text,
         p.created_at, p.updated_at,
         ARRAY(SELECT g.code FROM directory.person_memberships m
                 JOIN directory.person_groups g ON g.id = m.group_id
                WHERE m.person_id = p.id AND m.group_id = ANY($1::smallint[])
                ORDER BY g.code) AS groups,
         ST_Y(l.geom::geometry) AS lat, ST_X(l.geom::geometry) AS lon, l.address_text,
         l.precision_level, l.validation_status, l.address_granularity, l.coord_source,
         l.updated_at AS loc_updated_at, l.municipality_id, mu.name AS municipality,
         lo.name AS locality`;

export const PERSON_JOINS = `
  FROM directory.persons p
  LEFT JOIN geo.person_locations l ON l.person_id = p.id
  LEFT JOIN geo.municipalities mu ON mu.id = l.municipality_id
  LEFT JOIN geo.localities lo ON lo.id = l.locality_id`;

/** Visible si pertenece a algún grupo permitido y respeta la visibilidad. */
export const PERSON_VISIBLE = `
  EXISTS (SELECT 1 FROM directory.person_memberships vm
           WHERE vm.person_id = p.id AND vm.group_id = ANY($1::smallint[]))
  AND (p.visibility = 'normal' OR $2::boolean)`;

export function toPersonDto(r: PersonRow, user: AuthUser) {
  const exact = user.permissions.has('locations.exact.read');
  const location = r.precision_level
    ? {
        precisionLevel: r.precision_level,
        validationStatus: r.validation_status,
        addressGranularity: r.address_granularity,
        coordSource: r.coord_source,
        updatedAt: r.loc_updated_at?.toISOString() ?? null,
        municipalityId: r.municipality_id,
        municipality: r.municipality,
        locality: r.locality,
        exact: exact,
        lat: exact ? r.lat : null,
        lon: exact ? r.lon : null,
        addressText: exact ? r.address_text : null,
      }
    : null;
  return {
    id: r.id,
    code: r.code,
    givenNames: r.given_names,
    familyNames: r.family_names,
    fullName: `${r.given_names} ${r.family_names}`,
    phone: exact ? r.phone : null,
    notes: exact ? r.notes : null,
    cdr: exact ? r.cdr : null,
    defenseZone: exact ? r.defense_zone : null,
    isActive: r.is_active,
    isSynthetic: r.is_synthetic,
    visibility: r.visibility,
    consentStatus: r.consent_status,
    dataSource: r.data_source,
    retentionUntil: r.retention_until,
    groups: r.groups,
    createdAt: r.created_at.toISOString(),
    updatedAt: r.updated_at.toISOString(),
    location,
  };
}

export type PersonDto = ReturnType<typeof toPersonDto>;
