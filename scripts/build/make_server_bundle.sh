#!/usr/bin/env bash
# LEXAIR GEO · Construye el paquete de servidor offline (máquina de preparación o CI).
# Resultado: <OUT>/lexair-geo-server-<versión>/ y su .tar.gz, listos para copiar
# al servidor sin Internet y ejecutar scripts/install_lexair_geo.sh.
#
# Uso: make_server_bundle.sh --version 0.1.0 --node-tar node-v26.13.1-linux-x64.tar.xz \
#        [--web apps/flutter_client/build/web] [--maps DIR] [--catalog DIR] [--debs DIR] [--out dist]
# Los mapas y el catálogo son opcionales y NUNCA se versionan en git.
set -Eeuo pipefail
ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
VERSION=""; NODE_TAR=""; WEB=""; MAPS=""; CATALOG=""; DEBS=""; OUT="$ROOT/dist"
while [[ $# -gt 0 ]]; do
  case "$1" in
    --version) VERSION="$2"; shift 2 ;; --node-tar) NODE_TAR="$2"; shift 2 ;;
    --web) WEB="$2"; shift 2 ;; --maps) MAPS="$2"; shift 2 ;; --catalog) CATALOG="$2"; shift 2 ;;
    --debs) DEBS="$2"; shift 2 ;; --out) OUT="$2"; shift 2 ;;
    *) echo "Opción desconocida: $1" >&2; exit 2 ;;
  esac
done
[[ "$VERSION" =~ ^[0-9]+\.[0-9]+\.[0-9]+([.-][A-Za-z0-9.]+)?$ ]] || { echo "--version semver requerido" >&2; exit 2; }
[[ -f "$NODE_TAR" ]] || { echo "--node-tar requerido (tarball oficial linux-x64, verificado)" >&2; exit 2; }
NAME="lexair-geo-server-$VERSION"
B="$OUT/$NAME"
rm -rf "$B"; mkdir -p "$B/node"

echo "· API"
API_TMP=$(mktemp -d)
(cd "$ROOT/services/api" && npm ci --no-audit --no-fund --loglevel=error && npm run build --silent)
cp -a "$ROOT/services/api/package.json" "$ROOT/services/api/package-lock.json" "$ROOT/services/api/dist" "$API_TMP/"
# @node-rs/argon2 trae binarios precompilados por plataforma: no necesita scripts.
(cd "$API_TMP" && npm ci --omit=dev --ignore-scripts --no-audit --no-fund --loglevel=error)
find "$API_TMP/dist" -name '*.map' -delete
mv "$API_TMP" "$B/api"

echo "· Servidor de mosaicos"
mkdir -p "$B/tile_service"
cp -a "$ROOT/services/tile_service/package.json" "$ROOT/services/tile_service/src" "$B/tile_service/"

echo "· Base de datos, infraestructura y scripts"
mkdir -p "$B/database" "$B/scripts/maps"
cp -a "$ROOT/database/migrations" "$B/database/"
cp -a "$ROOT/infrastructure" "$B/"
cp -a "$ROOT"/scripts/*.sh "$B/scripts/"
cp -a "$ROOT/scripts/maps/load_geo_catalog.sh" "$B/scripts/maps/"
cp "$NODE_TAR" "$B/node/"

if [[ -n "$WEB" ]]; then
  [[ -f "$WEB/index.html" ]] || { echo "--web no contiene index.html" >&2; exit 1; }
  echo "· Cliente web"; cp -a "$WEB" "$B/web"; rm -f "$B/web/config.json"
fi
if [[ -n "$MAPS" ]]; then
  [[ -f "$MAPS/manifest.json" ]] || { echo "--maps sin manifest.json" >&2; exit 1; }
  echo "· Mapas"; mkdir -p "$B/maps"; cp "$MAPS/manifest.json" "$MAPS"/*.mbtiles "$B/maps/"
fi
if [[ -n "$CATALOG" ]]; then
  [[ -f "$CATALOG/catalog.json" ]] || { echo "--catalog sin catalog.json" >&2; exit 1; }
  echo "· Catálogo geográfico"; cp -a "$CATALOG" "$B/catalog"
fi
if [[ -n "$DEBS" ]]; then echo "· Paquetes .deb"; mkdir -p "$B/debs"; cp "$DEBS"/*.deb "$B/debs/"; fi

echo "$VERSION" > "$B/VERSION"
cat > "$B/LEEME.txt" <<TXT
LEXAIR GEO $VERSION — paquete de servidor offline (Studio Lexair)
Instalación (Ubuntu Server LTS, como root):
  sudo ./scripts/install_lexair_geo.sh --server-name geo.internal
Documentación: docs/OFFLINE_INSTALL.md del repositorio.
Datos cartográficos © OpenStreetMap contributors (ODbL 1.0).
TXT
(cd "$B" && find . -type f ! -name SHA256SUMS -print0 | sort -z | xargs -0 sha256sum > SHA256SUMS)
tar -C "$OUT" -czf "$OUT/$NAME.tar.gz" "$NAME"
(cd "$OUT" && sha256sum "$NAME.tar.gz" > "$NAME.tar.gz.sha256")
du -sh "$B" "$OUT/$NAME.tar.gz"
