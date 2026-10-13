# Fase 4 — Cloud Armor: el WAF

> **Objetivo:** crear una política de seguridad de backend con reglas WAF preconfiguradas (OWASP CRS), rate limiting, bloqueo geográfico y una lista de confianza, y adjuntarla al backend service. Esta es la fase donde se aplica tu experiencia de F5 WAAP sobre el equivalente de Google.
> **Tiempo estimado:** 35 min.

## Mapa mental: Cloud Armor frente a F5

| Concepto | F5 BIG-IP ASM / F5 XC | Cloud Armor |
|---|---|---|
| Contenedor de reglas | *Security Policy* | **Security policy** (tipo *backend*) |
| Firmas de ataque | Attack signatures (ASM) | **Preconfigured WAF rules** (`sqli-v33-stable`, `xss-v33-stable`, …) tomadas del **OWASP CRS 3.3** |
| Sensibilidad | Signature staging / enforcement | **Sensitivity level** = *paranoia level* del CRS (1–4) |
| Excepciones / falsos positivos | Disabling signatures / wildcards | **Rule tuning** (`opt_out_rule_ids`, request field exclusions) |
| Modo observación | Transparent / staging | **Preview mode** por regla |
| Rate limiting | DoS profiles / request throttling | **throttle** / **rate-based ban** |
| Geo / IP | iRules, IP intelligence | `origin.region_code`, `inIpRange()` |

Es el mismo marco mental que ya manejas; cambia la sintaxis.

---

## 4.1 Crear la política de seguridad

**Ruta:** ☰ → **Network Security** → **Cloud Armor policies** → **Create policy**

| Campo | Valor | Por qué |
|---|---|---|
| **Policy name** | `ca-waap-lab` | |
| **Policy type** | **Backend security policy** | Protege un backend service de un balanceador de aplicaciones. (La otra opción, *Edge*, es para CDN/buckets y filtra antes de la caché.) |
| **Default rule action** | **Allow** | La regla por defecto (prioridad `2147483647`) decide qué pasa con lo que **ninguna** regla matchea. En un portal público el default es *Allow* y se niega lo malo con reglas específicas. (Una app interna usaría *Deny* por defecto y abriría solo lo permitido — modelo *allowlist*.) |

En el paso de **Apply policy to targets** puedes adjuntarla ahora o al final; la adjuntaremos en 4.7.

Click a través del asistente y **Create**. Luego entra a la política para **Add rule** por cada bloque siguiente.

> 🧠 **Orden de evaluación:** las reglas se evalúan de **menor a mayor número de prioridad**. La primera que matchea **gana** y detiene la evaluación. Por eso la lista de confianza (4.6) va en prioridad `1400`: **después** de las firmas WAF (para que tu tráfico se siga inspeccionando) y **antes** del geo-bloqueo y el rate limit (para que no te bloqueen al probar).

---

## 4.2 Regla WAF — SQL injection (en modo Preview primero)

**Add rule:**

| Campo | Valor | Por qué |
|---|---|---|
| **Mode** | **Advanced mode** | Permite escribir expresiones en el *rules language*, necesario para las reglas preconfiguradas. |
| **Match** (expresión) | `evaluatePreconfiguredWaf('sqli-v33-stable', {'sensitivity': 1})` | Aplica todas las firmas de SQLi del OWASP CRS 3.3 con **sensibilidad 1** (paranoia level 1): el nivel con **menos falsos positivos**. Es la recomendación de Google para empezar. |
| **Action** | **Deny** | |
| **Deny response code** | **403 (Forbidden)** | Respuesta estándar para "no autorizado por política". |
| **Priority** | `1000` | |
| **Preview only (enforcement)** | ✅ **Marcado** | 🔑 **Modo observación.** En Preview la regla **registra** qué bloquearía pero **no bloquea**. Equivale al *staging* de ASM: permite cazar falsos positivos con tráfico real antes de hacer cumplir. |

Click **Add**.

**Flujo de trabajo profesional:** se despliega en Preview → se observan los logs 24–48 h → se afinan excepciones (`opt_out_rule_ids`) → se desmarca Preview para **enforcement**. En el lab abreviamos: Preview, una ronda de pruebas (Fase 5), y luego enforcement.

---

