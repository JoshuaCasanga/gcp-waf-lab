# Fase 5 — Validar que el WAF bloquea (antes/después)

> **Objetivo:** comprobar con evidencia que las reglas de Cloud Armor detectan y bloquean las sondas canónicas del OWASP Top 10 contra **tu propio** portal de lab, y leer en los logs qué firma disparó.
> **Tiempo estimado:** 30 min.
> **Alcance ético:** todo esto se ejecuta exclusivamente contra el balanceador de **tu** proyecto. Las cadenas usadas son los *test strings* públicos y triviales que la propia documentación de WAF usa para verificación; su único fin aquí es confirmar que la respuesta es `403`.

Las pruebas se corren desde **Cloud Shell** con el script [`scripts/test-waf.sh`](../scripts/test-waf.sh), que automatiza lo de abajo y arma una tabla de resultados.

```bash
export TARGET="https://app.tudominio.com"
bash scripts/test-waf.sh "$TARGET"
```

---

## 5.1 Línea base (tráfico legítimo debe pasar)

```bash
curl -s -o /dev/null -w "home: %{http_code}\n"            "$TARGET/"
curl -s -o /dev/null -w "catalogo: %{http_code}\n"        "$TARGET/rest/products/search?q=apple"
```
**Esperado:** `200`. Si esto diera 403, habría un falso positivo que afinar antes de seguir.

---

## 5.2 Demostración "antes" (reglas en Preview)

Con las reglas WAF aún en **Preview**, lanza las sondas canónicas. En Preview **no se bloquea**: la app responde pero el log marca que *se habría* bloqueado.

| Sonda (string de verificación estándar) | Cómo se envía | Resultado en Preview |
|---|---|---|
| Tautología SQL en parámetro de búsqueda | `GET /rest/products/search?q=' OR 1=1--` | `200/500` de la app + log `previewSecurityPolicy` con `sqli-v33-stable` |
| Etiqueta de script trivial | `GET /?x=<script>alert(1)</script>` | `200` + log `xss-v33-stable` |
| Secuencia de salto de directorio | `GET /?file=../../../../etc/passwd` | `200` + log `lfi-v33-stable` |

```bash
curl -s -o /dev/null -w "%{http_code}\n" --get "$TARGET/rest/products/search" --data-urlencode "q=' OR 1=1--"
```

> 🧠 **Por qué no basta una comilla sola:** en **sensibilidad 1** (paranoia level 1 del CRS) las firmas SQLi necesitan una estructura SQL reconocible (la detección principal, `942100`, usa *libinjection*). Las firmas que reaccionan a caracteres sueltos como `'` (`942110`, `942430`…) son de nivel 2 o superior. Una petición `?q='` **pasa sin coincidencia** en nivel 1: es el equilibrio cobertura / falsos positivos, igual que la *accuracy* de las firmas en ASM. Documéntalo en el README como hallazgo.

**Lee el log del intento** (Cloud Logging):
```bash
gcloud logging read '
  resource.type="http_load_balancer"
  jsonPayload.previewSecurityPolicy.outcome="DENY"
' --limit=5 --format="table(
    timestamp,
    httpRequest.requestUrl,
    jsonPayload.previewSecurityPolicy.priority,
    jsonPayload.previewSecurityPolicy.preconfiguredExprIds,
    jsonPayload.enforcedSecurityPolicy.outcome)"
```
Cada log trae **dos objetos**:
- `previewSecurityPolicy` → lo que la regla en preview **habría** hecho (`outcome: "DENY"`, con la firma en `preconfiguredExprIds`).
- `enforcedSecurityPolicy` → lo que **realmente** se aplicó (`outcome: "ACCEPT"`, normalmente la regla por defecto).

Esa diferencia es Preview trabajando: **detecta sin cortar**. En Logs Explorer el filtro equivalente es `jsonPayload.previewSecurityPolicy.outcome="DENY"`.

**Ver la entrada completa** (el `--format` puede ocultar `previewSecurityPolicy` si no lo incluyes):
```bash
gcloud logging read '
  resource.type="http_load_balancer"
  httpRequest.requestUrl:"OR+1"
' --limit=1 --freshness=15m --format=json | grep -A12 previewSecurityPolicy
```

