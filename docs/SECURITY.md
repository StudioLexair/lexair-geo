# Seguridad

## Principios

- Funcionamiento 100 % en LAN, sin dependencias externas en tiempo de ejecución
  (comprobado en CI con `scripts/build/check_no_external_urls.sh`).
- Mínimo privilegio en cada capa: roles de aplicación, base de datos y systemd.
- Sin contraseñas por defecto, sin secretos en el repositorio ni en los registros.

## Autenticación

- Contraseñas con **Argon2id** (`@node-rs/argon2`).
- Política: ≥ 12 caracteres, 3 de 4 clases (minúsculas, mayúsculas, dígitos,
  símbolos), sin contener el nombre de usuario. Se aplica igual en servidor y cliente.
- Bloqueo temporal tras intentos fallidos; límite de 10 inicios de sesión por minuto
  e IP (API y Nginx).
- Contraseñas temporales (alta, restablecimiento, superadministrador inicial) con
  cambio obligatorio: hasta cambiarla, el resto de rutas devuelven 403.
- JWT firmado (secreto de 64 caracteres generado en el servidor) que referencia una
  sesión en base de datos: cerrar sesión o desactivar un usuario revoca el acceso
  de inmediato.

## Autorización

17 permisos granulares asignados a 5 roles (configurables por el superadministrador):

| Rol | Rango | Resumen |
|-----|-------|---------|
| superadmin | 100 | Todo, incluido modificar permisos de roles |
| admin | 80 | Administración diaria (no gestiona superadministradores): usuarios, configuración, importación/exportación, auditoría |
| operator (operador) | 60 | Registro y corrección de personas y ubicaciones, proximidad |
| consultant (consultor) | 40 | Consultas y proximidad sin coordenadas exactas (distancias redondeadas a 50 m) |
| readonly (solo lectura) | 20 | Consulta básica de personas (sin Grupo B ni coordenadas) |

Todas las comprobaciones se hacen en el servidor; el cliente solo oculta lo que el
servidor rechazaría. Pruebas en `services/api/tests/integration/*.test.ts`.

## Datos personales

- Coordenadas, dirección, teléfono y notas solo con `locations.exact.read`.
- Personas con visibilidad restringida solo para rango ≥ 80.
- Exportación CSV limitada a 50 000 filas, auditada y protegida contra inyección de
  fórmulas (celdas que empiezan por `=`, `+`, `-`, `@`, tabulador o retorno se prefijan con `'`).
- Auditoría de solo inserción (trigger que impide `UPDATE`/`DELETE`).
- Registros sin datos sensibles: el API registra solo método, ruta **sin** parámetros
  de consulta e IP (nunca cuerpos ni cabeceras de autorización); PostgreSQL usa
  `log_parameter_max_length = 0`.
- Sin seguimiento GPS: una sola ubicación fija por persona, con origen documentado.

## Transporte

- HTTPS interno con **CA privada** creada en el servidor (clave en
  `/etc/lexair-geo/pki/private`, 0600, nunca sale del servidor ni entra en copias).
  `/etc/lexair-geo/pki` es 0750 root; la clave del servidor (0600) tampoco entra en
  copias. Solo el certificado **público** de la CA se copia a
  `/opt/lexair-geo/ca/lexair-geo-ca.crt` para su descarga; cualquier otra ruta `/ca/`
  responde 404.
- TLS 1.2/1.3 (TLS 1.0/1.1 rechazados, comprobado), HSTS, `X-Frame-Options DENY`, `nosniff`, `Referrer-Policy no-referrer`
  y CSP `default-src 'self'` (sin orígenes externos).
- El API y el servicio de mosaicos escuchan solo en `127.0.0.1`; PostgreSQL solo en
  `localhost`.

## Servidor

- Servicios systemd con usuario sin shell (`lexair`), `NoNewPrivileges`,
  `ProtectSystem=strict`, `ProtectHome`, `PrivateTmp` y límites de memoria.
- Secretos en `/etc/lexair-geo/api.env` (0640 root:lexair) y
  `/etc/lexair-geo/db-secrets.env` (0600 root), generados con `openssl rand`.
- Copias de seguridad 0640 (postgres:lexair); contienen datos personales: deben
  guardarse cifradas y fuera del servidor.

## Repositorio y CI

- `.gitignore` excluye `.env`, claves, certificados, volcados, `.pbf`, `.mbtiles`.
- CI falla si se versionan esos archivos o si aparece un patrón de token/clave privada.
- Acciones de GitHub fijadas por SHA; sin secretos en los YAML; releases solo con
  etiqueta `vX.Y.Z` o ejecución manual, como **borrador** en el repositorio privado
  y con el entorno protegido `release`.
- Dependencias con versiones exactas (`--save-exact`, `pubspec.lock`,
  `--enforce-lockfile`); `npm audit --omit=dev` en CI.

## Notificación de vulnerabilidades

Comuníquelas en privado al equipo de Studio Lexair; no abra issues públicos.
