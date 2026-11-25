import { z } from 'zod';

export const MAX_PAGE_SIZE = 200;

export const PaginationQuery = z.object({
  page: z.coerce.number().int().min(1).max(100000).default(1),
  pageSize: z.coerce.number().int().min(1).max(MAX_PAGE_SIZE).default(50),
});

export type Pagination = z.infer<typeof PaginationQuery>;

export function offsetOf(p: Pagination): number {
  return (p.page - 1) * p.pageSize;
}

export type Page<T> = {
  items: T[];
  page: number;
  pageSize: number;
  total: number;
  /** true cuando el total se truncó por el límite de conteo. */
  totalIsCapped: boolean;
};

export function buildPage<T>(items: T[], p: Pagination, total: number, cap?: number): Page<T> {
  const capped = cap !== undefined && total >= cap;
  return { items, page: p.page, pageSize: p.pageSize, total, totalIsCapped: capped };
}

/** Lista separada por comas de grupos ("A,B") validada. */
export const GroupsParam = z
  .string()
  .regex(/^[AB](,[AB])?$/, 'groups debe ser A, B o A,B')
  .transform((s) => Array.from(new Set(s.split(','))) as Array<'A' | 'B'>);
