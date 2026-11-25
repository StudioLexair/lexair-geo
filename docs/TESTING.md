# Pruebas y rendimiento

Todo lo que aparece aquí se ha ejecutado y medido de verdad. Lo que todavía no se ha
probado figura como **pendiente** y no se da por bueno.

## Pruebas automáticas

| Componente | Herramienta | Resultado (2026-11-25) |
|---|---|---|
| API: unitarias | Vitest | 36/36 |
| API: integración contra PostgreSQL 17 + PostGIS 3.5 reales, con el rol de mínimos privilegios `lexair_api` | Vitest (`LEXAIR_INTEGRATION=1`) | 60/60 |
| API: estilo y tipos | ESLint (`--max-warnings=0`), `tsc --noEmit` | sin avisos |
| Servidor de mosaicos | `node --test` | 6/6 |
| Cliente Flutter | `flutter analyze` / `flutter test` | sin avisos / 13/13 |
| Scripts de operación | ShellCheck | sin avisos |
| Migraciones 0001–0010 sobre base vacía | `migrate` | aplican sin errores |

Las pruebas de integración cubren:

- Autenticación: bloqueo tras intentos fallidos, cambio obligatorio de la contraseña
  temporal, revocación al cerrar sesión.
- Permisos por rol y grupo (el consultor no ve coordenadas exactas; solo lectura no ve
  el Grupo B).
- Restricciones de base de datos: coordenadas fuera de territorio o intercambiadas,
  códigos duplicados, auditoría de solo inserción, una ubicación fija por persona.
- Distancias geodésicas (±1 %), radios personalizados y redondeo a 50 m.
- Uso del índice GiST.
- Agrupación del mapa en vivo y precalculada, contrastada con recuentos SQL por grupo.
- Geocodificación: número inexistente, alias y ausencia de coordenadas inventadas.
- Importación CSV sin duplicar identidades.
- Exportación CSV auditada.

```bash
cd services/api
npm test                                   # unitarias
LEXAIR_INTEGRATION=1 TEST_DATABASE_URL=postgres://…/lexair_geo_test npx vitest run tests/integration
```

## Rendimiento con 500 000 personas y 30 usuarios simulados

### Entorno de la medición

El entorno es **más pequeño que el servidor objetivo** (8 GB de RAM):

- Debian 13, 2 vCPU Intel Xeon a 2,6 GHz, **1,9 GiB de RAM**.
- PostgreSQL 17.12 con `shared_buffers` de 128 MB (límite del entorno),
  `work_mem` 16 MB, `jit = off`, `random_page_cost` 1,1.
- API Node 26.13.1 con `--max-old-space-size=512`, `DB_POOL_MAX=16` y `LOG_LEVEL=warn`.
- `RATE_LIMIT_PER_MINUTE=100000`: los 30 usuarios simulados comparten la IP
  127.0.0.1 y el límite por defecto (600/min por IP) los habría frenado con 429. En
  producción cada puesto tiene su IP y se mantiene el valor por defecto.
- El generador de carga corre **en la misma máquina** y le quita CPU al API y a
  PostgreSQL.
- Las peticiones van directas al API (`127.0.0.1:3000`), sin Nginx ni TLS.
- Datos: 500 000 personas sintéticas con ubicación (base de 480 MB) y el catálogo real
  de Villa Clara.

### Método

`node dist/cli/load-test.js --users 30 --duration 120` abre 30 sesiones reales con JWT.
Cada usuario lanza la siguiente petición en cuanto recibe la anterior, **sin tiempo de
espera**. Es una carga muy superior a la de 30 personas trabajando: equivale a unos
110 peticiones/s sostenidas.

Mezcla ponderada de escenarios:

| Escenario | Peso | Petición |
|---|---|---|
| proximity | 30 | `/persons/:id/nearby` con radio aleatorio entre 100 m y 5 km |
| search_name | 15 | `/persons?q=<5 primeras letras del nombre>` |
| search_code | 15 | `/persons?q=<código>` |
| map_points | 15 | `/maps/points` en z10 (provincia), z13 (ciudad) o z16 (centro de Santa Clara) |
| person_detail | 10 | `/persons/:id` |
| geocode | 10 | `/geocoding/search` con consultas de calle, parque o localidad |
| group_filter | 5 | `/persons?groups=A\|B\|A,B` |

La memoria del API se muestrea cada 5 s. Los resultados en bruto están en
`docs/results/perf-30vu-500k-2026-11-25*.json`.

### Resultado final (dos ejecuciones de 120 s)

