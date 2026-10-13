# Fase 1 — Red: VPC, subred, firewall y salida controlada

> **Objetivo:** una VPC propia donde **nada es alcanzable desde Internet** salvo a través del balanceador de Google, con salida a Internet solo por NAT y acceso administrativo solo por IAP.

```
Internet ──X──> VMs (no tienen IP pública)
Google Front End (GFE) / health checks ──> VMs :3000   (único ingreso de datos)
IAP (35.235.240.0/20) ──> VMs :22                       (único ingreso administrativo)
VMs ──> Cloud NAT ──> Internet                          (solo salida, p. ej. Docker Hub)
```

---

## 1.1 Crear la VPC en modo custom

**Ruta:** ☰ → **VPC network** → **VPC networks** → **Create VPC network**

| Campo | Valor | Por qué |
|---|---|---|
| **Name** | `vpc-waap-lab` | |
| **Maximum transmission unit (MTU)** | `1460` (default) | El valor por defecto de GCP; no hay túneles ni jumbo frames que justifiquen otro. |
| **Subnet creation mode** | **Custom** | El modo *Automatic* crea una subred en **cada región** con rangos predefinidos. *Custom* te obliga a declarar solo lo que usas: menos superficie, direccionamiento controlado y sin solapes con otras redes (clave si después conectas una VPN como en tu lab de Palo Alto). |

**Sección New subnet:**

| Campo | Valor | Por qué |
|---|---|---|
| **Name** | `snet-web-scl` | Convención `snet-<capa>-<región>`. |
| **Region** | `southamerica-west1` (Santiago) | Latencia mínima para ti y residencia de datos en Chile. |
| **IP stack type** | **IPv4 (single-stack)** | Simplicidad; IPv6 queda como mejora opcional. |
| **IPv4 range** | `10.10.10.0/24` | 252 IPs utilizables, de sobra para un MIG de 2–4 VMs. |
| **Private Google Access** | **On** | Permite que VMs **sin IP pública** hablen con APIs de Google (Cloud Logging, Monitoring) por la red interna de Google, sin pasar por NAT. Sin esto, el driver de logs de Docker no podría enviar logs. |
| **Flow logs** | **On** → *Aggregation interval* 5 s, *Sample rate* 50 % | Registro de metadatos de conexiones (5-tupla, bytes). Sirve para demostrar que nadie llega a las VMs salvo GFE/IAP. 50 % equilibra visibilidad y costo de logging. |

Click **Done**.

**Sección Firewall rules (dentro del mismo asistente):**
La consola ofrece reglas sugeridas (`allow-icmp`, `allow-ssh`, `allow-rdp`, `allow-custom`). **Deja todas sin marcar.**
**Por qué:** `allow-ssh` abre el 22 a `0.0.0.0/0`, exactamente lo que este lab quiere evitar. Crearemos reglas mínimas a mano en el paso 1.2.

| Campo | Valor | Por qué |
|---|---|---|
| **Dynamic routing mode** | **Regional** | Solo hay una región; *Global* sirve cuando un Cloud Router debe anunciar rutas de todas las regiones (VPN/Interconnect multirregión). |

Click **Create**.

> Una VPC nueva trae dos reglas implícitas que **no se ven** en la lista: *deny all ingress* y *allow all egress*, ambas con prioridad 65535. Todo ingreso está bloqueado hasta que lo permitas explícitamente.

---

## 1.2 Reglas de firewall (mínimo privilegio)

**Ruta:** ☰ → **VPC network** → **Firewall policies** → **Create firewall rule** (sección *VPC firewall rules*)

Todas las reglas apuntan a un **tag de red** `web-backend`, que pondremos en la plantilla de VMs (Fase 2). Así la regla aplica solo a los backends y no a cualquier VM que alguien cree en la VPC.

### Regla A — Tráfico del balanceador y health checks

