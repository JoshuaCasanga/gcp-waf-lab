# Fase 6 — Observabilidad: dashboard, alertas y logs

> **Objetivo:** convertir los eventos del WAF en algo visible y accionable — un dashboard de Monitoring, una alerta que avise ante un pico de bloqueos, y consultas de log guardadas.

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


### Métrica basada en logs: bloqueos por regla

**Ruta:** ☰ → **Logging** → **Log-based Metrics** → **Create metric**

| Campo | Valor | Por qué |
|---|---|---|
| **Metric type** | **Counter** | Cuenta entradas de log que cumplen el filtro. |
| **Log-based metric name** | `armor_denies_by_rule` | Queda como `logging.googleapis.com/user/armor_denies_by_rule`. |
| **Build filter** | `resource.type="http_load_balancer"` `jsonPayload.enforcedSecurityPolicy.outcome="DENY"` | Solo bloqueos reales (no preview). |
| **Labels → Add label** | Name `priority`, Type **String**, Field name `jsonPayload.enforcedSecurityPolicy.priority` | Convierte la prioridad del log en una dimensión de la métrica. Esto es lo que permite agrupar por regla. |

Click **Create metric**.

---

