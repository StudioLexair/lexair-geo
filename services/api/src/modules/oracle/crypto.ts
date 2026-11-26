import { createCipheriv, createDecipheriv, scryptSync } from 'node:crypto';

/**
 * Cifrado de secretos de conectores (contraseña de Oracle). AES-256-GCM con
 * clave derivada del secreto del servidor (ORACLE_ENCRYPTION_KEY o, en su
 * defecto, JWT_SECRET). El texto cifrado se guarda en la base de datos y
 * NUNCA se devuelve al cliente ni se registra en la auditoría.
 * Formato: v1:<iv b64>:<tag b64>:<cipher b64>
 */
export function deriveKey(secret: string): Buffer {
  return scryptSync(secret, 'lexair-geo.oracle.v1', 32);
}

export function encryptSecret(plain: string, key: Buffer): string {
  const iv = Buffer.from(crypto.getRandomValues(new Uint8Array(12)));
  const cipher = createCipheriv('aes-256-gcm', key, iv);
  const ct = Buffer.concat([cipher.update(plain, 'utf8'), cipher.final()]);
  const tag = cipher.getAuthTag();
  return `v1:${iv.toString('base64')}:${tag.toString('base64')}:${ct.toString('base64')}`;
}

export function decryptSecret(stored: string, key: Buffer): string {
  const parts = stored.split(':');
  if (parts.length !== 4 || parts[0] !== 'v1') {
    throw new Error('Formato de secreto no reconocido');
  }
  const iv = Buffer.from(parts[1]!, 'base64');
  const tag = Buffer.from(parts[2]!, 'base64');
  const ct = Buffer.from(parts[3]!, 'base64');
  const decipher = createDecipheriv('aes-256-gcm', key, iv);
  decipher.setAuthTag(tag);
  return Buffer.concat([decipher.update(ct), decipher.final()]).toString('utf8');
}
