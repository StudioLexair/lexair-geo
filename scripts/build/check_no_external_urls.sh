#!/usr/bin/env bash
# LEXAIR GEO · Falla si la compilación web carga recursos externos en tiempo de ejecución
# (CDN de CanvasKit, fuentes de Google, etc.). Uso: check_no_external_urls.sh build/web
set -euo pipefail
DIR="${1:?Uso: $0 <directorio build/web>}"
[[ -f "$DIR/index.html" ]] || { echo "No es una compilación web: $DIR" >&2; exit 2; }
[[ -f "$DIR/canvaskit/canvaskit.wasm" ]] || { echo "FALLO: CanvasKit no está empaquetado localmente" >&2; exit 1; }
# Hosts que el navegador intentaría contactar. Las URL de documentación dentro de
# comentarios/licencias no se cargan, pero los patrones siguientes sí lo harían.
PATTERN='(gstatic\.com|fonts\.googleapis\.com|fonts\.gstatic\.com|unpkg\.com|cdn\.jsdelivr\.net|cdnjs\.|tile\.openstreetmap\.org|maps\.googleapis\.com|firebase|supabase)'
if grep -rEo "$PATTERN" "$DIR" --include='*.html' --include='*.js' --include='*.json' --include='*.mjs' | sort | uniq -c; then
  # flutter.js contiene la URL del CDN como valor por defecto, pero solo se usa si
  # useLocalCanvasKit es falso: lo verificamos explícitamente.
  if grep -q '"useLocalCanvasKit":true' "$DIR/flutter_bootstrap.js"; then
    echo "AVISO: aparecen URL de CDN como valores por defecto, pero useLocalCanvasKit=true (no se usan)."
    if grep -rEq '(fonts\.googleapis|fonts\.gstatic|tile\.openstreetmap|maps\.googleapis|firebase|supabase)' "$DIR" --include='*.js' --include='*.html'; then
      echo "FALLO: referencias a servicios externos no permitidos" >&2; exit 1
    fi
  else
    echo "FALLO: la compilación usaría el CDN (falta --no-web-resources-cdn)" >&2; exit 1
  fi
fi
echo "OK: sin recursos externos en tiempo de ejecución ($DIR)"
