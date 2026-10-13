# Fase 0 — Proyecto, facturación y guardrails

> **Objetivo:** partir de un proyecto limpio y aislado, con alerta de presupuesto y solo las APIs necesarias habilitadas.

La consola de GCP puede estar en español o inglés. Esta guía usa los nombres **en inglés** (los que aparecen en la documentación oficial); si tu consola está en español, el orden de las pantallas es el mismo.

---

## 0.1 Crear un proyecto dedicado

**Ruta:** selector de proyectos (barra superior) → **New Project**

| Campo | Valor | Por qué |
|---|---|---|
| **Project name** | `waap-lab` | Nombre legible. |
| **Project ID** | `waap-lab-<sufijo>` (ej. `waap-lab-ahc01`) | El ID es global y único en todo GCP; es lo que usan `gcloud` y la API. No se puede cambiar después. |
| **Location** | *No organization* (cuenta personal) | Sin organización no hay políticas heredadas que interfieran. En una empresa aquí elegirías la carpeta correspondiente. |

Click **Create**.

**Por qué un proyecto nuevo:** el proyecto es la frontera de facturación, IAM y cuotas. Aislar el lab permite borrarlo entero al final (limpieza garantizada) y evita que reglas de firewall o políticas de otro lab contaminen los resultados.

---

## 0.2 Vincular facturación y crear una alerta de presupuesto

**Ruta:** ☰ → **Billing** → **Budgets & alerts** → **Create budget**

| Campo | Valor | Por qué |
|---|---|---|
| **Name** | `budget-waap-lab` | |
| **Projects** | solo `waap-lab-<sufijo>` | La alerta debe medir este proyecto y no toda la cuenta. |
| **Budget type / Amount** | *Specified amount* → `20 USD` | Umbral bajo: si olvidas apagar algo, te enteras pronto. |
| **Thresholds** | 50 %, 90 %, 100 % | Avisos escalonados por correo. |

Click **Finish**.


---

## 0.3 Habilitar solo las APIs necesarias

**Ruta:** ☰ → **APIs & Services** → **Library**. Buscar y presionar **Enable** en cada una:

| API | Para qué se usa en el lab |
|---|---|
| **Compute Engine API** | VPC, firewall, VMs, MIG, balanceador, Cloud Armor (Cloud Armor vive dentro de la API de Compute). |
| **Cloud Logging API** | Logs del balanceador, de Cloud Armor, del firewall y de los contenedores. |
| **Cloud Monitoring API** | Métricas, dashboard y alertas. |
| **Identity-Aware Proxy (IAP) API** | SSH a VMs sin IP pública. |

**Por qué no habilitar todo:** cada API habilitada es superficie de ataque y potencial costo. Principio de mínimo privilegio aplicado al proyecto.

Equivalente CLI (desde Cloud Shell):

```bash
gcloud config set project waap-lab-<sufijo>
gcloud services enable compute.googleapis.com logging.googleapis.com \
  monitoring.googleapis.com iap.googleapis.com
```

---

## 0.4 Decidir el nombre de dominio

El certificado TLS administrado por Google **necesita un nombre DNS** que apunte a la IP del balanceador. Dos opciones:

| Opción | Cómo | Ventaja | Desventaja |
|---|---|---|---|
| **A. Dominio propio** (recomendada para portafolio) | Registrar un dominio barato y crear un registro `A` (en tu registrador o en Cloud DNS). | Se ve profesional en capturas; certificado normal. | Costo del dominio. |
| **B. `sslip.io` / `nip.io`** | Usar `34-120-10-5.sslip.io` (la IP con guiones). Ese nombre ya resuelve a la IP sin configurar nada. | Gratis e inmediato. | Depende de un servicio de terceros; si el certificado no se emite, usar la opción A. |

La IP la reservas en la [Fase 3](03-load-balancer.md); ahí se arma el nombre definitivo.

---

## 0.5 Cloud Shell

Abre **Cloud Shell** (icono `>_` arriba a la derecha). Ya trae `gcloud`, `curl`, `openssl` y `jq`; desde aquí ejecutarás las pruebas de la Fase 5.

```bash
git clone https://github.com/<tu-usuario>/gcp-waap-lab.git
cd gcp-waap-lab
cp scripts/00-variables.sh.example scripts/00-variables.sh   # edita PROJECT_ID y DOMAIN
```

