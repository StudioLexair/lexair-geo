import type { DbClient } from '../../db/pool.js';
import { likeContains, looksLikePersonCode, normalizeText } from '../../lib/text.js';
import { offsetOf, type Pagination } from '../../lib/pagination.js';
import { PERSON_JOINS, PERSON_SELECT, PERSON_VISIBLE, type PersonRow } from './dto.js';

export type Visibility = { groupIds: number[]; restricted: boolean };

export type SearchFilters = Pagination & {
  q?: string | undefined;
  municipalityId?: number | undefined;
  status: 'active' | 'inactive' | 'all';
  validation?: string | undefined;
  hasLocation?: 'true' | 'false' | undefined;
  onPass?: 'true' | 'false' | undefined;
};

/** Pase activo (vigente, no devuelto ni cancelado) del interno. */
export const ON_PASS_SQL = `EXISTS (SELECT 1 FROM directory.passes ops
   WHERE ops.person_id = p.id AND ops.returned_at IS NULL AND ops.cancelled_at IS NULL
     AND now() >= ops.starts_at AND now() <= ops.ends_at)`;

export const COUNT_CAP = 10_000;

export async function findPersonById(db: DbClient, id: string, v: Visibility): Promise<PersonRow | null> {
  const { rows } = await db.query<PersonRow>(
    `${PERSON_SELECT} ${PERSON_JOINS} WHERE p.id = $3 AND ${PERSON_VISIBLE}`,
    [v.groupIds, v.restricted, id],
  );
  return rows[0] ?? null;
}

/**
 * Búsqueda por nombre, código o dirección. Las tres vías usan índices
 * (UNIQUE en code, GIN trigram en nombre y dirección) y se combinan por id.
 */
export async function searchPersons(
  db: DbClient,
  f: SearchFilters,
  v: Visibility,
): Promise<{ rows: PersonRow[]; total: number }> {
  const params: unknown[] = [v.groupIds, v.restricted];
  const where: string[] = [PERSON_VISIBLE];
  const add = (sql: string, value: unknown) => {
    params.push(value);
    where.push(sql.replaceAll('?', `$${params.length}`));
  };
  let source = '';
  let order = 'p.family_names, p.given_names, p.id';
  let scoreJoin = '';
  const q = f.q?.trim() ?? '';
  if (q.length > 0) {
    const norm = normalizeText(q);
    params.push(norm, likeContains(norm), q.toUpperCase());
    const [n, l, c] = [params.length - 2, params.length - 1, params.length];
    const codeOnly = looksLikePersonCode(q) && norm.length < 3;
    source = `WITH hits AS (
        SELECT id, 2.0::real AS s FROM directory.persons WHERE code = $${c}
        ${looksLikePersonCode(q) && q.length >= 4 ? `UNION ALL
        SELECT id, 1.5::real FROM directory.persons
         WHERE code LIKE $${c} || '%'` : ''}
        ${codeOnly ? '' : `UNION ALL
        SELECT id, similarity(full_name_norm, $${n}) FROM directory.persons
         WHERE length($${n}) >= 2 AND full_name_norm LIKE $${l}
        UNION ALL
        SELECT person_id, similarity(address_norm, $${n}) * 0.8 FROM geo.person_locations
         WHERE length($${n}) >= 3 AND address_norm LIKE $${l}`}
      ), best AS (SELECT id, max(s) AS score FROM hits GROUP BY id)`;
    // JOIN (no subconsulta correlacionada): con miles de coincidencias la
    // subconsulta recorría el CTE por fila (O(n²), medido 140 ms de 157 ms).
    scoreJoin = 'JOIN best ON best.id = p.id';
    order = 'best.score DESC, p.family_names, p.id';
  }
  if (f.status !== 'all') add('p.is_active = ?', f.status === 'active');
  if (f.municipalityId) add('l.municipality_id = ?', f.municipalityId);
  if (f.validation) add('l.validation_status = ?', f.validation);
  if (f.hasLocation) where.push(f.hasLocation === 'true' ? 'l.person_id IS NOT NULL' : 'l.person_id IS NULL');
  if (f.onPass) where.push(f.onPass === 'true' ? ON_PASS_SQL : `NOT ${ON_PASS_SQL}`);

  const whereSql = where.join(' AND ');
  const countSql = `${source} SELECT count(*)::int AS total FROM (SELECT 1 ${PERSON_JOINS} ${scoreJoin}
    WHERE ${whereSql} LIMIT ${COUNT_CAP}) t`;
  const countParams = [...params];
  params.push(f.pageSize, offsetOf(f));
  const sql = `${source}
    ${PERSON_SELECT}
    ${PERSON_JOINS}
    ${scoreJoin}
    WHERE ${whereSql}
    ORDER BY ${order}
    LIMIT $${params.length - 1} OFFSET $${params.length}`;
  const { rows } = await db.query<PersonRow>(sql, params);
  // Conteo acotado: nunca recorre los 500.000 registros solo para paginar.
  let total = offsetOf(f) + rows.length;
  if (rows.length === f.pageSize || (rows.length === 0 && f.page > 1)) {
    const c = await db.query<{ total: number }>(countSql, countParams);
    total = c.rows[0]?.total ?? total;
  }
  return { rows, total };
}

export async function setMemberships(
  db: DbClient,
  personId: string,
  groupIds: number[],
  userId: string | null,
  source: 'manual' | 'import' = 'manual',
): Promise<void> {
  await db.query(
    'DELETE FROM directory.person_memberships WHERE person_id = $1 AND NOT (group_id = ANY($2::smallint[]))',
    [personId, groupIds],
  );
  await db.query(
    `INSERT INTO directory.person_memberships (person_id, group_id, source, added_by)
     SELECT $1, g, $3, $4 FROM unnest($2::smallint[]) AS g
     ON CONFLICT (person_id, group_id) DO NOTHING`,
    [personId, groupIds, source, userId],
  );
}
