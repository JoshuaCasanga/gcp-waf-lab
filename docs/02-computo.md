# Fase 2 — Cómputo: identidad, plantilla endurecida, health check y MIG regional

> **Objetivo:** un grupo autoescalable y autorreparable de VMs **sin IP pública**, endurecidas, que corren **OWASP Juice Shop** (aplicación deliberadamente vulnerable) en el puerto 3000.
> **Tiempo estimado:** 30 min (+5 min de arranque de las VMs).

**¿Por qué Juice Shop?** Es una app Node.js/Angular con vulnerabilidades reales del OWASP Top 10 (SQLi en el login, XSS, directorio `/ftp` expuesto, `/metrics` público). Permite demostrar **antes/después** del WAF con ataques reales y no con un "Hello World".

> ⚠️ Juice Shop es vulnerable por diseño. Nunca la publiques sin el WAF activo más tiempo del necesario, y destruye el lab al terminar.

---

## 2.1 Cuenta de servicio dedicada (mínimo privilegio)

**Ruta:** ☰ → **IAM & Admin** → **Service Accounts** → **Create service account**

| Paso | Campo | Valor | Por qué |
|---|---|---|---|
| 1 | **Service account name** | `sa-web-backend` | Identidad con la que las VMs llaman a APIs de Google. |
| 2 | **Grant this service account access to project** → **Role** | `Logs Writer` (`roles/logging.logWriter`) | Permite que el contenedor envíe sus logs a Cloud Logging. |
| 2 | **Add another role** | `Monitoring Metric Writer` (`roles/monitoring.metricWriter`) | Permite publicar métricas. |
| 3 | **Grant users access** | (vacío) | Nadie necesita suplantar esta cuenta. |

Click **Done**.

**Por qué no usar la cuenta por defecto de Compute:** la *Compute Engine default service account* suele tener rol **Editor** sobre todo el proyecto. Si un atacante compromete la VM (Juice Shop es vulnerable…), podría leer el token del *metadata server* y administrar el proyecto. Con `sa-web-backend` el radio de impacto se limita a "escribir logs y métricas".

---

## 2.2 Plantilla de instancia endurecida

**Ruta:** ☰ → **Compute Engine** → **Instance templates** → **Create instance template**

| Sección | Campo | Valor | Por qué |
|---|---|---|---|
| — | **Name** | `it-juiceshop-v1` | El sufijo `v1` es intencional: las plantillas son **inmutables**; para cambiar algo creas `v2` y haces *rolling update* del MIG. |
| — | **Location** | **Regional** → `southamerica-west1` | La plantilla queda acotada a la región de la subred. |
| Machine configuration | **Series / Machine type** | `E2` / `e2-small` (2 vCPU compartidas, 2 GB) | Juice Shop necesita ~1 GB de RAM. `e2-micro` se queda corto. |
| Boot disk → **Change** | **Operating system / Version** | Debian / **Debian GNU/Linux 12 (bookworm)** | Imagen oficial mantenida por Google con parches. |
| | **Boot disk type / Size** | *Balanced persistent disk* / `20 GB` | Espacio para Docker y la imagen (~500 MB). |
| Identity and API access | **Service account** | `sa-web-backend` | La cuenta del paso 2.1. |
| | **Access scopes** | *Allow full access to all Cloud APIs* | Con una cuenta de servicio propia, **IAM** es quien limita los permisos; los *scopes* son un mecanismo heredado. Es la recomendación actual de Google. |
| Firewall | **Allow HTTP traffic / Allow HTTPS traffic** | **Sin marcar** | Solo agregan los tags `http-server`/`https-server`, pensados para reglas que abren a `0.0.0.0/0`. Aquí el único ingreso es el balanceador. |
| Advanced options → **Networking** | **Network tags** | `web-backend` | Engancha las reglas de firewall de la Fase 1. |
| | **Network interfaces** → **Edit** | Network `vpc-waap-lab`, Subnetwork `snet-web-scl` | |
| | **External IPv4 address** | **None** | 🔑 **Decisión de seguridad central del lab**: la VM no existe en Internet. El único camino es GFE → Cloud Armor → backend. |
| Advanced options → **Security** | **Shielded VM**: *Turn on Secure Boot*, *Turn on vTPM*, *Turn on Integrity Monitoring* | Las tres activadas | Secure Boot impide cargar bootloaders/kernels no firmados (rootkits); vTPM mide el arranque; Integrity Monitoring alerta si esa medición cambia. |
| Advanced options → **Management** | **Automation → Startup script** | Pegar el contenido de [`scripts/startup-script.sh`](../scripts/startup-script.sh) | Instala Docker y levanta Juice Shop en cada arranque. Las VMs del MIG son **ganado, no mascotas**: se configuran solas, nadie entra a instalar nada a mano. |
| | **Metadata** → *Add item* | `enable-oslogin` = `TRUE` | El acceso SSH se controla con **IAM** (roles `roles/compute.osLogin`) y queda auditado, en vez de llaves SSH sueltas en metadatos. |
| Advanced options → **Security** → **SSH Keys** (o *Manage access*) | **Block project-wide SSH keys** | ✅ Marcado | Ignora llaves SSH a nivel de proyecto que alguien pudiera agregar. ⚠️ **No** lo agregues como metadato libre: la consola rechaza la key `block-project-ssh-keys` en *Metadata* con el aviso *"use the SSH Keys section"*. Con OS Login activo estas llaves ya se ignoran; esto es defensa en profundidad. |

Click **Create**.

### Qué hace el startup script

