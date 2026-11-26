import { XMLParser } from 'fast-xml-parser';

/** Una fila del libro de reclusos, ya normalizada. */
export type ReclusoRow = {
  nidentidad: string;
  nombre1: string;
  nombre2: string;
  apellido1: string;
  apellido2: string;
  fecIngresoReal: string;
  unidad: string;
  provincia: string;
  municipio: string;
  consejo: string;
  cdr: string;
  direccion: string;
  expediente: string;
};

export type ParsedWorkbook = {
  sheets: string[];
  sheetUsed: string;
  headers: string[];
  rows: ReclusoRow[];
  skipped: { row: number; reason: string }[];
};

type CellLike = { '@_ss:Index'?: string; Data?: string | { '#text': string } };

const HEADER_ALIASES: Record<string, keyof ReclusoRow> = {
  NIDENTIDAD: 'nidentidad',
  CI: 'nidentidad',
  NOMBRE1: 'nombre1',
  NOMBRE2: 'nombre2',
  APELLIDO1: 'apellido1',
  APELLIDO2: 'apellido2',
  FECINGREAL: 'fecIngresoReal',
  FECINGRESOREAL: 'fecIngresoReal',
  UNIDAD: 'unidad',
  PROVINCIA: 'provincia',
  MUNICIPIO: 'municipio',
  CONSEJO: 'consejo',
  CDR: 'cdr',
  DIRECCION: 'direccion',
  'DIRECCIÓN': 'direccion',
  EXPEDIENTE: 'expediente',
};

/** Hoja preferida: la que lleva dirección; si no existe, la primera con datos. */
function pickSheet(sheets: { name: string; rows: Record<string, string>[]; headers: string[] }[]) {
  const withAddr = sheets.find((s) => s.headers.includes('DIRECCION') || s.headers.includes('DIRECCIÓN'));
  return withAddr ?? sheets.find((s) => s.headers.includes('NIDENTIDAD')) ?? sheets[0];
}

function cellText(c: CellLike): string {
  const d = c?.Data;
  if (d == null) return '';
  return typeof d === 'string' ? d : (d['#text'] ?? '');
}

/** Lee un libro SpreadsheetML 2003 (Excel XML) con las hojas del registro. */
export function parseReclusosXml(xml: string): ParsedWorkbook {
  const parser = new XMLParser({
    ignoreAttributes: false,
    attributeNamePrefix: '@_',
    removeNSPrefix: true,
    parseTagValue: false,
    trimValues: false,
  });
  const doc = parser.parse(xml) as {
    Workbook?: { Worksheet?: unknown };
  };
  let worksheets = doc?.Workbook?.Worksheet;
  if (!worksheets) throw new Error('El XML no es un libro SpreadsheetML (Workbook/Worksheet)');
  if (!Array.isArray(worksheets)) worksheets = [worksheets];

  const sheets = (worksheets as { '@_Name'?: string; WorksheetOptions?: unknown; Table?: unknown }[]).map((ws) => {
    const tables: { Row?: unknown }[] = Array.isArray(ws.Table) ? ws.Table as { Row?: unknown }[] : ws.Table ? [ws.Table as { Row?: unknown }] : [];
    const rowsRaw: CellLike[][] = [];
    for (const t of tables) {
      let rowList = t.Row;
      if (!rowList) continue;
      if (!Array.isArray(rowList)) rowList = [rowList];
      for (const row of rowList as unknown[]) {
        // Cada Row agrupa sus celdas bajo la subclave `Cell` (una o varias);
        // el resto de claves es texto en blanco entre etiquetas.
        const r = (row ?? {}) as { Cell?: unknown };
        const cellList = r.Cell == null ? [] : Array.isArray(r.Cell) ? r.Cell : [r.Cell];
        rowsRaw.push(cellList as CellLike[]);
      }
    }
    const toGrid = () => rowsRaw.map((cells) => {
      const out: string[] = [];
      let idx = 0;
      for (const c of cells) {
        // removeNSPrefix deja el atributo como `@_Index` (y sin él `@_ss:Index`).
        const declared = (c as Record<string, string>)?.['@_Index'] ?? (c as Record<string, string>)?.['@_ss:Index'];
        if (declared) idx = Number(declared) - 1;
        out[idx] = cellText(c);
        idx += 1;
      }
      return out;
    });
    const grid = toGrid();
    // Cabecera: la primera fila que menciona NIDENTIDAD (o la primera con 6+ celdas)
    let headerRow = grid.findIndex((r) => r.some((v) => v?.trim() === 'NIDENTIDAD'));
    if (headerRow < 0) headerRow = 0;
    const headers = (grid[headerRow] ?? []).map((v) => (v ?? '').trim().toUpperCase());
    const rows: Record<string, string>[] = [];
    for (let i = headerRow + 1; i < grid.length; i++) {
      const obj: Record<string, string> = {};
      headers.forEach((h, col) => {
        const v = grid[i]?.[col];
        if (h && v !== undefined) obj[h] = (v ?? '').trim();
      });
      rows.push(obj);
    }
    return { name: ws['@_Name'] ?? 'Hoja', rows, headers: headers.filter((h) => h.length > 0) };
  });

  const chosen = pickSheet(sheets) ?? { name: 'Hoja', rows: [], headers: [] as string[] };
  const skipped: { row: number; reason: string }[] = [];
  const out: ReclusoRow[] = [];
  chosen.rows.forEach((r, i) => {
    const nidentidad = (r['NIDENTIDAD'] ?? '').trim();
    const nombre1 = (r['NOMBRE1'] ?? '').trim();
    const apellido1 = (r['APELLIDO1'] ?? '').trim();
    if (!nidentidad) { skipped.push({ row: i + 1, reason: 'sin NIDENTIDAD' }); return; }
    if (!nidentidad.match(/^[A-Za-z0-9-]{5,32}$/)) { skipped.push({ row: i + 1, reason: 'NIDENTIDAD con formato no válido' }); return; }
    if (!nombre1 || !apellido1) { skipped.push({ row: i + 1, reason: 'sin nombre o sin apellidos' }); return; }
    out.push({
      nidentidad: nidentidad.toUpperCase(),
      nombre1,
      nombre2: (r['NOMBRE2'] ?? '').trim(),
      apellido1,
      apellido2: (r['APELLIDO2'] ?? '').trim(),
      fecIngresoReal: (r['FECINGREAL'] ?? '').trim(),
      unidad: (r['UNIDAD'] ?? '').trim(),
      provincia: (r['PROVINCIA'] ?? '').trim(),
      municipio: (r['MUNICIPIO'] ?? '').trim(),
      consejo: (r['CONSEJO'] ?? '').trim(),
      cdr: (r['CDR'] ?? '').trim(),
      direccion: (r['DIRECCION'] ?? r['DIRECCIÓN'] ?? '').trim(),
      expediente: (r['EXPEDIENTE'] ?? '').trim(),
    });
  });
  return {
    sheets: sheets.map((s) => s.name),
    sheetUsed: chosen.name,
    headers: chosen.headers,
    rows: out,
    skipped,
  };
}

/** Compone la dirección legible a partir de las columnas del registro. */
export function composeAddress(r: ReclusoRow): string | null {
  const parts = [
    r.direccion || null,
    r.consejo ? `CP ${r.consejo}` : null,
    r.cdr ? `CDR ${r.cdr}` : null,
    r.municipio || null,
    r.provincia || 'Villa Clara',
  ].filter(Boolean) as string[];
  const text = parts.join(', ');
  return text.length > 0 ? text.slice(0, 300) : null;
}
