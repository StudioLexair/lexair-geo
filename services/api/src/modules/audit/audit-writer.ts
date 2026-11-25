import type { FastifyRequest } from 'fastify';
import type { DbClient } from '../../db/pool.js';

export type AuditEntry = {
  action: string;
  entityType: string;
  entityId?: string | null;
  success?: boolean;
  /** Solo metadatos: nunca contraseñas ni coordenadas. */
  details?: Record<string, unknown>;
};

const FORBIDDEN_KEYS =
  /^(.*pass(word)?.*|.*token.*|.*secret.*|lat|lon|lng|latitude|longitude|coordinates?|geom)$/i;

/** Elimina claves sensibles por si un llamador las incluye por error. */
export function sanitizeDetails(details: Record<string, unknown> = {}): Record<string, unknown> {
  const out: Record<string, unknown> = {};
  for (const [k, v] of Object.entries(details)) {
    if (FORBIDDEN_KEYS.test(k)) continue;
    if (Array.isArray(v)) {
      out[k] = v.filter((x) => typeof x !== 'string' || !FORBIDDEN_KEYS.test(x)).slice(0, 50);
    } else {
      out[k] = v;
    }
  }
  return out;
}

export async function writeAudit(db: DbClient, req: FastifyRequest | null, e: AuditEntry): Promise<void> {
  const user = req?.auth ?? null;
  await db.query(
    `INSERT INTO audit.audit_logs
       (actor_user_id, actor_username, action, entity_type, entity_id, success, ip, details)
     VALUES ($1, $2, $3, $4, $5, $6, $7::inet, $8::jsonb)`,
    [
      user?.id ?? null,
      user?.username ?? (e.details?.['username'] as string | undefined) ?? null,
      e.action,
      e.entityType,
      e.entityId ?? null,
      e.success ?? true,
      req?.ip ?? null,
      JSON.stringify(sanitizeDetails(e.details)),
    ],
  );
}