```bash
apt-get install -y docker.io                      # runtime de contenedores
docker run -d --name juiceshop --restart unless-stopped \
  -p 3000:3000 --log-driver=gcplogs ... bkimminich/juice-shop
```

- `--restart unless-stopped`: si el proceso muere, Docker lo levanta.
- `--log-driver=gcplogs`: los logs de la aplicación van **directo a Cloud Logging** (por Private Google Access), sin instalar agentes.
- El script es **idempotente**: si la VM se reinicia, no falla por "contenedor ya existe".

---

## 2.3 Health check

**Ruta:** ☰ → **Compute Engine** → **Health checks** → **Create health check**

| Campo | Valor | Por qué |
|---|---|---|
| **Name** | `hc-juiceshop` | |
| **Scope** | **Global** | El balanceador **global** exige health checks globales. |
| **Protocol / Port** | HTTP / `3000` | Sondea exactamente el servicio que se publica, no solo que la VM esté encendida. |
| **Proxy protocol** | NONE | |
| **Request path** | `/` | La home de Juice Shop responde `200` cuando la app está lista. Ojo: un `301`/`302` cuenta como **no sano**. |
| **Logs** | **On** | Registra cambios de estado (HEALTHY ↔ UNHEALTHY): esencial para troubleshooting. |
| **Check interval / Timeout** | `10 s` / `5 s` | |
| **Healthy threshold / Unhealthy threshold** | `2` / `3` | Tolera un fallo aislado antes de sacar una VM de rotación. |

Click **Create**.

> 🔗 **Equivalencia F5:** es el *health monitor* del pool (BIG-IP) o el *health check* del *origin pool* (XC).

---

## 2.4 Managed Instance Group (MIG) regional

**Ruta:** ☰ → **Compute Engine** → **Instance groups** → **Create instance group** → **New managed instance group (stateless)**

> ⚠️ **Configura primero *Location* (más abajo en el formulario) y después elige la plantilla.** El campo *Instance template* solo muestra plantillas globales o regionales **de la región seleccionada** en *Location*, que por defecto viene en otra región. Si eliges la plantilla antes, verás *"No matches"* aunque `it-juiceshop-v1` exista.

| Campo | Valor | Por qué |
|---|---|---|
| **Name** | `mig-juiceshop` | |
| **Instance template** | `it-juiceshop-v1` | |
| **Location** | **Multiple zones** → Region `southamerica-west1`, zonas `a`, `b`, `c` | **Alta disponibilidad**: si una zona cae, el MIG mantiene VMs en las otras. Un MIG zonal sería un punto único de falla. |
| **Target distribution shape** | **Balanced** (default) | Reparte las VMs en partes iguales entre zonas cuando hay capacidad y, si una zona no tiene, crea la VM en otra en vez de fallar. *Even* exige simetría exacta (puede fallar al escalar) y la consola solo lo permite si desactivas la reparación de VMs en zona alternativa, que viene activa por defecto y aporta resiliencia. Para un MIG regional, *Balanced* prioriza disponibilidad. |
| **Autoscaling mode** | **On: add and remove instances to the group** | |
| **Minimum / Maximum number of instances** | `2` / `4` | Mínimo 2 = HA real (una VM en al menos dos zonas). Máximo 4 = techo de costo, incluso bajo un ataque de capa 7 que se escape del rate limiting. |
| **Autoscaling signals** | CPU utilization → `60 %` | Escala antes de saturar. |
| **Initialization period** | `300 s` | Tiempo que tarda una VM nueva en instalar Docker y bajar la imagen; evita que el autoscaler tome decisiones con métricas de VMs que todavía arrancan. |
| **Autohealing → Health check** | `hc-juiceshop` | Si la app deja de responder, el MIG **recrea** la VM automáticamente. |
| **Autohealing → Initial delay** | `300 s` | Sin esto, el MIG destruiría VMs recién creadas antes de que Juice Shop termine de arrancar (bucle de recreación). |
| **Port mapping → Add port** | Name `http`, Port `3000` | El **named port**: el backend service del balanceador dice "envía a `http`" y el MIG traduce a `3000`. Desacopla el balanceador del puerto real. |

Click **Create**.

> 💡 En producción conviene un health check de *autohealing* separado y más conservador que el del balanceador, para que un pico de carga no provoque recreación de VMs. Para el lab, uno basta.

---

## 2.5 Verificación

Espera ~5 minutos y valida:

```bash
# Las VMs NO deben tener IP externa (columna EXTERNAL_IP vacía)
gcloud compute instances list --filter="name~juiceshop"

# Entrar por IAP (sin IP pública, sin bastión)
VM=$(gcloud compute instances list --filter="name~juiceshop" --format="value(name)" --limit=1)
ZONE=$(gcloud compute instances list --filter="name=$VM" --format="value(zone.basename())")
gcloud compute ssh "$VM" --zone="$ZONE" --tunnel-through-iap \
  --command="sudo docker ps && curl -s -o /dev/null -w '%{http_code}\n' localhost:3000"
# Esperado: contenedor juiceshop "Up" y código 200
```

Si `docker ps` sale vacío: revisa el log del startup script con
`sudo journalctl -u google-startup-scripts.service --no-pager | tail -50`.

📸 **Evidencia:** lista de VMs sin IP externa + salida del comando por IAP → `evidencias/02-vms-sin-ip.png`, `evidencias/02-iap-ssh.png`.

✅ **Checkpoint:** 2 VMs en zonas distintas, Juice Shop responde 200 en `localhost:3000`, sin IPs públicas.

➡️ Siguiente: [Fase 3 — Load Balancer](03-load-balancer.md)
