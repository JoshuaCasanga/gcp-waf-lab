# Fase 3 — Balanceador de aplicaciones global + HTTPS

> **Objetivo:** publicar el MIG detrás de un **Global external Application Load Balancer** con IP pública estática, certificado TLS administrado por Google y redirección HTTP→HTTPS. Este balanceador es el punto donde, en la Fase 4, se "engancha" Cloud Armor.


El balanceador de aplicaciones global se compone de piezas encadenadas. La consola las crea en un solo asistente, pero conviene entender cada una porque el equivalente CLI las crea por separado.

| Pieza | Función | Equivalente mental F5 |
|---|---|---|
| **Forwarding rule** | Une la IP+puerto público con un *target proxy*. | *Virtual Server* (IP:puerto). |
| **Target proxy** | Termina TLS (si es HTTPS), sostiene el certificado y consulta el URL map. | Perfil Client-SSL + listener. |
| **URL map** | Enruta por host/path hacia un backend service. | iRule / política de enrutamiento LTM. |
| **Backend service** | Define salud, balanceo, named port, logging y **dónde se adjunta Cloud Armor**. | *Pool* + monitor. |
| **Backend (MIG)** | Las VMs reales. | Miembros del pool. |

---

## 3.1 Reservar IP estática global

**Ruta:** ☰ → **VPC network** → **IP addresses** → **Reserve external static IP address**

| Campo | Valor | Por qué |
|---|---|---|
| **Name** | `ip-waap-lab` | |
| **Network Service Tier** | **Premium** | El balanceador **global** solo funciona en nivel Premium (se debe usar la red troncal de Google y los GFE en el borde). *Standard* es regional. |
| **IP version** | IPv4 | |
| **Type** | **Global** | Debe coincidir con el alcance del balanceador. Una IP *Regional* no se puede adjuntar a un forwarding rule global. |

Click **Reserve**.

**Por qué estática:** el registro DNS `A` y el certificado administrado dependen de que la IP no cambie. Una IP efímera se perdería al recrear el balanceador.

**Crear el dominio**
- Acá utilicé `sslip.io`, lo que permite crear un dominio para el certificado TLS, sin configurar nada.

---

## 3.2 Crear el balanceador (asistente)

**Ruta:** ☰ → **Network services** → **Load balancing** → **Create load balancer**

### Selección de tipo

| Pantalla | Elección | Por qué |
|---|---|---|
| **Type of load balancer** | **Application Load Balancer (HTTP/HTTPS)** | Capa 7: es el único tipo que entiende HTTP y por tanto el único al que se le puede adjuntar un WAF (Cloud Armor inspecciona HTTP). |
| **Public facing or internal** | **Public facing (external)** | El portal se publica a Internet. |
| **Global or single region** | **Best for global workloads** | Habilita el balanceador global basado en GFE, requisito para Cloud Armor con reglas WAF preconfiguradas. |
| **Load balancer generation** | **Global external Application Load Balancer** | La generación actual (no el "classic"). |

Click **Configure**. **Name:** `alb-waap-lab`.

### Backend configuration

**Backend services & backend buckets** → **Create a backend service**

| Campo | Valor | Por qué |
|---|---|---|
| **Name** | `bes-juiceshop` | |
| **Backend type** | **Instance group** | |
| **Protocol** | **HTTP** | TLS se termina en el balanceador; del GFE al backend el tráfico va por la red interna de Google, [cifrado automáticamente por Google](https://docs.cloud.google.com/load-balancing/docs/ssl-certificates/encryption-to-the-backends). Para el lab, HTTP al backend es suficiente y simplifica. |
| **Named port** | `http` | Debe coincidir con el named port del MIG (Fase 2.4). |
| **Timeout** | `30 s` | |
| **New backend → Instance group** | `mig-juiceshop` | |
| **Balancing mode** | **Utilization**, Max 80 % | Envía tráfico según uso de CPU del backend. |
| **Capacity** | `100 %` | |
| **Health check** | `hc-juiceshop` (existente) | |
| **Logging** | **Enable**, Sample rate `1` |  Registra **el 100 %** de las peticiones. Cada log trae latencia, código de respuesta y, cuando Cloud Armor actúe, **qué regla disparó**. |
| **Cloud Armor → backend security policy** | Se deja en **None / Default** por ahora | La política se crea y adjunta en la Fase 4. |
| **Identity-Aware Proxy** | **Off** | IAP a nivel de app forzaría login de Google a todo visitante; queremos el portal público para probar el WAF. |

Click **Create**.

### Frontend configuration

Aquí se crean **dos** frontends: HTTPS (el real) y HTTP (solo para redirigir).

**Frontend 1 — HTTPS:**

| Campo | Valor | Por qué |
|---|---|---|
| **Name** | `fe-https` | |
| **Protocol** | **HTTPS (includes HTTP/2)** | |
| **IP version / IP address** | IPv4 / `ip-waap-lab` | La IP estática reservada. |
| **Port** | `443` | |
| **Certificate** | **Create a new certificate** → tipo **Create Google-managed certificate** → Name `cert-waap-lab` → Domains: tu hostname (`app.tudominio.com` o `34-120-10-5.sslip.io`) | Google **emite y renueva** el certificado gratis. Requiere que el DNS ya apunte a la IP: Google valida el dominio por esa ruta. La emisión tarda de 15 a 60 min. |
| **SSL policy** | `ssl-pol-modern` (créala **antes**, ver nota abajo) | Deshabilita TLS 1.0/1.1 y cifradores débiles. Esto es *hardening* directo del control de "configuración TLS" que ya tocas con F5. La opción *GCP default* usa perfil **COMPATIBLE** y acepta TLS 1.0/1.1. |
| **Early data (0-RTT)** | **Disabled** | 0-RTT reduce latencia pero expone la primera petición a ataques de *replay*. |

Click **Done**.

**Frontend 2 — HTTP (redirección):**
En la pantalla del frontend HTTPS, marca la casilla **Enable HTTP to HTTPS redirect**.

Se crea automáticamente un segundo forwarding rule en el puerto 80 con un URL map cuya única acción es devolver `301` hacia `https://`. Así nadie navega en claro, y el usuario que teclea `http://` igual llega seguro. Es una buena práctica de seguridad web estándar.

---

## 3.3 Esperar el certificado y verificar

El balanceador queda activo en 1–2 min, pero el **certificado** necesita que el DNS resuelva y puede tardar hasta 60 min en pasar a `ACTIVE`.

```bash
# Estado del certificado (repetir hasta ACTIVE)
gcloud compute ssl-certificates describe cert-waap-lab --global \
  --format="value(managed.status, managed.domainStatus)"
# PROVISIONING → ACTIVE

# Backends sanos (2/2)
gcloud compute backend-services get-health bes-juiceshop --global \
  --format="value(status.healthStatus[].healthState)"

# Prueba de extremo a extremo
curl -I http://app.tudominio.com      # -> 301 Moved Permanently a https
curl -I https://app.tudominio.com     # -> 200 OK (Juice Shop)
```

📸 **Evidencia:** certificado `ACTIVE`, backends `2/2 HEALTHY`, Juice Shop abierto en el navegador por HTTPS con candado → `evidencias/03-cert-active.png`, `evidencias/03-portal-https.png`.

✅ **Checkpoint:** portal accesible por HTTPS, HTTP redirige a HTTPS, TLS 1.2+ forzado, backends sanos. **Todavía sin WAF.**

➡️ Siguiente: [Fase 4 — Cloud Armor (WAF)](04-cloud-armor.md)
