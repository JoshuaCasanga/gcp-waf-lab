#!/usr/bin/env bash
# Despliegue completo del lab WAAP por CLI (equivalente a las Fases 1-4 de la consola).
# Uso:  source scripts/00-variables.sh && bash scripts/deploy.sh
# Requiere: gcloud autenticado y APIs habilitadas (Fase 0).
set -euo pipefail

: "${PROJECT_ID:?source scripts/00-variables.sh primero}"
gcloud config set project "$PROJECT_ID"
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

echo "== Fase 1: Red =="
gcloud compute networks create "$VPC" --subnet-mode=custom
gcloud compute networks subnets create "$SUBNET" \
  --network="$VPC" --range="$SUBNET_RANGE" --region="$REGION" \
  --enable-private-ip-google-access --enable-flow-logs

gcloud compute firewall-rules create fw-allow-gfe-hc-3000 \
  --network="$VPC" --direction=ingress --action=allow \
  --rules="tcp:${APP_PORT}" --source-ranges="$GFE_HC_RANGES" \
  --target-tags="$TAG" --enable-logging --priority=1000
gcloud compute firewall-rules create fw-allow-iap-ssh \
  --network="$VPC" --direction=ingress --action=allow \
  --rules="tcp:22" --source-ranges="$IAP_RANGE" \
  --target-tags="$TAG" --enable-logging --priority=1000
gcloud compute firewall-rules create fw-deny-all-ingress-log \
  --network="$VPC" --direction=ingress --action=deny \
  --rules=all --source-ranges="0.0.0.0/0" \
  --enable-logging --priority=65000

gcloud compute routers create "$ROUTER" --network="$VPC" --region="$REGION"
gcloud compute routers nats create "$NAT" --router="$ROUTER" --region="$REGION" \
  --nat-all-subnet-ip-ranges --auto-allocate-nat-external-ips \
  --enable-logging --log-filter=ALL

echo "== Fase 2: Cuenta de servicio + plantilla + MIG =="
gcloud iam service-accounts create "$SA" --display-name="WAAP backend"
SA_EMAIL="${SA}@${PROJECT_ID}.iam.gserviceaccount.com"
for ROLE in roles/logging.logWriter roles/monitoring.metricWriter; do
  gcloud projects add-iam-policy-binding "$PROJECT_ID" \
    --member="serviceAccount:${SA_EMAIL}" --role="$ROLE" >/dev/null
done

gcloud compute instance-templates create "$TEMPLATE" \
  --region="$REGION" --machine-type=e2-small \
  --image-family=debian-12 --image-project=debian-cloud \
  --boot-disk-size=20GB --boot-disk-type=pd-balanced \
  --network="$VPC" --subnet="$SUBNET" --no-address \
  --tags="$TAG" \
  --service-account="$SA_EMAIL" \
  --scopes=cloud-platform \
  --shielded-secure-boot --shielded-vtpm --shielded-integrity-monitoring \
  --metadata=enable-oslogin=TRUE,block-project-ssh-keys=TRUE \
  --metadata-from-file=startup-script="${SCRIPT_DIR}/startup-script.sh"

gcloud compute health-checks create http "$HC" \
  --global --port="$APP_PORT" --request-path="/" \
  --check-interval=10s --timeout=5s \
  --healthy-threshold=2 --unhealthy-threshold=3

gcloud compute instance-groups managed create "$MIG" \
  --template="$TEMPLATE" --size=2 --region="$REGION" \
  --health-check="$HC" --initial-delay=300
gcloud compute instance-groups managed set-named-ports "$MIG" \
  --named-ports="http:${APP_PORT}" --region="$REGION"
gcloud compute instance-groups managed set-autoscaling "$MIG" \
  --region="$REGION" --min-num-replicas=2 --max-num-replicas=4 \
  --target-cpu-utilization=0.6 --cool-down-period=300

