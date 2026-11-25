# LEXAIR GEO

Plataforma GIS **offline** de localización fija de personas para la provincia de
Villa Clara (Cuba). Desarrollada por **Studio Lexair**.

- Servidor único Ubuntu Server LTS de 8 GB en red local, sin Internet.
- 10–30 puestos cliente: aplicación **Windows** (instalador offline o ZIP portable)
  y **navegador** (Flutter Web), ambos contra la misma API y base de datos.
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
