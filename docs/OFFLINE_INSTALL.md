# Instalación offline del servidor

## Requisitos

- Ubuntu Server LTS 22.04, 24.04 o 26.04 (x86-64), **8 GB de RAM**, ≥ 10 GB libres
  (recomendado 40 GB SSD para datos, copias y mapas).
- Acceso root. IP fija en la LAN y un nombre interno (p. ej. `geo.internal`) en el
  DNS local o en el archivo `hosts` de cada puesto.
- Sin Internet: todo llega en el **paquete de servidor**.

## 1. Preparar el paquete (equipo con Internet o CI)

El flujo `release` de GitHub Actions genera `lexair-geo-server-X.Y.Z.tar.gz` (API,
servicio de mosaicos, cliente web, migraciones, scripts, Node.js oficial verificado).
Los **mapas** y el **catálogo** se añaden desde la máquina de preparación
([MAP_DATA.md](MAP_DATA.md)):

```bash
scripts/build/make_server_bundle.sh --version X.Y.Z \
  --node-tar node-v26.13.1-linux-x64.tar.xz --web apps/flutter_client/build/web \
  --maps /opt/dl/mappkg --catalog /opt/dl/catalog-vc \
  --debs ./debs-ubuntu-24.04      # opcional: .deb de postgresql-17, postgis, nginx
```

Para obtener los `.deb` sin instalarlos, en un Ubuntu de la misma versión con Internet:

```bash
mkdir debs && cd debs
apt-get download $(apt-cache depends --recurse --no-recommends --no-suggests \
  --no-conflicts --no-breaks --no-replaces --no-enhances \
  postgresql-17 postgresql-17-postgis-3 nginx-light | grep '^\w' | sort -u)
```

Copie el `.tar.gz` y su `.sha256` al servidor (USB) y verifique:

```bash
sha256sum -c lexair-geo-server-X.Y.Z.tar.gz.sha256
tar xzf lexair-geo-server-X.Y.Z.tar.gz && cd lexair-geo-server-X.Y.Z
```

## 2. Instalar

```bash
sudo ./scripts/install_lexair_geo.sh --server-name geo.internal [--server-ip 192.168.10.10]
```

Los 14 pasos (cada uno idempotente; repetir el comando es seguro):

| # | Paso | Si ya existe |
|---|------|--------------|
| 1 | Comprobaciones: SO, RAM, disco, SHA-256 de todo el paquete | — |
| 2 | Paquetes del sistema desde `debs/` (o `--online`) | se omite |
| 3 | Usuario `lexair`, directorios `/opt/lexair-geo`, `/srv/lexair-geo`, `/etc/lexair-geo` | se conservan |
| 4 | Node.js del paquete en `/opt/lexair-geo/node` | se reutiliza |
| 5 | Ajuste PostgreSQL para la RAM detectada (reinicia solo si cambia) | sin cambios |
| 6 | Base `lexair_geo`, roles `lexair_owner` / `lexair_api_login`, extensiones | secretos conservados |
| 7 | Versión en `/opt/lexair-geo/releases/X.Y.Z`, enlace `current` atómico (guarda 3) | se reutiliza |
| 8 | `/etc/lexair-geo/api.env` (0640) con `JWT_SECRET` generado localmente | `JWT_SECRET` conservado |
| 9 | Migraciones de esquema | solo las nuevas |
| 10 | CA privada (EC P-384, 10 años) y certificado del servidor (825 días) | renueva < 30 días o si cambian nombre/IP |
| 11 | Mapas: verificación SHA-256 y activación | se conservan |
| 12 | Catálogo geográfico (si la base está vacía o `--reload-catalog`) | se conserva |
| 13 | systemd (`lexair-geo-api`, `lexair-geo-tiles`, `lexair-geo-backup.timer`) y Nginx | se actualizan |
| 14 | Superadministrador inicial (si no hay usuarios) + `healthcheck` | no se crea |

La **contraseña temporal** del superadministrador se muestra **una sola vez** en la
terminal (no se escribe en el registro `/var/log/lexair-geo/install-*.log`) y debe
cambiarse en el primer acceso. No existen contraseñas por defecto.

## 3. Puestos cliente

1. Descargue la CA desde `http://geo.internal/ca/lexair-geo-ca.crt` e instálela como
   «Entidad de certificación raíz de confianza» (Windows: `certutil -addstore Root`,
   o el instalador de LEXAIR GEO con `/CAFILE=`).
2. **Windows**: ejecute `LexairGeo-X.Y.Z-Setup-x64.exe` (sin Internet) o descomprima el ZIP
   portable y cree `config.json` junto al ejecutable. Ver [WINDOWS_BUILD.md](WINDOWS_BUILD.md).
3. **Navegador**: abra `https://geo.internal/`.

## 4. Verificar

```bash
sudo /opt/lexair-geo/current/scripts/healthcheck_lexair_geo.sh --local
```

## Retroceso de versión

```bash
ls /opt/lexair-geo/releases
sudo ln -sfn /opt/lexair-geo/releases/<anterior> /opt/lexair-geo/current
sudo systemctl restart lexair-geo-api lexair-geo-tiles
```

Las migraciones son aditivas; si una versión nueva añadió migraciones, restaure
también la copia de seguridad previa ([OPERATIONS.md](OPERATIONS.md)).
