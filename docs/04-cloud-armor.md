# Fase 4 — Cloud Armor: el WAF

> **Objetivo:** crear una política de seguridad de backend con reglas WAF preconfiguradas (OWASP CRS), rate limiting, bloqueo geográfico y una lista de confianza, y adjuntarla al backend service. Esta es la fase donde se aplica tu experiencia de F5 WAAP sobre el equivalente de Google.

---

## 4.1 Crear la política de seguridad

**Ruta:** ☰ → **Network Security** → **Cloud Armor policies** → **Create policy**

| Campo | Valor | Por qué |
|---|---|---|
| **Policy name** | `ca-waap-lab` | |
| **Policy type** | **Backend security policy** | Protege un backend service de un balanceador de aplicaciones. (La otra opción, *Edge*, es para CDN/buckets y filtra antes de la caché.) |
| **Default rule action** | **Allow** | La regla por defecto (prioridad `2147483647`) decide qué pasa con lo que **ninguna** regla matchea. En un portal público el default es *Allow* y se deniega lo malo con reglas específicas. (Una app interna usaría *Deny* por defecto y abriría solo lo permitido — modelo *allowlist*.) |

En el paso de **Apply policy to targets** puedes adjuntarla ahora o al final; la adjuntaremos en 4.7.

Click a través del asistente y **Create**. Luego entra a la política para **Add rule** por cada bloque siguiente.

> **Orden de evaluación:** las reglas se evalúan de **menor a mayor número de prioridad**. La primera que matchea **gana** y detiene la evaluación. 
---

## 4.2 Regla WAF — SQL injection (en modo Preview/Monitoring primero)

**Add rule:**

| Campo | Valor | Por qué |
|---|---|---|
| **Mode** | **Advanced mode** | Permite escribir expresiones en el *rules language*, necesario para las reglas preconfiguradas. |
| **Match** (expresión) | `evaluatePreconfiguredWaf('sqli-v33-stable', {'sensitivity': 1})` | Aplica todas las firmas de SQLi del OWASP CRS 3.3 con **sensibilidad 1** (paranoia level 1): el nivel con **menos falsos positivos**. Es la recomendación de Google para empezar. |
| **Action** | **Deny** | |
| **Deny response code** | **403 (Forbidden)** | Respuesta estándar para "no autorizado por política". |
| **Priority** | `1000` | |
| **Preview only (enforcement)** | Check |  **Modo monitoreo.** En Preview la regla **registra** qué bloquearía pero **no bloquea**. Permite cazar falsos positivos con tráfico real. |

Click **Add**.

**Flujo en un entorno real:** se despliega en Preview → se observan los logs 24–48 h → se afinan excepciones (`opt_out_rule_ids`) → se desmarca Preview para **enforcement**.

---

## 4.3 Resto de reglas WAF preconfiguradas

Se repite **Add rule** (Advanced mode, Action Deny 403, Preview marcado al inicio) para cada firma del OWASP CRS:

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


---

## 4.4 Rate limiting (throttle)

Un WAF no solo filtra por firmas de ataque; también limita abuso de volumen (fuerza bruta en el login, scraping, etc).

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
| **Preview** | Check | |

---

## 4.6 Lista de confianza para la IP de pruebas

Para que el geo-bloqueo y el rate limit no bloqueen mientras se prueba, la IP pública va en una regla *allow*.


**Add rule:**

| Campo | Valor | Por qué |
|---|---|---|
| **Mode** | **Basic mode** | Basta con casar por IP de origen. |
| **Match — Source IP ranges** | `190.x.x.x/32` (tu IP) | |
| **Action** | **Allow** | |
| **Priority** | `1400` | **Después** de las firmas WAF (1000–1070) y **antes** del geo (1500) y del rate limit (2000). El tráfico se sigue inspeccionando, pero no afectan las reglas de volumen ni de país. |

---

## 4.7 Adjuntar la política al backend service

**Ruta:** dentro de `ca-waap-lab` → pestaña **Targets** → **Apply policy to targets** (o desde el backend service → **Edit** → **Security**).

| Campo | Valor |
|---|---|
| **Type** | Backend service |
| **Target** | `bes-juiceshop` |

Click **Add** / **Save**.

---

## 4.8 Aumentar el verbose de logging de Cloud Armor

**Ruta:** backend service `bes-juiceshop` → **Edit** → **Logging** → **Enable** y, en la política Cloud Armor, nivel de log **VERBOSE**.


**Por qué VERBOSE:** incluye en cada log **qué firma concreta** del CRS disparó (ej. `owasp-crs-v030301-id942100-sqli`) y el fragmento que la activó. Es lo que permite explicar un bloqueo y crear la excepción correcta. En modo *NORMAL* solo se vería "sqli-v33-stable".

---