| Escenario | n (ej. 1 / 2) | p50 ms | p95 ms | p99 ms |
|---|---|---|---|---|
| proximity | 3 908 / 4 037 | 326 / 322 | **444 / 454** | 508 / 533 |
| map_points | 1 990 / 2 006 | 164 / 163 | **283 / 285** | 351 / 341 |
| geocode (direcciones) | 1 324 / 1 338 | 108 / 103 | **185 / 177** | 236 / 216 |
| search_code | 2 019 / 2 008 | 78 / 77 | 143 / 140 | 180 / 176 |
| person_detail | 1 233 / 1 337 | 69 / 68 | 125 / 129 | 159 / 159 |
| search_name | 1 972 / 1 950 | 656 / 626 | 948 / 963 | 1 045 / 1 129 |
| group_filter | 678 / 672 | 384 / 390 | 669 / 678 | 777 / 861 |

- Total: 13 124 y 13 348 peticiones (109 y 111 peticiones/s), **0 errores**.
- API: RSS máximo de 134 MB y heap máximo de 39 MB.

| Objetivo | Medido (p95) | Estado |
|---|---|---|
| Consultas geográficas p95 < 500 ms | proximidad 444–454 ms; mapa 283–285 ms | cumplido en este entorno, con poco margen en proximidad |
| Búsqueda de direcciones p95 < 1 s | 177–185 ms | cumplido |

Sin carga, una petición aislada tarda entre 3 y 40 ms (proximidad a 5 km en el centro
de Santa Clara: 33 ms; mapa z16: 9 ms; búsqueda por nombre con 1 736 coincidencias:
70–95 ms). Bajo carga, el tiempo restante es sobre todo cola en las 2 vCPU compartidas
con el generador.

### Cómo se llegó ahí (mediciones intermedias reales)

| Versión | Peticiones/s | Errores | p95 proximidad | p95 mapa | p95 nombre |
|---|---|---|---|---|---|
| Inicial | 6,6 | 78 de 819 (74 en el mapa) | 10 461 ms | 9 769 ms | 5 672 ms |
| KNN en proximidad + agregados del mapa z6–14 | 29,4 | 0 | 1 352 ms | 4 701 ms | 3 489 ms |
| Agregados z6–16 como cota + JOIN en la búsqueda (final) | 109–111 | 0 | 444–454 ms | 283–285 ms | 948–963 ms |

1. **Proximidad.** `ST_DWithin` más recuento recorría todas las personas del radio: más
   de 54 000 a 5 km del centro de Santa Clara, unos 480 ms por consulta. Ahora una
   búsqueda KNN por el índice GiST (`<->`) se detiene en `proximity.max_results` + 1 y
   devuelve página y total en una sola consulta: unos 25 ms.
2. **Mapa.** Agrupar en vivo 500 000 ubicaciones costaba segundos. La vista
   materializada `geo.map_cluster_cells` (0010) guarda recuentos por celda y por
   combinación grupo/visibilidad, así que los permisos se siguen aplicando de forma
   exacta. En zoom ≥ 15 se usa como cota superior para no construir miles de puntos
   que luego se descartarían.
3. **Búsqueda por nombre.** La ordenación por relevancia usaba una subconsulta
   correlacionada sobre el CTE de coincidencias (O(n²): 140 de 157 ms). Ahora es un
   JOIN.
4. **Búsqueda por prefijo de código.** Índice `text_pattern_ops` (0009).

### Limitaciones y pendientes

- **No se ha medido en el servidor objetivo de 8 GB.** Allí PostgreSQL usará
  `shared_buffers` de 2 GB (`infrastructure/postgresql/90-lexair-geo.conf`) y el
  generador de carga correrá en otra máquina. Se espera un resultado mejor, pero hay que
  medirlo: repetir el mismo comando contra `https://geo.internal` tras la instalación.
- Medición sin Nginx/TLS ni red LAN.
- Las agrupaciones del mapa pueden ir hasta `map.cluster_refresh_s` (60 s) más el
  tiempo de refresco (≈ 11 s) por detrás de los cambios. Se indica con
  `pendingChanges`. Los puntos individuales y las búsquedas siempre son en vivo.
- La búsqueda por nombre (sin objetivo explícito) se queda en p95 < 1 s con esta carga
  extrema; los nombres sintéticos comparten prefijos y producen miles de coincidencias.

## Cartografía

Paquete `vc-20261125-z16`: tres estilos, z6–16, 90 432 mosaicos por estilo, ≈ 394 MB.
Las cifras completas y la revisión visual están en
[MAP_DATA.md](MAP_DATA.md#resultado-medido-2-vcpu).

## Pruebas manuales y de navegador

| Prueba | Estado |
|---|---|
| Compilación web de Flutter (`--no-wasm-dry-run`) | pendiente |
| Navegadores actuales (Chromium) | pendiente |
| Firefox 85 (cliente heredado) | pendiente: no se afirma compatibilidad hasta probarlo |
| Instalador de extremo a extremo (dos ejecuciones, idempotencia) | pendiente |
| Copia, restauración y comprobación de salud sobre una instalación | pendiente |
| Compilación Windows e instalador Inno Setup | solo en CI (`build-windows.yml`); pendiente de verificar en Actions |
