import { describe, expect, it } from 'vitest';
import {
  assertCoordinate, clusterCellDegrees, CUBA_BBOX, maskDistance, parseBBox, precisionForGranularity, resolveRadius,
} from '../../src/lib/geo.js';

describe('validación de coordenadas', () => {
  it('acepta coordenadas dentro del territorio', () => {
    expect(() => assertCoordinate(22.4, -79.95, CUBA_BBOX)).not.toThrow();
  });
  it('detecta latitud/longitud intercambiadas', () => {
    expect(() => assertCoordinate(-79.95, 22.4, CUBA_BBOX)).toThrow(/intercambiadas/);
  });
  it('rechaza NaN, infinitos y fuera de rango', () => {
    expect(() => assertCoordinate(Number.NaN, -79, CUBA_BBOX)).toThrow();
    expect(() => assertCoordinate(95, -79, CUBA_BBOX)).toThrow();
    expect(() => assertCoordinate(40.4, -3.7, CUBA_BBOX)).toThrow(/fuera/);
  });
});

describe('bbox', () => {
  it('parsea y recorta a Cuba', () => {
    expect(parseBBox('-90,10,-70,30')).toEqual(CUBA_BBOX);
  });
  it('rechaza formatos incoherentes', () => {
    expect(() => parseBBox('1,2,3')).toThrow();
    expect(() => parseBBox('-79,23,-80,22')).toThrow(/incoherente/);
  });
});

describe('política de radios', () => {
  const policy = { presets: [100, 250, 500, 1000, 2000, 5000], maxCustom: 10000, canCustom: false };
  it('acepta radios predefinidos', () => expect(resolveRadius(500, policy)).toBe(500));
  it('rechaza radio personalizado sin permiso', () => expect(() => resolveRadius(750, policy)).toThrow(/no autorizado/));
  it('limita el radio personalizado', () => {
    expect(resolveRadius(750.4, { ...policy, canCustom: true })).toBe(750);
    expect(() => resolveRadius(20000, { ...policy, canCustom: true })).toThrow(/máximo/);
  });
  it('rechaza radios no positivos', () => expect(() => resolveRadius(0, policy)).toThrow());
});

describe('privacidad y agrupación', () => {
  it('redondea distancias sin permiso exacto', () => {
    expect(maskDistance(123, false)).toBe(100);
    expect(maskDistance(10, false)).toBe(50);
    expect(maskDistance(123.4, true)).toBe(123);
  });
  it('celda de agrupación decrece con el zoom', () => {
    expect(clusterCellDegrees(10)).toBeGreaterThan(clusterCellDegrees(14));
    expect(clusterCellDegrees(0)).toBe(90);
  });
  it('precisión sugerida según granularidad', () => {
    expect(precisionForGranularity('dwelling')).toBe('high');
    expect(precisionForGranularity('street')).toBe('approximate');
    expect(precisionForGranularity('locality')).toBe('general_area');
    expect(precisionForGranularity('x')).toBe('unverified');
  });
});
