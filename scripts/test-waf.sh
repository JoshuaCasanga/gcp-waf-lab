#!/usr/bin/env bash
# Valida que Cloud Armor bloquea las sondas canonicas del OWASP Top 10
# contra TU propio portal de lab. Solo verifica codigos de respuesta (200/403/429).
# Uso:  bash scripts/test-waf.sh https://app.tudominio.com
set -euo pipefail

TARGET="${1:-}"
if [[ -z "$TARGET" ]]; then
  echo "Uso: $0 https://tu-dominio-o-ip-con-guiones.sslip.io" >&2
  exit 1
fi

code() {  # code <descripcion> <param> <valor>
  local desc="$1" param="$2" val="$3"
  local c
  c=$(curl -s -o /dev/null -w "%{http_code}" --get "$TARGET/" --data-urlencode "${param}=${val}" || echo "ERR")
  printf "  %-22s -> %s\n" "$desc" "$c"
}

echo "== 1) Trafico legitimo (esperado 200) =="
printf "  %-22s -> %s\n" "home" "$(curl -s -o /dev/null -w '%{http_code}' "$TARGET/")"
printf "  %-22s -> %s\n" "busqueda valida" "$(curl -s -o /dev/null -w '%{http_code}' "$TARGET/rest/products/search?q=apple")"

echo "== 2) Sondas WAF (esperado 403 en enforcement) =="
# Strings de verificacion estandar, triviales y publicos; unico fin: comprobar el bloqueo.
code "SQLi (tautologia)"   "q"    "' OR 1=1--"
code "XSS (script)"        "x"    "<script>alert(1)</script>"
code "Comilla sola (PL1)" "q"    "'"   # esperado 200: no dispara en sensibilidad 1
code "Path traversal"      "file" "../../../../etc/passwd"
code "Scanner UA (param)"  "test" "() { :; }; echo vuln"   # patron shellshock como firma RCE

echo "== 3) HTTP -> HTTPS (esperado 301) =="
HTTP_TARGET="${TARGET/https:/http:}"
printf "  %-22s -> %s\n" "redirect" "$(curl -s -o /dev/null -w '%{http_code}' "$HTTP_TARGET/")"

echo
echo "Interpretacion:"
echo "  - En PREVIEW las sondas devuelven 200/500 (la app responde) pero el log marca DENY."
echo "  - En ENFORCEMENT deben devolver 403; el trafico legitimo sigue en 200."
echo "  - Revisa la firma que disparo con:"
echo "      gcloud logging read 'resource.type=\"http_load_balancer\" jsonPayload.enforcedSecurityPolicy.outcome=\"DENY\"' \\"
echo "        --limit=10 --format='table(timestamp,httpRequest.remoteIp,jsonPayload.enforcedSecurityPolicy.preconfiguredExprIds)'"
