import { describe, expect, it } from 'vitest';
import { CUBA_BBOX } from '../../src/lib/geo.js';
import { validateCsv } from '../../src/modules/imports/csv-validation.js';

const munis = new Map([['municipio ficticio', 7]]);

describe('validación CSV', () => {
  it('acepta filas correctas y resuelve municipios normalizados', () => {
    const r = validateCsv('code,given_names,family_names,data_source,municipality\nABC-1,A,B,fuente,MUNICIPIO FICTÍCIO\n',
      munis, CUBA_BBOX);
    expect(r.errors).toEqual([]);
    expect(r.rows[0]?.municipalityId).toBe(7);
  });
  it('detecta columnas obligatorias ausentes', () => {
    const r = validateCsv('code,given_names\nA1B,x\n', munis, CUBA_BBOX);
    expect(r.errors[0]?.errors[0]).toMatch(/Faltan columnas/);
  });
  it('reporta errores por línea', () => {
    const csv = ['code,given_names,family_names,data_source,lat,lon,municipality',
      'OK-1,a,b,fuente,22.4,-79.9,', 'OK-1,a,b,fuente,,,', 'BAD-2,a,b,fuente,22.4,,', 'BAD-3,a,b,fuente,,,Inventado'].join('\n');
    const r = validateCsv(csv, munis, CUBA_BBOX);
    expect(r.rows.map((x) => x.code)).toEqual(['OK-1']);
    expect(r.errors.map((e) => e.line)).toEqual([3, 4, 5]);
  });
  it('maneja CSV ilegible', () => {
    const r = validateCsv('code,given_names\n"sin cerrar', munis, CUBA_BBOX);
    expect(r.errors.length).toBe(1);
  });
});
