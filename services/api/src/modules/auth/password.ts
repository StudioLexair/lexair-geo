import { hash, verify, Algorithm } from '@node-rs/argon2';
import { randomBytes } from 'node:crypto';

/**
 * Argon2id con parámetros recomendados por OWASP (19 MiB, t=2, p=1).
 * Coste de memoria acotado para respetar el presupuesto del API (512 MB).
 */
const OPTIONS = {
  algorithm: Algorithm.Argon2id,
  memoryCost: 19_456,
  timeCost: 2,
  parallelism: 1,
} as const;

export async function hashPassword(plain: string): Promise<string> {
  return hash(plain, OPTIONS);
}

export async function verifyPassword(hashed: string, plain: string): Promise<boolean> {
  try {
    return await verify(hashed, plain);
  } catch {
    return false;
  }
}

/** Hash ficticio para igualar tiempos cuando el usuario no existe. */
let dummyHash: string | null = null;
export async function burnVerifyTime(plain: string): Promise<void> {
  dummyHash ??= await hashPassword(randomBytes(16).toString('hex'));
  await verifyPassword(dummyHash, plain);
}

export type PasswordCheck = { ok: true } | { ok: false; reason: string };

/** Política: ≥12 caracteres, 3 clases, distinta del usuario. */
export function checkPasswordPolicy(password: string, username: string): PasswordCheck {
  if (password.length < 12) return { ok: false, reason: 'Mínimo 12 caracteres' };
  if (password.length > 128) return { ok: false, reason: 'Máximo 128 caracteres' };
  const classes = [/[a-z]/, /[A-Z]/, /\d/, /[^A-Za-z0-9]/].filter((re) => re.test(password)).length;
  if (classes < 3) {
    return { ok: false, reason: 'Use al menos 3 tipos: minúsculas, mayúsculas, números, símbolos' };
  }
  if (password.toLowerCase().includes(username.toLowerCase())) {
    return { ok: false, reason: 'La contraseña no puede contener el nombre de usuario' };
  }
  return { ok: true };
}

/** Contraseña temporal aleatoria (se muestra una sola vez). */
export function generateTemporaryPassword(): string {
  const alphabet = 'ABCDEFGHJKLMNPQRSTUVWXYZabcdefghijkmnpqrstuvwxyz23456789';
  const bytes = randomBytes(18);
  let out = '';
  for (const b of bytes) out += alphabet[b % alphabet.length];
  return `${out.slice(0, 6)}-${out.slice(6, 12)}-${out.slice(12, 18)}!`;
}