Resultado real obtenido en el lab:
```json
"previewSecurityPolicy": {
  "configuredAction": "DENY",
  "matchedFieldName": "q",
  "matchedFieldType": "ARG_VALUES",
  "matchedFieldValue": "' OR 1=1--",
  "name": "ca-waap-lab",
  "outcome": "DENY",
  "preconfiguredExprIds": ["owasp-crs-v030301-id942100-sqli"],
  "preview": true
}
```

| Campo | Significado | Equivalente F5 |
|---|---|---|
| `preconfiguredExprIds` | Firma CRS que disparó | Signature ID |
| `matchedFieldName` / `matchedFieldType` | Dónde estaba el ataque (valor del parámetro `q`) | Contexto de la violación |
| `matchedFieldValue` | Fragmento exacto que activó la firma | Detalle del support ID |
| `preview: true` + `outcome: DENY` | Lo habría bloqueado, pero está en monitoreo | Staging / Transparent |

Los campos `matched*` solo aparecen con logging **VERBOSE** (Fase 4.8). La app respondió `500`: la sonda llegó a Juice Shop y rompió su consulta, lo que confirma que la app es vulnerable y que nada la estaba deteniendo.

> **No confundir con la regla de rate limit.** La regla 2000 tiene `match: true`, así que aparece como `enforcedSecurityPolicy` en casi **todas** las peticiones legítimas (`configuredAction: RATE_BASED_BAN`, `outcome: ACCEPT`, `rateLimitAction.outcome: RATE_LIMIT_THRESHOLD_CONFORM` = bajo el umbral). No es un block activo. Para aislar la prueba, se debe filtrar también por URL: `httpRequest.requestUrl:"/rest/products/search"`.
>


 **Evidencia "antes":** log mostrando la firma detectada en modo preview → `evidencias/05-preview-detect.png`.

---

## 5.3 Pasar a enforcement/blocking

En cada regla WAF (prioridades 1000–1070) **desmarca Preview** y guarda. CLI equivalente:

```bash
for P in 1000 1010 1020 1030 1040 1050 1060 1070; do
  gcloud compute security-policies rules update "$P" \
    --security-policy=ca-waap-lab --no-preview
done
```

---

## 5.4 Demostración "después" (enforcement)

Luego se repiten exactamente las mismas pruebas. Ahora la respuesta debe ser **403** y la app nunca las ve.

```bash
# SQLi canónico -> 403
curl -s -o /dev/null -w "sqli: %{http_code}\n" --get "$TARGET/rest/products/search" --data-urlencode "q=' OR 1=1--"
# XSS canónico -> 403
curl -s -o /dev/null -w "xss:  %{http_code}\n" --get "$TARGET/" --data-urlencode "x=<script>alert(1)</script>"
# Path traversal canónico -> 403
curl -s -o /dev/null -w "lfi:  %{http_code}\n" --get "$TARGET/" --data-urlencode "file=../../../../etc/passwd"
# Tráfico legítimo -> sigue 200
curl -s -o /dev/null -w "ok:   %{http_code}\n" "$TARGET/rest/products/search?q=apple"
```

**Esperado:**
```
sqli: 403
xss:  403
lfi:  403
ok:   200
```

---

## 5.5 Probar el rate limiting

```bash
for i in $(seq 1 130); do
  curl -s -o /dev/null -w "%{http_code}\n" "$TARGET/" &
done | sort | uniq -c
```
Tras ~100 peticiones en el minuto, los códigos pasan de `200` a `429`. Durante los 5 min de ban, incluso una petición normal responde `429`.

---

## 5.6 Leer qué firma disparó (lo más valioso)

```bash
gcloud logging read '
  resource.type="http_load_balancer"
  jsonPayload.enforcedSecurityPolicy.outcome="DENY"
' --limit=10 \
  --format="table(
    timestamp,
    httpRequest.remoteIp,
    jsonPayload.enforcedSecurityPolicy.priority,
    jsonPayload.enforcedSecurityPolicy.preconfiguredExprIds)"
```

La columna `preconfiguredExprIds` muestra el ID exacto del OWASP CRS, p. ej. `owasp-crs-v030301-id942100-sqli`. **Este dato es el puente con tu trabajo:** es el mismo tipo de "support ID / signature ID" que revisas en F5 para decidir si un bloqueo es legítimo o un falso positivo que amerita excepción.

 **Evidencia "después":** terminal con los cuatro resultados (3×403 + 1×200) y la tabla de logs con los IDs de firma → `evidencias/05-enforce-403.png`, `evidencias/05-signature-ids.png`.

---

