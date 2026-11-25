import { describe, expect, it } from 'vitest';
import { extractMunicipalityContext, likeContains, looksLikePersonCode, normalizeText, parseAddressQuery } from '../../src/lib/text.js';

describe('normalizeText', () => {
  it('quita tildes, signos y espacios repetidos', () => {
    expect(normalizeText('  Calle Martí,  #45 — Santa Clara ')).toBe('calle marti #45 santa clara');
    expect(normalizeText('ÑAÑEZ')).toBe('nanez');
    expect(normalizeText(null)).toBe('');
  });
});

describe('parseAddressQuery', () => {
  it.each([
    ['Martí #45', 'marti', '45'],
    ['independencia No. 112', 'independencia', '112'],
    ['Calle Gardenia 999', 'calle gardenia', '999'],
    ['calle 5', 'calle 5', null],
    ['Carretera Central km 3', 'carretera central km 3', null],
    ['Parque Vidal', 'parque vidal', null],
  ])('%s → calle "%s", número %s', (raw, street, num) => {
    const r = parseAddressQuery(raw);
    expect(r.street).toBe(street);
    expect(r.houseNumber).toBe(num);
  });
});

describe('utilidades', () => {
  it('escapa comodines LIKE', () => expect(likeContains('50%_a')).toBe('%50\\%\\_a%'));
  it('reconoce códigos de persona', () => {
    expect(looksLikePersonCode('SYN-0000123')).toBe(true);
    expect(looksLikePersonCode('maria')).toBe(false);
  });
});

describe('extractMunicipalityContext', () => {
  const munis = [
    { id: 12, norm: 'santa clara' }, { id: 10, norm: 'remedios' }, { id: 3, norm: 'santo domingo' },
  ];
  it('separa el municipio al final y conserva calle y número', () => {
    expect(extractMunicipalityContext('calle marti 12 santa clara', munis)).toEqual({ rest: 'calle marti 12', municipalityId: 12 });
  });
  it('acepta el municipio al principio y elimina «en»/«de»', () => {
    expect(extractMunicipalityContext('remedios calle independencia', munis)?.municipalityId).toBe(10);
    expect(extractMunicipalityContext('parque vidal en santa clara', munis)).toEqual({ rest: 'parque vidal', municipalityId: 12 });
  });
  it('no separa si la consulta es solo el municipio ni si aparece en medio', () => {
    expect(extractMunicipalityContext('santa clara', munis)).toBeNull();
    expect(extractMunicipalityContext('carretera santa clara manicaragua', munis)).toBeNull();
  });
});

describe('stripGenericStreetWord', () => {
  it('ignora «calle» inicial solo si queda un nombre', async () => {
    const { stripGenericStreetWord } = await import('../../src/modules/geocoding/repo.js');
    expect(stripGenericStreetWord('calle marti')).toBe('marti');
    expect(stripGenericStreetWord('calle c')).toBe('calle c');
    expect(stripGenericStreetWord('calle 5')).toBe('calle 5');
    expect(stripGenericStreetWord('carretera central')).toBe('carretera central');
  });
});
