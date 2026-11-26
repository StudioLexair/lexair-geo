# VIGÍA · Lexair Geo

**VIGÍA** es la plataforma GIS **offline** para el seguimiento de internos en
pase en la provincia de Villa Clara (Cuba), desarrollada por **Studio Lexair**:
zonas dibujables sobre el mapa, marcadores de pases activos con estilo
configurable, personal de la fuerza cercano con teléfonos, kardex arrastrable
al mapa para fijar residencias exactas y carga de datos desde Oracle 11g.

- Servidor único Ubuntu Server LTS de 8 GB en red local, sin Internet.
- 10–30 puestos cliente: aplicación **Windows** (tres instaladores: Cliente,
  Servidor y TodoEnUno con selección de rol, o ZIP portable)
- **Modo «todo en uno»**: el paquete Windows incluye servidor integrado (PostgreSQL 17 + PostGIS +
  Node + API con el catálogo de Villa Clara precargado) que se levanta solo al abrir VIGÍA —
  ideal para pruebas y máquina de guardia; para la red del unidad, elija «Solo cliente»
  al instalar (o en el asistente inicial del programa) y apunte los clientes al servidor central.
  y **navegador** (Flutter Web), ambos contra la misma API y base de datos.
- **Búsqueda global (Ctrl+K)**: una sola caja que detecta qué es lo escrito —
  identidad (11 dígitos), teléfono, dirección o texto — y busca a la vez
  personas (con corrección de tipeo «¿quisiste decir…?», fonética en español
  que encuentra Judith escrito Yudith, teléfonos y prefijos de carné),
  direcciones con número y con **nombres antiguos de calles**, y zonas del
  mapa; sugerencias en vivo con fotografía, grupos por tipo, filtros, y
  historial con búsquedas fijadas.
- Hasta **500 000 personas** en dos grupos (A: directorio importado, B: registros
  propios), sin duplicar identidades.
- Cartografía local generada desde **OpenStreetMap** (extracto Geofabrik de Cuba).
  Mapa base © OpenStreetMap contributors, licencia ODbL 1.0.
- Sin servicios en la nube, sin CDN, sin Google Maps/Firebase/Supabase y sin
  seguimiento GPS. Las ubicaciones son fijas y cada una registra su origen y precisión.

## Componentes

| Ruta | Componente |
|------|------------|
| `services/api` | API REST `/api/v1` (Node.js 26 LTS, TypeScript, Fastify 5) |
| `services/tile_service` | Servidor de mosaicos PNG desde MBTiles (Node, sin dependencias) |
| `apps/flutter_client` | Cliente Flutter (Windows + Web) |
| `database/migrations` | Esquema PostgreSQL 17 + PostGIS 3.5 (`lexair_geo`) |
| `scripts/maps` | Canalización cartográfica: osm2pgsql → catálogo y mosaicos Mapnik |
| `scripts/*.sh` | Instalación, copia de seguridad, restauración y salud |
| `infrastructure` | Nginx (HTTPS interno), systemd, ajuste PostgreSQL |
| `.github/workflows` | CI, integración con PostGIS, compilaciones Web/Windows y release |

## Inicio rápido (desarrollo)

```bash
# Requisitos: Node 26.13.1, PostgreSQL 17 + PostGIS 3.5, Flutter 3.50.1
createdb lexair_geo && psql -d lexair_geo -c 'CREATE EXTENSION postgis'
cd services/api && npm ci
DATABASE_URL=postgres://usuario:clave@127.0.0.1/lexair_geo npm run migrate
DATABASE_URL=... npm run admin:create -- --username admin      # clave temporal
DATABASE_URL=... npm run seed:synthetic -- --count 10000       # datos SINTÉTICOS
DATABASE_URL=... JWT_SECRET=$(openssl rand -hex 32) npm run dev

cd apps/flutter_client && flutter run -d chrome
```

## Producción

Ver [docs/OFFLINE_INSTALL.md](docs/OFFLINE_INSTALL.md). En resumen:

```bash
sudo ./scripts/install_lexair_geo.sh --server-name geo.internal
```

## Documentación

[Arquitectura](docs/ARCHITECTURE.md) · [Base de datos](docs/DATABASE.md) ·
[API](docs/API.md) · [Datos cartográficos](docs/MAP_DATA.md) ·
[Instalación offline](docs/OFFLINE_INSTALL.md) · [Compilación Windows](docs/WINDOWS_BUILD.md) ·
[Navegadores](docs/BROWSER_COMPATIBILITY.md) · [Seguridad](docs/SECURITY.md) ·
[Pruebas y rendimiento](docs/TESTING.md) · [Operación](docs/OPERATIONS.md) ·
[Informes de etapa](docs/STAGE_REPORTS.md)

## Datos

El repositorio **no contiene** datos reales de personas, volcados, certificados,
secretos ni archivos cartográficos pesados (`.pbf`, `.mbtiles`). Los datos de
prueba son sintéticos (códigos `SYN-…`, nombres inventados, sin teléfonos).

## Licencia

Código: propietario, Studio Lexair (uso interno). Datos cartográficos derivados de
OpenStreetMap: © OpenStreetMap contributors, disponibles bajo la
[Open Database License](https://opendatacommons.org/licenses/odbl/1-0/).
