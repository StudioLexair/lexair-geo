import { badRequest, forbidden } from './errors.js';

export type BBox = { west: number; south: number; east: number; north: number };

/** Envolvente amplia de Cuba (coincide con la restricción SQL). */
export const CUBA_BBOX: BBox = { west: -85.2, south: 19.5, east: -74.0, north: 23.6 };

export const PRECISION_LEVELS = [
  'exact_verified',
  'high',
  'approximate',
  'general_area',
  'unverified',
] as const;
export type PrecisionLevel = (typeof PRECISION_LEVELS)[number];

export const COORD_SOURCES = [
  'manual_coordinates',
  'map_pick',
  'geocoded_address',
  'gps_once',
  'admin_correction',
] as const;

export const GRANULARITIES = ['dwelling', 'poi', 'street', 'locality', 'municipality', 'unknown'] as const;

export function isFiniteCoordinate(lat: number, lon: number): boolean {
  return Number.isFinite(lat) && Number.isFinite(lon) && Math.abs(lat) <= 90 && Math.abs(lon) <= 180;
}

export function insideBBox(lat: number, lon: number, b: BBox): boolean {
  return lon >= b.west && lon <= b.east && lat >= b.south && lat <= b.north;
}

/**
 * Valida una coordenada para el territorio permitido. Detecta el error más
 * frecuente (latitud y longitud intercambiadas) para dar un mensaje útil.
 */
export function assertCoordinate(lat: number, lon: number, allowed: BBox): void {
  if (!isFiniteCoordinate(lat, lon)) throw badRequest('Coordenadas no válidas');
  if (insideBBox(lat, lon, allowed)) return;
  if (isFiniteCoordinate(lon, lat) && insideBBox(lon, lat, allowed)) {
    throw badRequest('Latitud y longitud parecen intercambiadas');
  }
  throw badRequest('La coordenada está fuera del territorio configurado');
}

export function parseBBox(raw: string): BBox {
  const parts = raw.split(',').map((p) => Number(p.trim()));
  if (parts.length !== 4 || parts.some((p) => !Number.isFinite(p))) {
    throw badRequest('bbox debe tener el formato oeste,sur,este,norte');
  }
  const [west, south, east, north] = parts as [number, number, number, number];
  if (west >= east || south >= north) throw badRequest('bbox incoherente');
  // Se recorta a Cuba: nunca se consulta fuera del territorio de datos.
  return {
    west: Math.max(west, CUBA_BBOX.west),
    south: Math.max(south, CUBA_BBOX.south),
    east: Math.min(east, CUBA_BBOX.east),
    north: Math.min(north, CUBA_BBOX.north),
  };
}

export type RadiusPolicy = { presets: number[]; maxCustom: number; canCustom: boolean };

/** Solo radios predefinidos, salvo permiso proximity.custom y límite máximo. */
export function resolveRadius(requested: number, policy: RadiusPolicy): number {
  if (!Number.isFinite(requested) || requested <= 0) throw badRequest('Radio no válido');
  if (policy.presets.includes(requested)) return requested;
  if (!policy.canCustom) throw forbidden('Radio personalizado no autorizado');
  if (requested > policy.maxCustom) {
    throw badRequest(`El radio máximo autorizado es ${policy.maxCustom} m`);
  }
  return Math.round(requested);
}

/** Tamaño de celda (grados) para agrupar puntos ≈ 64 px por celda. */
export function clusterCellDegrees(zoom: number): number {
  const z = Math.min(Math.max(Math.round(zoom), 0), 22);
  return 360 / 2 ** z / 4;
}

/**
 * Sin permiso de ubicación exacta, la distancia se redondea a 50 m para no
 * permitir triangular la vivienda de una persona.
 */
export function maskDistance(distanceM: number, exact: boolean): number {
  if (exact) return Math.round(distanceM);
  return Math.max(50, Math.round(distanceM / 50) * 50);
}

/** Precisión sugerida a partir de la granularidad de la dirección hallada. */
export function precisionForGranularity(g: string): PrecisionLevel {
  switch (g) {
    case 'dwelling':
      return 'high';
    case 'street':
    case 'poi':
      return 'approximate';
    case 'locality':
    case 'municipality':
      return 'general_area';
    default:
      return 'unverified';
  }
}
