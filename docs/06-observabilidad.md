# Fase 6 — Observabilidad: dashboard, alertas y logs

> **Objetivo:** convertir los eventos del WAF en algo visible y accionable — un dashboard de Monitoring, una alerta que avise ante un pico de bloqueos, y consultas de log guardadas.
> **Tiempo estimado:** 25 min.

Un WAF sin observabilidad es una caja negra. Esta fase es la que, en una entrevista, demuestra que piensas como operador de seguridad y no solo como instalador.

---

## 6.1 Dashboard de Cloud Armor

**Ruta:** ☰ → **Monitoring** → **Dashboards** → **Create dashboard**. Nombre: `WAAP Lab`. Agrega *widgets* (**Add widget** → *Line* / *Stacked bar*):

| Widget | Métrica | Filtro / agrupación | Qué cuenta |
|---|---|---|---|
| Peticiones permitidas vs. bloqueadas | `loadbalancing.googleapis.com/https/request_count` | agrupar por `response_code_class` | Proporción 2xx / 4xx; un salto de 4xx = ataque o falso positivo. |
| Permitidas vs. bloqueadas por Cloud Armor | Recurso **Network Security Policy** → `networksecurity.googleapis.com/https/request_count` | agrupar por `blocked` | Cuánto tráfico frena el WAF frente a lo que deja pasar. |
| Coincidencias en preview | Recurso **Network Security Policy** → *Previewed Requests count* | agrupar por `blocked` | Qué **bloquearía** una regla antes de pasarla a enforcement. |
| Bloqueos por regla | `logging.googleapis.com/user/armor_denies_by_rule` (métrica basada en logs, ver abajo) | agrupar por `priority` | Qué regla bloquea más. |
| Latencia backend (p50/p95) | `https/backend_latencies` | percentiles 50 y 95 | Que el WAF no degrade la experiencia. |
| Salud del backend | `https/backend_request_count` por `backend_target` | | Las VMs reciben tráfico y responden. |

**Por qué estos widgets:** cuentan la historia completa — *llega tráfico → el WAF filtra → el backend responde rápido → está sano*.

> ⚠️ **Las métricas nativas de Cloud Armor no tienen la prioridad de la regla.** Solo exponen las etiquetas `blocked` (permitida/bloqueada) y `backend_target_name`, agregadas por política. Para ver **qué regla** bloquea, hay que crear una **métrica basada en logs** que extraiga la prioridad del log del balanceador.

### Métrica basada en logs: bloqueos por regla

**Ruta:** ☰ → **Logging** → **Log-based Metrics** → **Create metric**

| Campo | Valor | Por qué |
|---|---|---|
| **Metric type** | **Counter** | Cuenta entradas de log que cumplen el filtro. |
| **Log-based metric name** | `armor_denies_by_rule` | Queda como `logging.googleapis.com/user/armor_denies_by_rule`. |
| **Build filter** | `resource.type="http_load_balancer"` `jsonPayload.enforcedSecurityPolicy.outcome="DENY"` | Solo bloqueos reales (no preview). |
| **Labels → Add label** | Name `priority`, Type **String**, Field name `jsonPayload.enforcedSecurityPolicy.priority` | Convierte la prioridad del log en una dimensión de la métrica. Esto es lo que permite agrupar por regla. |

Click **Create metric**. Equivalente CLI:

```bash
cat > armor-metric.yaml <<'YAML'
description: Bloqueos de Cloud Armor por prioridad de regla
filter: resource.type="http_load_balancer" AND jsonPayload.enforcedSecurityPolicy.outcome="DENY"
metricDescriptor:
  metricKind: DELTA
  valueType: INT64
  labels:
  - key: priority
    valueType: STRING
labelExtractors:
  priority: EXTRACT(jsonPayload.enforcedSecurityPolicy.priority)
YAML
gcloud logging metrics create armor_denies_by_rule --config-from-file=armor-metric.yaml
```

> 🕐 Una métrica basada en logs **solo cuenta desde que la creas**; no procesa logs anteriores. Después de crearla, vuelve a lanzar `scripts/test-waf.sh` para que tenga datos.

Guarda el dashboard. Puedes exportar su JSON a `scripts/dashboard.json` para versionarlo.

---

## 6.2 Alerta por pico de bloqueos

**Ruta:** ☰ → **Monitoring** → **Alerting** → **Create policy**

| Campo | Valor | Por qué |
|---|---|---|
| **Metric** | Recurso **Network Security Policy** → `networksecurity.googleapis.com/https/request_count`, filtro `blocked = true` (o la métrica `armor_denies_by_rule`) | Mide bloqueos reales (no preview). Las métricas de Monitoring no pueden filtrar por campos del log, por eso se usa la etiqueta `blocked` o la métrica basada en logs. |
| **Rolling window / function** | 1 min / sum | |
| **Condition type** | **Threshold** → *above* `50` por minuto | Un pico de 50 denies/min indica ataque sostenido o un *deploy* que rompió algo y dispara falsos positivos. |
| **Notification channel** | **Add new → Email** (tu correo) | Aviso accionable. |
| **Alert name** | `alert-waf-spike` | |
| **Documentation** | "Pico de bloqueos Cloud Armor. Revisar `preconfiguredExprIds` en Logs Explorer y decidir: ataque (mantener) o FP (tunear)." | Un *runbook* embebido: tu yo futuro (o un compañero) sabe qué hacer. |

Click **Create policy**.

---

## 6.3 Consultas de log guardadas (Logs Explorer)

**Ruta:** ☰ → **Logging** → **Logs Explorer**. Pega cada consulta y guárdala (**Save**).

**a) Solo bloqueos del WAF, con firma:**
```
resource.type="http_load_balancer"
jsonPayload.enforcedSecurityPolicy.outcome="DENY"
```
Columnas útiles: `httpRequest.remoteIp`, `jsonPayload.enforcedSecurityPolicy.priority`, `jsonPayload.enforcedSecurityPolicy.preconfiguredExprIds`.

**b) Top IPs atacantes (para decidir un allowlist/denylist):**
```
resource.type="http_load_balancer"
jsonPayload.enforcedSecurityPolicy.outcome="DENY"
```
Luego **Actions → Analyze / group by** `httpRequest.remoteIp`.

**c) Intentos bloqueados por el firewall (Fase 1, regla de deny con log):**
```
logName=~"compute.googleapis.com%2Ffirewall"
jsonPayload.disposition="DENIED"
```
Demuestra que, aun antes del WAF, nadie alcanza las VMs por otros puertos.

---

## 6.4 (Opcional) Adaptive Protection

Cloud Armor **Enterprise** añade *Adaptive Protection*: un modelo de ML que detecta DDoS de capa 7 y sugiere reglas automáticamente. En tier **Standard** aparece como *Alerting only*.

**No lo habilites en el lab** (la suscripción Enterprise tiene costo mensual). Pero menciónalo en el README como evolución natural: *"siguiente paso en producción: Cloud Armor Enterprise con Adaptive Protection y Threat Intelligence"*. Muestra que conoces el techo del producto.

📸 **Evidencia:** dashboard con tráfico y bloqueos, la política de alerta, una consulta de log con IDs de firma → `evidencias/06-dashboard.png`, `evidencias/06-alert.png`.

✅ **Checkpoint:** dashboard con 4 widgets, 1 alerta con runbook, 3 consultas de log guardadas.

➡️ Siguiente: [Fase 7 — Limpieza](07-limpieza.md)