## 4.3 Resto de reglas WAF preconfiguradas

Repite **Add rule** (Advanced mode, Action Deny 403, Preview marcado al inicio) para cada firma del OWASP CRS:

| Prioridad | Expresión (Match) | Qué cubre |
|---|---|---|
| `1000` | `evaluatePreconfiguredWaf('sqli-v33-stable', {'sensitivity': 1})` | SQL injection |
| `1010` | `evaluatePreconfiguredWaf('xss-v33-stable', {'sensitivity': 1})` | Cross-site scripting |
| `1020` | `evaluatePreconfiguredWaf('lfi-v33-stable', {'sensitivity': 1})` | Local file inclusion / path traversal |
| `1030` | `evaluatePreconfiguredWaf('rce-v33-stable', {'sensitivity': 1})` | Remote command execution |
| `1040` | `evaluatePreconfiguredWaf('rfi-v33-stable', {'sensitivity': 1})` | Remote file inclusion |
| `1050` | `evaluatePreconfiguredWaf('scannerdetection-v33-stable', {'sensitivity': 1})` | Escáneres automáticos (nikto, sqlmap…) |
| `1060` | `evaluatePreconfiguredWaf('protocolattack-v33-stable', {'sensitivity': 1})` | HTTP request smuggling / splitting |
| `1070` | `evaluatePreconfiguredWaf('sessionfixation-v33-stable', {'sensitivity': 1})` | Session fixation |

**Por qué sensibilidad 1 en todas:** cada nivel de paranoia añade firmas más agresivas y más falsos positivos. Nivel 1 da la mejor relación detección/ruido para empezar; subir a 2+ es una decisión de *tuning* posterior y documentada.

> 🔗 Esto es el equivalente directo de activar los *attack signature sets* de ASM por categoría del OWASP Top 10.

---

## 4.4 Rate limiting (throttle)

Un WAF no solo filtra firmas; también limita abuso de volumen (fuerza bruta en el login, scraping).

**Add rule:**

| Campo | Valor | Por qué |
|---|---|---|
| **Mode** | Advanced | |
| **Match** | `true` | Aplica a todo el tráfico que llegó hasta aquí (lo que no bloquearon las reglas WAF ni la lista de confianza). |
| **Action** | **Rate based ban** | Más allá de limitar, **banea** temporalmente al cliente que se pasa del umbral. |
| **Rate limit threshold — Count / Interval** | `100` / `60 s` | 100 req/min por cliente es amplio para un humano, estrecho para un bot. |
| **Enforce on key** | **IP** | Cuenta por IP de origen. (Opciones: *All*, *IP*, *HTTP header*, *XFF IP*…; en producción tras otro proxy usarías *XFF IP*.) |
| **Ban duration** | `300 s` | Tras exceder el umbral, 5 min de bloqueo. |
| **Ban threshold — Count / Interval** | `100` / `60 s` | |
| **Exceed action** | **Deny 429 (Too Many Requests)** | Código correcto para rate limiting. |
| **Priority** | `2000` | Después de las firmas WAF. |
| **Preview** | desmarcado | El rate limit es seguro de aplicar directo. |

Click **Add**.

---

## 4.5 Bloqueo geográfico (ejemplo de regla personalizada)

Demuestra el *rules language*. Como el portal es un lab para Chile, permitimos solo la región CL y denegamos el resto (ajusta a tu gusto; es ilustrativo).

**Add rule:**

| Campo | Valor | Por qué |
|---|---|---|
| **Mode** | Advanced | |
| **Match** | `origin.region_code != 'CL'` | `origin.region_code` usa códigos ISO 3166-1 alpha-2. Denegar lo que **no** sea Chile reduce muchísimo el ruido de botnets globales. |
| **Action** | **Deny 403** | |
| **Priority** | `1500` | Después de las firmas (para que un ataque desde CL igual se registre por firma) y antes del rate limit. |
| **Preview** | ✅ marcado | Geo-bloqueo mal calibrado deja gente fuera; obsérvalo antes de hacerlo cumplir. |

> ⚠️ Si pruebas desde fuera de Chile (o por VPN), esta regla te bloquearía. Por eso va en Preview, y por eso la lista de confianza del siguiente paso (prioridad `1400`) se evalúa antes que esta regla.