| Campo | Valor | Por qué |
|---|---|---|
| **Name** | `fw-allow-gfe-hc-3000` | |
| **Logs** | **On** | Cada conexión permitida queda registrada (evidencia para el README). |
| **Network** | `vpc-waap-lab` | |
| **Priority** | `1000` | Menor número = mayor prioridad. 1000 es el estándar para *allow*. |
| **Direction of traffic** | **Ingress** | |
| **Action on match** | **Allow** | |
| **Targets** | **Specified target tags** → `web-backend` | Aplica solo a las VMs del backend. |
| **Source filter** | **IPv4 ranges** | |
| **Source IPv4 ranges** | `35.191.0.0/16`, `130.211.0.0/22` | Son los rangos de Google desde donde llegan **los health checks** (`35.191.0.0/16`) y **el tráfico proxied por los Google Front Ends** del balanceador global (`35.191.0.0/16` y `130.211.0.0/22`). Nadie en Internet puede usar estas IPs como origen: los routers de borde de Google descartan paquetes que las falsifiquen. |
| **Protocols and ports** | **Specified** → TCP `3000` | Juice Shop escucha en 3000. Ni un puerto más. |

Click **Create**.

### Regla B — SSH solo vía Identity-Aware Proxy

| Campo | Valor | Por qué |
|---|---|---|
| **Name** | `fw-allow-iap-ssh` | |
| **Logs** | **On** | |
| **Priority** | `1000` | |
| **Direction / Action** | Ingress / Allow | |
| **Targets** | tag `web-backend` | |
| **Source IPv4 ranges** | `35.235.240.0/20` | Rango exclusivo de **IAP TCP forwarding**. IAP autentica al usuario con su identidad de Google + IAM **antes** de abrir el túnel: SSH sin IP pública y sin bastión. |
| **Protocols and ports** | TCP `22` | |

### Regla C — Deny explícito con log

| Campo | Valor | Por qué |
|---|---|---|
| **Name** | `fw-deny-all-ingress-log` | |
| **Logs** | **On** | La regla implícita *deny* **no genera logs**. Esta copia explícita sí: verás en Cloud Logging cada intento de conexión bloqueado (escaneos, bots). |
| **Priority** | `65000` | Se evalúa después de las *allow* (1000) pero antes de la implícita (65535). |
| **Direction / Action** | Ingress / **Deny** | |
| **Targets** | **All instances in the network** | |
| **Source IPv4 ranges** | `0.0.0.0/0` | |
| **Protocols and ports** | **Deny all** | |


---

## 1.3 Cloud Router + Cloud NAT (salida controlada)

Las VMs no tendrán IP pública, pero necesitan descargar paquetes (`apt-get install`) y la imagen de Juice Shop desde Docker Hub.

**Ruta:** ☰ → **Network services** → **Cloud NAT** → **Create Cloud NAT gateway**

| Campo | Valor | Por qué |
|---|---|---|
| **Gateway name** | `nat-scl` | |
| **NAT type** | **Public** | Traduce IPs privadas a IP pública para salir a Internet. |
| **Network** | `vpc-waap-lab` | |
| **Region** | `southamerica-west1` | Cloud NAT es **regional**: atiende solo subredes de su región. |
| **Cloud Router** | **Create new router** → Name `cr-scl` → **Create** | Cloud NAT no es un appliance: es configuración distribuida que **vive en un Cloud Router** (plano de control). No se usa BGP aquí; el router es solo el contenedor de la configuración. |
| **Source endpoint type** | VM instances | |
| **Source (internal)** | *Primary and secondary ranges for all subnets* | Solo hay una subred. |
| **Cloud NAT IP addresses** | **Automatic** | Google asigna y escala las IPs públicas de salida. En producción usarías *Manual* para tener IPs fijas que un tercero pueda poner en *allowlist*. |
| **Logging** | **Translation and errors** | Registra cada traducción: evidencia de qué destinos contactan tus VMs (útil para detectar exfiltración o C2). |

Click **Create**.

**Por qué NAT y no IP pública en cada VM:** NAT es **solo salida**. Una conexión iniciada desde Internet no tiene a dónde traducirse, así que las VMs siguen siendo inalcanzables. Es la misma idea que un SNAT/PAT en un FortiGate o Palo Alto.

---

