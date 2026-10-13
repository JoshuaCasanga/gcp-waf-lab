# Fase 7 — Limpieza (detener el gasto)

> **Objetivo:** destruir todo lo creado, en el orden correcto, para que el lab no genere costo. Un presupuesto solo avisa; esto es lo que corta.
> **Tiempo estimado:** 10 min.

## Por qué importa el orden

Los recursos tienen **dependencias**: no puedes borrar una IP mientras un forwarding rule la usa, ni una subred mientras una VM vive en ella. Se borra de afuera hacia adentro: **frontend → proxies → backend → cómputo → red**.

## Opción A — Borrar el proyecto completo (recomendada)

La forma más segura de no dejar nada cobrando:

**Ruta:** ☰ → **IAM & Admin** → **Settings** → **Shut down** (Delete project).

```bash
gcloud projects delete waap-lab-<sufijo>
```

Google programa la eliminación y deja ~30 días para recuperarlo. Después de eso, no existe nada que cobre. **Si creaste el proyecto solo para este lab, esta es la opción.**

## Opción B — Borrar recurso por recurso (si compartes el proyecto)

Usa [`scripts/cleanup.sh`](../scripts/cleanup.sh), que ejecuta este orden:

```bash
# 1. Frontend: forwarding rules (443 y 80) y la IP deja de estar en uso
gcloud compute forwarding-rules delete fr-https fr-http --global -q

# 2. Target proxies + URL maps (incluye el de redirect)
gcloud compute target-https-proxies delete tp-https -q
gcloud compute target-http-proxies  delete tp-http  -q
gcloud compute url-maps delete um-waap-lab um-redirect -q

# 3. Certificado y SSL policy
gcloud compute ssl-certificates delete cert-waap-lab --global -q
gcloud compute ssl-policies      delete ssl-pol-modern -q

# 4. Backend service (desadjunta Cloud Armor automáticamente)
gcloud compute backend-services delete bes-juiceshop --global -q

# 5. Política Cloud Armor
gcloud compute security-policies delete ca-waap-lab -q

# 6. MIG (detiene y borra las VMs) + plantilla + health check
gcloud compute instance-groups managed delete mig-juiceshop --region=southamerica-west1 -q
gcloud compute instance-templates delete it-juiceshop-v1 -q
gcloud compute health-checks delete hc-juiceshop -q

# 7. IP estática (ya libre)
gcloud compute addresses delete ip-waap-lab --global -q

# 8. NAT + Cloud Router
gcloud compute routers nats delete nat-scl --router=cr-scl --region=southamerica-west1 -q
gcloud compute routers delete cr-scl --region=southamerica-west1 -q

# 9. Firewall + subred + VPC
gcloud compute firewall-rules delete fw-allow-gfe-hc-3000 fw-allow-iap-ssh fw-deny-all-ingress-log -q
gcloud compute networks subnets delete snet-web-scl --region=southamerica-west1 -q
gcloud compute networks delete vpc-waap-lab -q
```

## Verificación final

```bash
gcloud compute forwarding-rules list --global
gcloud compute instances list
gcloud compute addresses list --global
# Todo debe salir vacío.
```

> 💰 El recurso que más cobra aunque "no hagas nada" es el **balanceador** (regla de forwarding por hora) y la **IP estática reservada sin usar**. Confirma que ambos desaparecieron.

✅ **Checkpoint:** `gcloud compute ... list` vacío o proyecto eliminado. Costo detenido.

⬅️ Volver al [README](../README.md)