---

## 4.6 Lista de confianza para tu IP de pruebas

Para que el geo-bloqueo y el rate limit no te bloqueen mientras pruebas, tu IP pública va en una regla *allow*. La clave es **dónde** la pones en el orden de evaluación.

```bash
curl -s https://ifconfig.me   # anota tu IP pública, ej. 190.x.x.x
```

**Add rule:**

| Campo | Valor | Por qué |
|---|---|---|
| **Mode** | **Basic mode** | Basta con casar por IP de origen. |
| **Match — Source IP ranges** | `190.x.x.x/32` (tu IP) | |
| **Action** | **Allow** | |
| **Priority** | `1400` | 🔑 **Después** de las firmas WAF (1000–1070) y **antes** del geo (1500) y del rate limit (2000). Tu tráfico se sigue inspeccionando, pero no te afectan las reglas de volumen ni de país. |

> ⚠️ **Error de diseño frecuente: poner la allowlist primero (p. ej. prioridad 100).** En Cloud Armor una regla *allow* **termina la evaluación**: todo lo que venga de esa IP se acepta **sin pasar por las firmas WAF**. En este lab se comprobó: con la regla en prioridad 100, una SQLi enviada desde la IP de confianza llegó a la app (HTTP 500) con la regla SQLi ya en enforcement, y el log mostró la regla 100 como `enforcedSecurityPolicy`. En producción, si una IP "confiable" (oficina, proveedor, monitoreo) se ve comprometida, el atacante entra sin inspección. Es el mismo riesgo que marcar una IP como *Never block* en ASM.
>
> Si ya la creaste en 100, muévela (primero crea la nueva, después borra la vieja):
> ```bash
> gcloud compute security-policies rules create 1400 --security-policy=ca-waap-lab \
>   --src-ip-ranges="TU_IP/32" --action=allow \
>   --description="IP de pruebas: exenta de geo y rate limit, inspeccionada por WAF"
> gcloud compute security-policies rules delete 100 --security-policy=ca-waap-lab
> ```

> 🔗 Equivale a un *allowlist* de IP administrativas en ASM/XC. En producción pondrías aquí los rangos de oficinas o de un bastion, **siempre después de las firmas**.

---

## 4.7 Adjuntar la política al backend service

**Ruta:** dentro de `ca-waap-lab` → pestaña **Targets** → **Apply policy to targets** (o desde el backend service → **Edit** → **Security**).

| Campo | Valor |
|---|---|
| **Type** | Backend service |
| **Target** | `bes-juiceshop` |

Click **Add** / **Save**.

**Por qué aquí y no antes:** la política no hace nada hasta que "protege" un backend service. Es el momento en que Cloud Armor se inserta en el camino **GFE → [Cloud Armor] → backend**.

---

## 4.8 Subir la verbosidad de logging de Cloud Armor

**Ruta:** backend service `bes-juiceshop` → **Edit** → **Logging** → **Enable** y, en la política Cloud Armor, nivel de log **VERBOSE**.

CLI:
```bash
gcloud compute security-policies update ca-waap-lab \
  --log-level=VERBOSE
```

**Por qué VERBOSE:** incluye en cada log **qué firma concreta** del CRS disparó (ej. `owasp-crs-v030301-id942100-sqli`) y el fragmento que la activó. Es lo que te permite, en el trabajo real, explicar un bloqueo y crear la excepción correcta. En modo *NORMAL* solo verías "sqli-v33-stable".

---

## 4.9 Verificación de la configuración

```bash
gcloud compute security-policies describe ca-waap-lab \
  --format="yaml(rules[].priority, rules[].action, rules[].preview, rules[].match.expr.expression)"

gcloud compute backend-services describe bes-juiceshop --global \
  --format="value(securityPolicy)"
# debe devolver .../securityPolicies/ca-waap-lab
```

📸 **Evidencia:** lista de reglas de la política (con prioridades y preview) y la política adjunta al backend → `evidencias/04-armor-rules.png`.

✅ **Checkpoint:** política Cloud Armor con 8 reglas WAF (preview), rate limit activo, geo en preview, tu IP en confianza, política adjunta, logging VERBOSE.

➡️ Siguiente: [Fase 5 — Validación del WAF](05-pruebas.md)
