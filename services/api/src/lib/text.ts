/**
 * Réplica en TypeScript de catalog.normalize_text() para parsear consultas
 * antes de enviarlas a PostgreSQL. Ambas deben producir la misma salida.
 */
export function normalizeText(input: string | null | undefined): string {
  return (input ?? '')
    .normalize('NFD')
    .replace(/[\u0300-\u036f]/g, '')
    .toLowerCase()
    .replace(/[^a-z0-9#/-]+/g, ' ')
    .replace(/\s+/g, ' ')
    .trim();
}

export type ParsedAddressQuery = {
  /** Texto normalizado sin número de vivienda. */
  street: string;
  houseNumber: string | null;
  /** Texto normalizado completo. */
  full: string;
};

/** Palabras tras las cuales un número forma parte del nombre de la vía. */
const STREET_TYPE_WORDS = new Set([
  'calle', 'avenida', 'ave', 'av', 'carretera', 'km', 'kilometro', 'edificio',
  'edif', 'reparto', 'zona', 'bloque', 'callejon', 'calzada', 'entre', 'y',
]);

const NUMBER_PATTERNS = [
  /(?:^|\s)(?:#|no|nro|num|numero|n)\s*(\d{1,5}[a-z]?)(?=\s|$)/,
  /(?:^|\s)#(\d{1,5}[a-z]?)(?=\s|$)/,
];

/** Extrae el número de vivienda ("Martí #45", "calle 5 No. 12"). */
export function parseAddressQuery(raw: string): ParsedAddressQuery {
  const full = normalizeText(raw);
  for (const re of NUMBER_PATTERNS) {
    const m = full.match(re);
    if (m && m[1]) {
      const street = full.replace(m[0], ' ').replace(/\s+/g, ' ').trim();
      return { street, houseNumber: m[1], full };
    }
  }
  // Número final ("independencia 112"), salvo calles numeradas ("calle 5").
  const tail = full.match(/^(.*\D)\s(\d{1,5}[a-z]?)$/);
  if (tail && tail[1] && tail[2]) {
    const words = tail[1].trim().split(' ');
    const last = words[words.length - 1] ?? '';
    if (!STREET_TYPE_WORDS.has(last)) {
      return { street: tail[1].trim(), houseNumber: tail[2], full };
    }
  }
  return { street: full, houseNumber: null, full };
}

/** Escapa comodines LIKE para buscar subcadenas literales. */
export function likeContains(normalized: string): string {
  return `%${normalized.replace(/[\\%_]/g, (c) => `\\${c}`)}%`;
}

/** Código de persona: mayúsculas, dígitos y guiones. */
export function looksLikePersonCode(raw: string): boolean {
  return /^[A-Za-z0-9][A-Za-z0-9-]{2,31}$/.test(raw.trim()) && /\d/.test(raw);
}

export type MunicipalityRef = { id: number; norm: string };

/**
 * Separa un municipio indicado como contexto al principio o al final de la
 * consulta ("marti 12 santa clara", "en remedios calle independencia").
 * Devuelve la consulta restante y el municipio, o null si no hay contexto o
 * si la consulta es solo el nombre del municipio (entonces se busca como lugar).
 */
export function extractMunicipalityContext(
  normalized: string,
  municipalities: MunicipalityRef[],
): { rest: string; municipalityId: number } | null {
  const sorted = [...municipalities].sort((a, b) => b.norm.length - a.norm.length);
  for (const m of sorted) {
    if (!m.norm) continue;
    let rest: string | null = null;
    if (normalized.endsWith(` ${m.norm}`)) rest = normalized.slice(0, -m.norm.length);
    else if (normalized.startsWith(`${m.norm} `)) rest = normalized.slice(m.norm.length);
    if (rest === null) continue;
    rest = rest.trim().replace(/^(en|de)\s+/, '').replace(/\s+(en|de|municipio|mun)$/, '').trim();
    if (rest.length >= 2) return { rest, municipalityId: m.id };
  }
  return null;
}
