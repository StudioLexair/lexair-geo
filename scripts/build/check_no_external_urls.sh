#!/usr/bin/env bash
# LEXAIR GEO · Falla si la compilación web cargaría recursos externos en tiempo de
# ejecución (CDN de CanvasKit, fuentes de Google, mosaicos públicos, servicios en la nube).
# Uso: check_no_external_urls.sh build/web
#
# El motor de Flutter contiene dos URL externas como *valores por defecto*:
#   - gstatic.com (CDN de CanvasKit) en flutter.js / flutter_bootstrap.js; no se usa si
#     la compilación lleva "useLocalCanvasKit":true (--no-web-resources-cdn).
#   - fonts.gstatic.com (Roboto y fuentes de respaldo) en main.dart.js; no se usa si
#     web/flutter_bootstrap.js fija fontFallbackBaseUrl a una ruta local.
# Se comprueban ambas sustituciones de forma explícita; cualquier otra referencia falla.
set -euo pipefail
DIR="${1:?Uso: $0 <directorio build/web>}"
[[ -f "$DIR/index.html" ]] || { echo "No es una compilación web: $DIR" >&2; exit 2; }
[[ -f "$DIR/canvaskit/canvaskit.wasm" ]] || { echo "FALLO: CanvasKit no está empaquetado localmente" >&2; exit 1; }
BOOT="$DIR/flutter_bootstrap.js"
fail=0

grep -q '"useLocalCanvasKit":true' "$BOOT" \
  || { echo "FALLO: falta useLocalCanvasKit=true (compilar con --no-web-resources-cdn)" >&2; fail=1; }
grep -Eq "fontFallbackBaseUrl:[[:space:]]*['\"][^h'\"][^'\"]*['\"]" "$BOOT" \
  || { echo "FALLO: flutter_bootstrap.js no fija fontFallbackBaseUrl a una ruta local" >&2; fail=1; }
grep -q '"family":"NotoSans"' "$DIR/assets/FontManifest.json" \
  || { echo "FALLO: la fuente NotoSans no está empaquetada" >&2; fail=1; }
# Sin familia «Roboto» empaquetada, el motor descarga Roboto al arrancar.
grep -q '"family":"Roboto"' "$DIR/assets/FontManifest.json" \
  || { echo "FALLO: falta la familia Roboto local (el motor la descargaría)" >&2; fail=1; }

# Servicios que nunca deben aparecer.
FORBIDDEN='(fonts\.googleapis\.com|tile\.openstreetmap\.org|maps\.googleapis\.com|firebase(io|app)?\.com|supabase\.(co|in)|unpkg\.com|cdn\.jsdelivr\.net|cdnjs\.cloudflare\.com)'
if grep -rEo "$FORBIDDEN" "$DIR" --include='*.html' --include='*.js' --include='*.mjs' --include='*.json' | sort | uniq -c | grep .; then
  echo "FALLO: referencias a servicios externos no permitidos" >&2; fail=1
fi

# gstatic.com solo se admite como valor por defecto del motor, en sus ficheros.
unexpected=$(grep -rlE 'gstatic\.com' "$DIR" --include='*.html' --include='*.js' --include='*.mjs' --include='*.json' \
  | grep -vE '/(flutter\.js|flutter_bootstrap\.js|main\.dart\.js)$' || true)
if [[ -n "$unexpected" ]]; then
  echo "FALLO: gstatic.com fuera de los ficheros del motor:" >&2; echo "$unexpected" >&2; fail=1
fi

if [[ "$fail" -ne 0 ]]; then exit 1; fi
echo "OK: CanvasKit local, fuentes empaquetadas y sin servicios externos ($DIR)"
