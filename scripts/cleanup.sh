#!/usr/bin/env bash
# Destruye todos los recursos del lab en el orden correcto (Fase 7, Opcion B).
# Uso:  source scripts/00-variables.sh && bash scripts/cleanup.sh
# Alternativa mas segura si el proyecto es dedicado:  gcloud projects delete "$PROJECT_ID"
set -uo pipefail   # no -e: queremos continuar aunque algo ya no exista

: "${PROJECT_ID:?source scripts/00-variables.sh primero}"
gcloud config set project "$PROJECT_ID"
D="-q"

echo "== Frontend =="
gcloud compute forwarding-rules delete fr-https fr-http --global $D
gcloud compute target-https-proxies delete tp-https $D
gcloud compute target-http-proxies  delete tp-http  $D
gcloud compute url-maps delete um-waap-lab um-redirect $D

echo "== TLS =="
gcloud compute ssl-certificates delete "$CERT" --global $D
gcloud compute ssl-policies      delete "$SSL_POLICY" $D

echo "== Backend + Cloud Armor =="
gcloud compute backend-services delete "$BES" --global $D
gcloud compute security-policies delete "$ARMOR" $D

echo "== Computo =="
gcloud compute instance-groups managed delete "$MIG" --region="$REGION" $D
gcloud compute instance-templates delete "$TEMPLATE" $D
gcloud compute health-checks delete "$HC" $D

echo "== IP =="
gcloud compute addresses delete "$IP_NAME" --global $D

echo "== NAT + Router =="
gcloud compute routers nats delete "$NAT" --router="$ROUTER" --region="$REGION" $D
gcloud compute routers delete "$ROUTER" --region="$REGION" $D

echo "== Red =="
gcloud compute firewall-rules delete fw-allow-gfe-hc-3000 fw-allow-iap-ssh fw-deny-all-ingress-log $D
gcloud compute networks subnets delete "$SUBNET" --region="$REGION" $D
gcloud compute networks delete "$VPC" $D

echo "== Verificacion =="
gcloud compute forwarding-rules list --global
gcloud compute instances list
gcloud compute addresses list --global
echo "Si todo sale vacio, el costo esta detenido."
