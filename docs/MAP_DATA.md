# Datos cartográficos

## Origen y licencia

- Fuente única: **OpenStreetMap**, extracto `cuba-latest.osm.pbf` de Geofabrik
  (<https://download.geofabrik.de/central-america/cuba.html>), verificado con su `.md5`
  y registrado por SHA-256 en el manifiesto.
- Paquete actual: replicación OSM `2026-11-24T21:21:23Z`, PBF sha256
  `f529e92141a159ec50a313bc6952e517379656f6cbcbe10e68cd4fd0edcf4747`.
- Licencia de los datos: **ODbL 1.0**. Atribución obligatoria «© OpenStreetMap
  contributors», visible siempre en el mapa (cliente Windows y web) y en los metadatos
  MBTiles. Los mosaicos renderizados son una obra producida; la base de datos derivada
  (catálogo) se mantiene bajo ODbL y puede entregarse a quien la solicite junto con
  estos scripts, que permiten reproducirla.
- **No se inventan** límites, calles ni direcciones. Lo que no está en OSM no aparece.
  El paquete sintético de pruebas (`services/tile_service/tools/make-synthetic-mbtiles.mjs`)
  se marca `isSynthetic: true` y el cliente muestra el aviso «MAPA SINTÉTICO».

## Estilos disponibles

| Estilo | Estado |
|--------|--------|
| Estándar | Generado desde OSM |
| Oscuro | Generado desde OSM |
| Alto contraste | Generado desde OSM |
| Topográfico | **No disponible**: no hay datos de relieve locales con licencia |
| Satélite | **No disponible**: no hay imágenes con licencia para uso offline |

El manifiesto declara los estilos ausentes en `missingFeatures`; el cliente no los ofrece.

## Canalización (máquina de preparación, NUNCA el servidor de producción)

Requisitos (Debian/Ubuntu): `osm2pgsql` 2.1, `osmium-tool`, `osmcoastline` 2.4,
PostgreSQL + PostGIS, `python3-mapnik` (Mapnik 4), `python3-psycopg2`, fuentes DejaVu.
Probado en un equipo de **2 vCPU y 1,9 GB de RAM**: los pasos están pensados para
memoria reducida (osm2pgsql con `--bbox` y `--slim`).

```bash
W=/opt/dl/mapwork; PREP=postgres://usuario:clave@127.0.0.1/lexair_prep
# 1. Descarga y verificación
curl -fO https://download.geofabrik.de/central-america/cuba-latest.osm.pbf
curl -fO https://download.geofabrik.de/central-america/cuba-latest.osm.pbf.md5
md5sum -c cuba-latest.osm.pbf.md5

# 2. Límite provincial (relación 1923804) y base de preparación
osmium getid -r cuba-latest.osm.pbf r1923804 -o vc_relonly.osm.pbf
osmium export vc_relonly.osm.pbf -o vc_boundary.geojson
createdb lexair_prep && psql -d lexair_prep -c 'CREATE EXTENSION postgis'
#   (cargar vc_boundary.geojson en la tabla vc_boundary(geom geometry(MultiPolygon,4326)))

# 3. Importación con estilo flex propio (≈100 s, pico ≈180 MB)
osm2pgsql -d lexair_prep -O flex -S scripts/maps/osm2pgsql_lexair.lua --slim --cache 250 \
  --bbox -80.79,21.92,-78.79,23.47 cuba-latest.osm.pbf

# 4. Catálogo geográfico (municipios, localidades, calles, viviendas, POI)
psql -d lexair_prep -f scripts/maps/build_geo_catalog.sql
scripts/maps/export_geo_catalog.sh "$PREP" $W/cuba-latest.osm.pbf /opt/dl/catalog-vc

# 5. Línea de costa (polígonos de tierra; 4 s, 397 MB)
osmcoastline -v -e -f -o $W/coast.db -p land -s 4326 cuba-latest.osm.pbf

# 6. Mosaicos raster z6–16 de los tres estilos + manifest.json
scripts/maps/build_map_package.sh "host=127.0.0.1 dbname=lexair_prep user=… password=…" \
  $W/coast.db $W/cuba-latest.osm.pbf /opt/dl/mappkg 6 16 2
```

`RESUME=1` permite continuar un renderizado interrumpido conservando los niveles completos.

### Renderizador

- `scripts/maps/lexair_styles.py` genera el XML Mapnik (EPSG:3857) de cada estilo a
  partir de una paleta: tierra/mar (osmcoastline), usos del suelo, agua, edificios
  (z15+), límites municipales/provinciales, ferrocarril, vías en 8 clases con
  anchura según zoom, nombres de calles (z15+) y de lugares.
- `scripts/maps/render_mbtiles.py` renderiza metamosaicos de 8×8 (2048 px) para que
  las etiquetas no se corten, solo los que intersectan la provincia + 3 km, y guarda
  los PNG deduplicados (esquema MBTiles `map`/`images` + vista `tiles`).

### Resultado medido (2 vCPU)

Paquete `vc-20261125-z16`, generado el 2026-11-25 a partir del extracto Geofabrik de Cuba
(datos hasta 2026-11-24T21:21:23Z, SHA-256 del PBF
`f529e92141a159ec50a313bc6952e517379656f6cbcbe10e68cd4fd0edcf4747`). Límites
[-80.78572, 21.92425, -78.79264, 23.46464], `isSynthetic: false`.

| Estilo | Zoom | Mosaicos | Únicos (deduplicados) | Tamaño | Render completo |
|--------|------|----------|-----------------------|--------|-----------------|
| standard | 6–16 | 90 432 | 41 662 | 132,0 MB | 239 s |
| dark | 6–16 | 90 432 | 41 610 | 129,0 MB | 231 s |
| high_contrast | 6–16 | 90 432 | 40 188 | 132,5 MB | 244 s |

Total ≈ 394 MB. Mosaicos por zoom: 6: 64 · 7: 128 · 8: 128 · 9: 128 · 10: 128 · 11: 320 ·
12: 576 · 13: 1 600 · 14: 4 928 · 15: 17 408 · 16: 65 024. La pasada de z16 (1 016
metamosaicos por estilo, reanudando un paquete z6–15 ya completo) tardó 7 min 57 s
reales en 2 vCPU. Topográfico y satélite no se generan (`missingFeatures`): no hay datos
reales disponibles sin conexión.

Revisión visual: mosaicos de Santa Clara en z13 y z16 en los tres estilos (calles,
nombres, parque Vidal y atribución correctos). Servidos por `tile_service`: ≈ 1 ms por
mosaico, 24–25 KB por PNG, `ETag`/304, RSS del proceso 70 MB.

## Instalación de un paquete en el servidor

El instalador (paso 11) verifica el SHA-256 de cada `.mbtiles` contra el manifiesto,
copia el paquete a `/srv/lexair-geo/maps/<versión>/` y cambia el enlace `current`
de forma atómica. Para actualizar solo los mapas:

```bash
sudo ./scripts/install_lexair_geo.sh --bundle /media/usb/lexair-geo-server-X.Y.Z
# o manualmente: copiar a /srv/lexair-geo/maps/<versión>, ln -sfn … current,
# systemctl restart lexair-geo-tiles
```

Los archivos `.pbf`, `.mbtiles`, `coast.db` y el catálogo **no se versionan en git**
(`.gitignore` y comprobación en CI).
