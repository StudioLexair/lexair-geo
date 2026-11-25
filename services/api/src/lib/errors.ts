/** Error de dominio con código HTTP y código estable para los clientes. */
export class AppError extends Error {
  constructor(
    public readonly statusCode: number,
    public readonly code: string,
    message: string,
    public readonly details?: unknown,
  ) {
    super(message);
    this.name = 'AppError';
  }
}

export const badRequest = (message: string, details?: unknown) =>
  new AppError(400, 'BAD_REQUEST', message, details);
export const unauthorized = (message = 'Autenticación requerida') =>
  new AppError(401, 'UNAUTHORIZED', message);
export const forbidden = (message = 'Permiso insuficiente') => new AppError(403, 'FORBIDDEN', message);
export const notFound = (message = 'Recurso no encontrado') => new AppError(404, 'NOT_FOUND', message);
export const conflict = (message: string) => new AppError(409, 'CONFLICT', message);

/** Traduce violaciones de restricciones PostgreSQL a errores comprensibles. */
export function fromPgError(err: unknown): AppError | null {
  const e = err as { code?: string; constraint?: string; detail?: string };
  if (!e || typeof e.code !== 'string') return null;
  switch (e.code) {
    case '23505':
      return conflict(`Valor duplicado (${e.constraint ?? 'restricción única'})`);
    case '23503':
      return badRequest(`Referencia inexistente (${e.constraint ?? 'clave foránea'})`);
    case '23514':
      return badRequest(`Dato fuera de las reglas permitidas (${e.constraint ?? 'check'})`);
    case '22P02':
    case '22003':
    case '22007':
      return badRequest('Formato de dato inválido');
    case '57014':
      return new AppError(503, 'QUERY_TIMEOUT', 'La consulta superó el tiempo máximo permitido');
    default:
      return null;
  }
}
