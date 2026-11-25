# Base de datos `lexair_geo`

PostgreSQL 17 + PostGIS 3.5 + `pg_trgm` + `unaccent`. Migraciones SQL numeradas en
`database/migrations`, aplicadas por `services/api/src/cli/migrate.ts` (registro en
`public.schema_migrations`, cada migración en su propia transacción, idempotentes).

## Esquemas

| Esquema | Contenido |
|---------|-----------|
| `identity` | `users` (Argon2id, `must_change_password`, bloqueo por intentos) |
| `security` | `permissions` (17), `roles` (5, con rango), `role_permissions`, `sessions` (revocables) |
| `directory` | `persons`, `person_groups` (A, B), `person_memberships`, `import_jobs` |
| `geo` | `person_locations`, `municipalities`, `localities`, `addresses`, `street_aliases`, `points_of_interest`, `data_sources` |
| `catalog` | `system_settings` (JSON validado), `normalize_text()` |
| `audit` | `audit_logs` (solo inserción: trigger `audit_logs_append_only`) |

## Personas y grupos: sin duplicar identidades

```
directory.persons (1) ──< directory.person_memberships >── (1) directory.person_groups
        │ id uuid, code único                 (person_id, group_id) PK          code 'A' | 'B'
        │                                     source manual|import|migration
        └──(0..1) geo.person_locations (person_id PK)
```

Una persona que está en A y B es **una** fila en `persons` y **dos** filas en
`person_memberships`. Reimportar a otro grupo añade la membresía sin crear otra
persona (probado en `tests/integration/imports-admin.test.ts`).

## Ubicaciones fijas

`geo.person_locations`:

| Columna | Tipo / restricción |
|---------|--------------------|
| `geom` | `geography(Point,4326)`, índice **GiST**, `CHECK` dentro del rectángulo de Cuba |
| `coord_source` | `manual_coordinates`, `map_pick`, `geocoded_address`, `gps_once`, `admin_correction` |
| `precision_level` | `exact`, `high`, `approximate`, `low`, `unverified` |
| `address_granularity` | `dwelling`, `poi`, `street`, `locality`, `municipality`, `unknown` |
| `validation_status` | `pending`, `verified`, `rejected`; `exact` exige verificación (`exact_requires_verification`) |
| `municipality_id` | calculado por intersección con los límites OSM |

No existe tabla de posiciones históricas ni seguimiento: una persona tiene como
máximo una ubicación fija vigente. `gps_once` documenta una captura puntual
manual, nunca un rastreo.

Consultas de proximidad (ejemplo real del API):

```sql
SELECT p.id, ST_Distance(l.geom, o.geom) AS d
  FROM geo.person_locations l
  JOIN directory.persons p ON p.id = l.person_id
 CROSS JOIN (SELECT geom FROM geo.person_locations WHERE person_id = $1) o
 WHERE ST_DWithin(l.geom, o.geom, $2)      -- usa el índice GiST
   AND p.is_active
 ORDER BY d LIMIT $3;
```

## Catálogo geográfico (OSM)

| Tabla | Filas (Villa Clara, extracto 2026-11-24) | Origen |
|-------|-------|--------|
| `municipalities` | 13 | relaciones `admin_level=6` |
| `localities` | 581 | nodos/áreas `place=*` |
| `addresses` | 4 963 (1 572 viviendas con número + 3 391 tramos de calle) | `addr:*` y calles con nombre |
| `points_of_interest` | 3 926 | `amenity`, `shop`, `leisure`… con nombre |

Cada fila guarda `source_code` → `data_sources` (atribución, licencia, fecha,
`is_synthetic`). Las búsquedas usan `catalog.normalize_text()` (minúsculas, sin
tildes) e índices GIN trigram. **No se inventan coordenadas**: si no hay
coincidencia, el geocodificador devuelve lista vacía; si el número de casa no
existe, devuelve la calle con granularidad `street` y lo indica.

## Agregados del mapa (`geo.map_cluster_cells`, migración 0010)

Vista materializada con una fila por (nivel de zoom 6–16, celda de rejilla, combinación
de flags): bit 1 = Grupo A, bit 2 = Grupo B, bit 4 = visibilidad restringida. Guarda
`n`, `sum_lat` y `sum_lon`, de modo que el API compone el centroide y filtra por los
grupos y la visibilidad que el usuario puede ver sin tocar las 500 000 filas. Con 500 000
personas: 165 751 filas, 16 MB, refresco completo ≈ 10,7 s en 2 vCPU
(`REFRESH … CONCURRENTLY`, sin bloquear lecturas).

- Triggers de sentencia (`map_clusters_changed`) en `geo.person_locations`,
  `directory.persons` y `directory.person_memberships` marcan
  `geo.map_cluster_state.changed_at`. Su coste es una sola actualización por sentencia,
  también en importaciones masivas.
- `geo.refresh_map_clusters(force boolean)` (`SECURITY DEFINER`, solo `EXECUTE` para
  `lexair_api`) refresca si hay cambios y usa un bloqueo consultivo para no solaparse.
- El API la llama cada `map.cluster_refresh_s` segundos (60 por defecto).

La migración 0009 añade `persons_code_prefix_idx` (`text_pattern_ops`) para las
búsquedas por prefijo de código.

## Roles de base de datos

| Rol | Uso |
|-----|-----|
| `lexair_owner` | Propietario del esquema; migraciones y carga de catálogo |
| `lexair_api` (NOLOGIN) | Privilegios mínimos (`0006`, `0007`): lectura general, escritura solo donde el API escribe; auditoría solo `INSERT`/`SELECT` |
| `lexair_api_login` | Usuario de conexión del API, miembro de `lexair_api` |

## Volumen medido (500 000 personas sintéticas)

Base de desarrollo con 500 000 personas, 500 000 ubicaciones, ~600 000 membresías
(≈60 % A, 30 % B, 10 % ambos) y el catálogo real: **480 MB** en disco
(`pg_database_size`). Generación: 136 s para 498 000 registros en un equipo de 2 vCPU.
