import { z } from 'zod';
import { COORD_SOURCES, GRANULARITIES, PRECISION_LEVELS } from '../../lib/geo.js';
import { GroupsParam, PaginationQuery } from '../../lib/pagination.js';

const name = z.string().trim().min(1).max(120);

export const PersonCodeSchema = z
  .string()
  .trim()
  .toUpperCase()
  .regex(/^[A-Z0-9][A-Z0-9-]{2,31}$/, 'Código: 3–32 caracteres A-Z, 0-9 o guion');

export const LocationInput = z.object({
  lat: z.number(),
  lon: z.number(),
  coordSource: z.enum(COORD_SOURCES),
  precisionLevel: z.enum(PRECISION_LEVELS).exclude(['exact_verified']).default('unverified'),
  addressGranularity: z.enum(GRANULARITIES).default('unknown'),
  addressText: z.string().trim().max(300).nullish(),
  municipalityId: z.number().int().positive().nullish(),
  localityId: z.number().int().positive().nullish(),
  geocodeConfidence: z.number().min(0).max(1).nullish(),
});
export type LocationInput = z.infer<typeof LocationInput>;

const groupsArray = z.array(z.enum(['A', 'B'])).min(1).max(2)
  .transform((g) => Array.from(new Set(g)));

export const CreatePersonBody = z.object({
  code: PersonCodeSchema,
  givenNames: name,
  familyNames: name,
  phone: z.string().trim().regex(/^[0-9 +()-]{5,25}$/).nullish(),
  notes: z.string().trim().max(2000).nullish(),
  cdr: z.string().trim().max(120).nullish(),
  defenseZone: z.string().trim().max(120).nullish(),
  groups: groupsArray,
  visibility: z.enum(['normal', 'restricted']).default('normal'),
  consentStatus: z.enum(['granted', 'not_required', 'pending', 'revoked']).default('pending'),
  dataSource: z.string().trim().min(2).max(120),
  retentionUntil: z.iso.date().nullish(),
  location: LocationInput.nullish(),
});
export type CreatePersonBody = z.infer<typeof CreatePersonBody>;

export const UpdatePersonBody = CreatePersonBody.omit({ code: true, groups: true, location: true })
  .partial()
  .refine((o) => Object.keys(o).length > 0, 'Sin cambios');

export const SetGroupsBody = z.object({ groups: groupsArray });

export const SearchPersonsQuery = PaginationQuery.extend({
  q: z.string().trim().max(120).optional(),
  municipalityId: z.coerce.number().int().positive().optional(),
  groups: GroupsParam.optional(),
  status: z.enum(['active', 'inactive', 'all']).default('active'),
  validation: z.enum(['pending', 'validated', 'rejected']).optional(),
  hasLocation: z.enum(['true', 'false']).optional(),
  /** true: solo internos con pase activo; false: solo sin pase activo. */
  onPass: z.enum(['true', 'false']).optional(),
});

export const NearbyQuery = PaginationQuery.extend({
  radius: z.coerce.number().positive().max(100000),
  groups: GroupsParam.optional(),
});

export const VerifyBody = z.object({
  precisionLevel: z.enum(PRECISION_LEVELS).default('exact_verified'),
  status: z.enum(['validated', 'rejected']).default('validated'),
});
