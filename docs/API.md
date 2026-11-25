# API REST `/api/v1`

Base: `https://geo.internal/api/v1`. JSON UTF-8. Autenticación `Authorization: Bearer <token>`
(JWT ligado a una sesión revocable en `security.sessions`; duración configurable `security.session_hours`, 10 h por defecto).

Errores: `{"error": "CODIGO", "message": "texto", "details": [{"path": "campo", "message": "…"}]}`
con códigos HTTP 400, 401, 403, 404, 409, 413, 422, 429, 500.

## Autenticación

| Método y ruta | Permiso | Descripción |
|---|---|---|
| `POST /auth/login` | — | `{username, password, clientKind}` → `{token, expiresAt, user}`. Límite 10/min por IP; bloqueo temporal tras intentos fallidos. |
| `GET /auth/me` | sesión | Perfil, rol, permisos y grupos visibles |
| `POST /auth/logout` | sesión | Revoca la sesión |
| `POST /auth/change-password` | sesión | Obligatorio si `mustChangePassword`; política ≥ 12 caracteres, 3 clases, sin el usuario |

Mientras `mustChangePassword` sea verdadero, el resto de rutas responden 403.

## Personas, grupos y ubicaciones

| Método y ruta | Permiso |
|---|---|
| `GET /persons?q&groups=A,B&municipalityId&status=active\|inactive\|all&validation&hasLocation&page&pageSize` → `{items, page, pageSize, total, totalIsCapped}` | `persons.read` (+ `groups.a.read`/`groups.b.read`) |
| `POST /persons` | `persons.write` |
| `GET /persons/:id` · `PATCH /persons/:id` | `persons.read` · `persons.write` |
| `POST /persons/:id/deactivate` · `/reactivate` | `persons.write` |
| `PUT /persons/:id/groups` `{groups: ["A","B"]}` | `groups.manage` |
| `PUT /persons/:id/location` · `DELETE …/location` | `locations.write` |
| `POST /persons/:id/location/verify` | `locations.verify` |
| `GET /groups` | `persons.read` |

Visibilidad aplicada en el servidor:

- Sin `locations.exact.read` no se devuelven coordenadas, dirección, teléfono ni
  notas; las distancias se redondean a 50 m.
- Personas marcadas como restringidas solo para roles de rango ≥ 80.
- Cada usuario solo ve los grupos que su rol permite.

## Proximidad y mapa

| Método y ruta | Permiso |
|---|---|
| `GET /proximity/radii` → radios predefinidos (100, 250, 500, 1000, 2000, 5000 m), si el usuario puede usar radio personalizado y su máximo (`proximity.max_custom_radius_m`, 10 km por defecto) | `proximity.query` |
| `GET /persons/:id/nearby?radius=<metros>&groups&page&pageSize` — un radio que no esté predefinido es «personalizado» | `persons.read` + `proximity.query` (+ `proximity.custom`) |

`q` busca a la vez por código exacto, prefijo de código (≥ 4 caracteres, p. ej.
`SYN-00012`), nombre normalizado (sin tildes, trigramas) y dirección; ordena por
relevancia. El total se cuenta solo si hace falta y con tope (`totalIsCapped`).

`nearby` recorre el índice GiST en orden de distancia (KNN, operador `<->`) y se detiene
tras `proximity.max_results` (500) personas visibles, así que el coste no depende de la
densidad de la zona. La distancia es esférica (error < 0,5 % frente al elipsoide) y
`total` está limitado a `proximity.max_results` (`totalIsCapped`).
| `GET /maps/styles` → estilos del manifiesto (estándar, oscuro, alto contraste) | sesión |
| `GET /maps/points?bbox=w,s,e,n&zoom&groups` → `{mode: 'clusters', cellDegrees, items, truncated, aggregatedAt?, pendingChanges?}` o `{mode: 'points', items, truncated}` | `persons.read` |

`/maps/points` agrupa en el servidor por rejilla según zoom (≈ 64 px por celda). Los puntos
individuales solo se envían con zoom ≥ 15, permiso `locations.exact.read` y como máximo
`map.max_points` (2 000) en la vista; si hay más, se vuelve a agrupar.

Para zoom 6–16 las agrupaciones salen de la vista materializada `geo.map_cluster_cells`
(migración 0010), con recuentos por celda y por combinación de grupo/visibilidad, de
modo que el filtrado por permisos es exacto. Se refresca en segundo plano cuando hay
cambios (ajuste `map.cluster_refresh_s`, 60 s por defecto). `aggregatedAt` indica el
último refresco y `pendingChanges: true` que hay altas, bajas o movimientos aún no
reflejados en las agrupaciones. Los puntos individuales siempre se consultan en vivo.

## Geocodificación local

| Método y ruta | Permiso |
|---|---|
| `GET /geocoding/search?q&municipalityId&limit` | `persons.read` |
| `GET /geocoding/reverse?lat&lon` → municipio, localidad y dirección más cercana | `persons.read` |
| `GET /geocoding/municipalities` | `persons.read` |
| `GET/POST/DELETE /geocoding/aliases` | lectura / `geocoding.manage` |
| `GET/POST/DELETE /geocoding/addresses` (direcciones locales añadidas a mano) | `geocoding.manage` |

Cada resultado incluye `kind`, `granularity`, `suggestedPrecision`, `confidence`,
`source` (atribución) e `isSynthetic`. Un municipio al principio o al final de la
consulta («independencia 105 santa clara») se usa como filtro.

## Importación, exportación y administración

| Método y ruta | Permiso |
|---|---|
| `POST /imports/persons?group=A&dryRun=true&filename=` (cuerpo `text/csv`, máx. 20 MB) | `imports.run` |
| `GET /imports` · `GET /imports/:id` (errores por línea) | `imports.run` |
| `GET /exports/persons.csv?groups&municipalityId&includeInactive` (máx. 50 000 filas, auditado, protegido contra inyección de fórmulas) | `exports.run` |
| `GET /admin/dashboard` · `GET /admin/status` | `system.status` |
| `GET /admin/settings` · `PUT /admin/settings/:key` (valor validado por clave) | `settings.manage` |
| `GET /admin/roles` · `PUT /admin/roles/:code/permissions` (solo superadministrador) | `users.manage` |
| `GET/POST/PATCH /users` · `POST /users/:id/reset-password` | `users.manage` |
| `GET /audit?actor&action&entity&from&to&page` | `audit.read` |

## Salud

| Ruta | Descripción |
|---|---|
| `GET /health/live` | Proceso vivo (sin consultar dependencias) |
| `GET /health` | Base de datos, PostGIS, servicio de mosaicos y manifiesto cartográfico |

## Mosaicos (servicio aparte)

`GET /tiles/{estilo}/{z}/{x}/{y}.png` (y `/tiles/{z}/{x}/{y}.png` para el estilo
estándar), `GET /tiles/styles.json`, `GET /tiles/health`. Respuestas con `ETag` y
`Cache-Control`; Nginx añade una caché en disco.
