# Arquitectura

## Vista general

```
 Puestos Windows (Flutter)        Navegadores (Flutter Web)
          │  HTTPS (CA interna)            │
          └──────────────┬─────────────────┘
                         ▼
              Nginx :443 (TLS, límites, caché de mosaicos, web estática)
               │ /api/*                 │ /tiles/*              │ /
               ▼                        ▼                       ▼
   lexair-geo-api :3000        lexair-geo-tiles :8081      /opt/lexair-geo/current/web
   (Fastify, pool 16)          (node:sqlite, MBTiles)
               │                        │
               ▼                        ▼
   PostgreSQL 17 + PostGIS      /srv/lexair-geo/maps/current/*.mbtiles
   base lexair_geo              (generados FUERA del servidor)
```

Todo corre en **un único servidor** de 8 GB. No hay Redis, colas, réplicas,
contenedores obligatorios ni Nominatim: PostGIS, `pg_trgm` y `unaccent` cubren
la búsqueda geográfica y de direcciones para 500 000 registros.

### Presupuesto de memoria (8 GB)

| Proceso | Límite | Mecanismo |
|---------|--------|-----------|
| PostgreSQL | `shared_buffers` 2 GB + `work_mem` 16 MB × consultas | `90-lexair-geo.conf` |
| API | 900 MB (heap 512 MB) | `MemoryMax` systemd, `--max-old-space-size` |
| Mosaicos | 400 MB (heap 192 MB) | `MemoryMax` systemd |
| Nginx | ~50 MB + caché en disco 2 GB | `proxy_cache_path` |
| SO + caché de páginas | resto (~4 GB) | `effective_cache_size` 5 GB |

**Docker Compose no se usa en producción**: añade un demonio y capas de red sin
beneficio en un servidor único y dedicado; systemd ofrece aislamiento
(`ProtectSystem`, `NoNewPrivileges`) y límites de memoria con menos consumo.

## Flujo de datos

1. **Cartografía** (máquina de preparación, nunca en producción):
   `cuba-latest.osm.pbf` → osm2pgsql (`--bbox` Villa Clara) → base `lexair_prep` →
   - catálogo geográfico (municipios, localidades, calles, viviendas con número, POI) →
     CSV versionados con manifiesto → `load_geo_catalog.sh` en el servidor;
   - mosaicos raster Mapnik (estándar, oscuro, alto contraste) → MBTiles + `manifest.json`.
2. **Personas**: alta manual, importación CSV (Grupo A/B) o migración. Una persona
   es una sola fila en `directory.persons`; su pertenencia a grupos está en
   `directory.person_memberships` (A, B o ambos).
3. **Ubicación fija**: `geo.person_locations.geom geography(Point,4326)` con índice
   GiST, origen (`coord_source`), precisión, granularidad (vivienda, POI, calle,
   localidad, municipio) y estado de validación. No hay historial de movimientos.
4. **Consultas**: proximidad con `ST_DWithin` sobre `geography` (radios 100 m – 5 km
   o personalizado con permiso), mapa por `bbox` con agrupación en servidor por
   rejilla según zoom, búsqueda por nombre/código y geocodificación local.

## API

Fastify 5 con validación `zod`, JWT de corta duración ligado a sesiones en base de
datos (revocables), permisos granulares por ruta, límites de velocidad y auditoría
de toda operación sensible. Detalle en [API.md](API.md).

## Cliente Flutter

Módulos por funcionalidad (`lib/features/*`) con capas separadas:

- **presentación**: pantallas y widgets (≤ 250 líneas por archivo como objetivo);
- **dominio**: modelos inmutables (`person.dart`, `user_profile.dart`…);
- **datos**: repositorios que llaman a rutas reales del API (`*_repository.dart`).

El mapa usa `flutter_map` con mosaicos del propio servidor y la atribución
«© OpenStreetMap contributors» siempre visible. La configuración (`config.json`)
indica el servidor; en Windows se busca junto al ejecutable o en
`%PROGRAMDATA%\LexairGeo`, en la web se sirve desde el mismo origen.

## Decisiones

| Decisión | Motivo |
|----------|--------|
| Mosaicos raster pre-renderizados (MBTiles) | Cero CPU de render en producción; funciona en navegadores antiguos; tamaño acotado (≈ 394 MB medidos para 3 estilos z6–16 de Villa Clara). |
| Mapnik en preparación, no Planetiler | Planetiler genera vectoriales (requeriría renderizado en cliente/WebGL); Mapnik produce PNG directamente. |
| Catálogo propio en lugar de Nominatim | Nominatim completo exige decenas de GB y procesos de importación pesados; el catálogo de Villa Clara son ~5 000 direcciones + 581 localidades. |
| Agrupación en servidor | 500 000 puntos no pueden enviarse al cliente; el servidor agrupa por celdas según zoom y solo muestra puntos individuales a zoom ≥ 15 con permiso de ubicación exacta. |
| Rol de aplicación con privilegios mínimos | El API conecta como `lexair_api_login` (miembro de `lexair_api`); las migraciones usan `lexair_owner`. Las pruebas de integración usan el mismo esquema de roles. |
