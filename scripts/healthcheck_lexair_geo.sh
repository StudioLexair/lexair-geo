#!/usr/bin/env bash
# LEXAIR GEO · Verificación de salud. Código de salida 0 = todo correcto.
# Uso: healthcheck_lexair_geo.sh [--local] [--url https://geo.internal] [--cacert ca.crt] [--json]
#  --local   comprueba también servicios systemd, disco, memoria y copias.
#  --url     servidor a comprobar por HTTPS (por defecto https://127.0.0.1).
#  --cacert  CA para validar el certificado desde otro equipo
#            (por defecto la CA del servidor o su copia pública en /opt/lexair-geo/ca).
set -uo pipefail
URL=""; LOCAL=0; JSON=0; CA=""
while [[ $# -gt 0 ]]; do
  case "$1" in --url) URL="$2"; shift 2 ;; --local) LOCAL=1; shift ;; --json) JSON=1; shift ;;
    --cacert) CA="$2"; shift 2 ;;
    *) echo "Opción desconocida: $1" >&2; exit 2 ;; esac
done
FAIL=0; RESULTS=()
check() { # nombre, estado(ok|warn|fail), detalle
  RESULTS+=("$1|$2|$3")
  [[ "$2" == fail ]] && FAIL=1
  (( JSON )) || printf '%-5s %-22s %s\n' "$( [[ $2 == ok ]] && echo OK || { [[ $2 == warn ]] && echo AVISO || echo FALLO; })" "$1" "$3"
}
if [[ -z "$CA" ]]; then
  for c in /etc/lexair-geo/pki/ca.crt /opt/lexair-geo/ca/lexair-geo-ca.crt; do [[ -r "$c" ]] && { CA="$c"; break; }; done
fi
CURL=(curl -fsS --max-time 5)
[[ -n "$CA" && -r "$CA" ]] && CURL+=(--cacert "$CA")

if (( LOCAL )); then
  for s in postgresql lexair-geo-api lexair-geo-tiles nginx; do
    if systemctl is-active --quiet "$s"; then check "servicio $s" ok activo
    else check "servicio $s" fail "$(systemctl is-active "$s" 2>&1)"; fi
  done
  systemctl is-active --quiet lexair-geo-backup.timer && check "copia programada" ok "timer activo" \
    || check "copia programada" warn "lexair-geo-backup.timer inactivo"
  API=$("${CURL[@]}" http://127.0.0.1:3000/api/v1/health 2>/dev/null) \
    && check "API directa" ok "$(echo "$API" | grep -o '"status":"[a-z]*"' | head -1)" \
    || check "API directa" fail "sin respuesta en 127.0.0.1:3000"
  TILES=$("${CURL[@]}" http://127.0.0.1:8081/health 2>/dev/null) \
    && check "mosaicos directos" ok "$(echo "$TILES" | grep -o '"isSynthetic":[a-z]*' | head -1)" \
    || check "mosaicos directos" fail "sin respuesta en 127.0.0.1:8081"
  ROOT_USE=$(df -P / | awk 'NR==2 {gsub("%","",$5); print $5}')
  (( ROOT_USE < 85 )) && check disco ok "${ROOT_USE}% usado" || check disco "$( ((ROOT_USE<95)) && echo warn || echo fail)" "${ROOT_USE}% usado"
  AVAIL=$(awk '/MemAvailable/ {print int($2/1024)}' /proc/meminfo)
  (( AVAIL > 400 )) && check memoria ok "${AVAIL} MB disponibles" || check memoria warn "${AVAIL} MB disponibles"
  LAST=$(ls -1t /srv/lexair-geo/backups/lexair_geo_*.dump 2>/dev/null | head -1)
  if [[ -z "$LAST" ]]; then check "última copia" warn "ninguna todavía"
  else AGE_H=$(( ($(date +%s) - $(stat -c %Y "$LAST")) / 3600 ))
    (( AGE_H <= 26 )) && check "última copia" ok "$(basename "$LAST") (${AGE_H} h)" \
      || check "última copia" warn "$(basename "$LAST") tiene ${AGE_H} h"; fi
  if [[ -f /etc/lexair-geo/pki/server.crt ]]; then
    END=$(openssl x509 -in /etc/lexair-geo/pki/server.crt -noout -enddate | cut -d= -f2)
    openssl x509 -in /etc/lexair-geo/pki/server.crt -noout -checkend $((30*86400)) >/dev/null \
      && check certificado ok "válido hasta $END" || check certificado warn "caduca pronto: $END"
  fi
fi
[[ -n "$URL" ]] || URL="https://127.0.0.1"

{
  H=$("${CURL[@]}" "$URL/api/v1/health" 2>&1) && check "HTTPS /api/v1/health" ok "$(echo "$H" | grep -o '"status":"[a-z]*"' | head -1)" \
    || check "HTTPS /api/v1/health" fail "$H"
  S=$("${CURL[@]}" "$URL/tiles/styles.json" 2>/dev/null) && check "HTTPS estilos" ok "$(echo "$S" | grep -o '"id":"[a-z_]*"' | tr '\n' ' ')" \
    || check "HTTPS estilos" fail "sin /tiles/styles.json"
  CODE=$("${CURL[@]}" -o /dev/null -w '%{http_code} %{content_type}' "$URL/tiles/standard/10/284/446.png" 2>/dev/null)
  [[ "$CODE" == "200 image/png" ]] && check "HTTPS mosaico" ok "z10/284/446 image/png" || check "HTTPS mosaico" fail "${CODE:-sin respuesta}"
  W=$("${CURL[@]}" -o /dev/null -w '%{http_code}' "$URL/" 2>/dev/null)
  [[ "$W" == 200 ]] && check "cliente web" ok "HTTP 200" || check "cliente web" warn "HTTP ${W:-—} (¿paquete sin web/?)"
}

(( ${#RESULTS[@]} > 0 )) || { FAIL=1; RESULTS+=("verificación|fail|no se ejecutó ninguna comprobación"); }
if (( JSON )); then
  printf '{"ok":%s,"checks":[' "$( ((FAIL)) && echo false || echo true)"
  for i in "${!RESULTS[@]}"; do IFS='|' read -r n s d <<< "${RESULTS[$i]}"
    d=${d//\\/\\\\}; d=${d//\"/\\\"}; printf '%s{"name":"%s","status":"%s","detail":"%s"}' "$( ((i)) && echo ,)" "$n" "$s" "$d"; done
  echo ']}'
fi
exit $FAIL