echo "== Fase 3: Balanceador + HTTPS =="
gcloud compute addresses create "$IP_NAME" --global --ip-version=IPV4
LB_IP=$(gcloud compute addresses describe "$IP_NAME" --global --format="value(address)")
echo ">> IP del balanceador: $LB_IP  (crea el A record: $DOMAIN -> $LB_IP)"

gcloud compute backend-services create "$BES" \
  --global --protocol=HTTP --port-name=http \
  --health-checks="$HC" --timeout=30s \
  --enable-logging --logging-sample-rate=1.0 \
  --load-balancing-scheme=EXTERNAL_MANAGED
gcloud compute backend-services add-backend "$BES" \
  --global --instance-group="$MIG" --instance-group-region="$REGION" \
  --balancing-mode=UTILIZATION --max-utilization=0.8

gcloud compute ssl-policies create "$SSL_POLICY" \
  --profile=MODERN --min-tls-version=1.2
gcloud compute ssl-certificates create "$CERT" \
  --global --domains="$DOMAIN"

gcloud compute url-maps create um-waap-lab --default-service="$BES"
gcloud compute target-https-proxies create tp-https \
  --url-map=um-waap-lab --ssl-certificates="$CERT" --ssl-policy="$SSL_POLICY"
gcloud compute forwarding-rules create fr-https \
  --global --address="$IP_NAME" --target-https-proxy=tp-https --ports=443 \
  --load-balancing-scheme=EXTERNAL_MANAGED

# Redirect HTTP -> HTTPS
cat > /tmp/redirect.yaml <<'YAML'
kind: compute#urlMap
name: um-redirect
defaultUrlRedirect:
  httpsRedirect: true
  redirectResponseCode: MOVED_PERMANENTLY_DEFAULT
YAML
gcloud compute url-maps import um-redirect --global --source=/tmp/redirect.yaml -q
gcloud compute target-http-proxies create tp-http --url-map=um-redirect
gcloud compute forwarding-rules create fr-http \
  --global --address="$IP_NAME" --target-http-proxy=tp-http --ports=80 \
  --load-balancing-scheme=EXTERNAL_MANAGED

echo "== Fase 4: Cloud Armor =="
gcloud compute security-policies create "$ARMOR" \
  --description="WAAP lab - OWASP CRS + rate limit + geo"
gcloud compute security-policies update "$ARMOR" --log-level=VERBOSE

# Reglas WAF preconfiguradas (en preview al inicio)
declare -A WAF=(
  [1000]="sqli-v33-stable"     [1010]="xss-v33-stable"
  [1020]="lfi-v33-stable"      [1030]="rce-v33-stable"
  [1040]="rfi-v33-stable"      [1050]="scannerdetection-v33-stable"
  [1060]="protocolattack-v33-stable" [1070]="sessionfixation-v33-stable"
)
for P in "${!WAF[@]}"; do
  gcloud compute security-policies rules create "$P" \
    --security-policy="$ARMOR" \
    --expression="evaluatePreconfiguredWaf('${WAF[$P]}', {'sensitivity': 1})" \
    --action=deny-403 --preview
done

# Rate based ban
gcloud compute security-policies rules create 2000 \
  --security-policy="$ARMOR" --expression="true" \
  --action=rate-based-ban \
  --rate-limit-threshold-count=100 --rate-limit-threshold-interval-sec=60 \
  --ban-duration-sec=300 \
  --ban-threshold-count=100 --ban-threshold-interval-sec=60 \
  --conform-action=allow --exceed-action=deny-429 \
  --enforce-on-key=IP

# Geo (preview)
gcloud compute security-policies rules create 1500 \
  --security-policy="$ARMOR" \
  --expression="origin.region_code != 'CL'" \
  --action=deny-403 --preview

# Adjuntar al backend service
gcloud compute backend-services update "$BES" \
  --global --security-policy="$ARMOR"

echo "== LISTO =="
echo "IP: $LB_IP  | Dominio: $DOMAIN"
echo "Siguiente: crea el A record, espera el certificado (hasta 60 min) y corre scripts/test-waf.sh"
