#!/usr/bin/env bash
# Startup script para las VMs del MIG (Fase 2.2).
# Idempotente: seguro de re-ejecutar en cada arranque.
# Instala Docker y levanta OWASP Juice Shop en :3000, con logs a Cloud Logging.
set -euo pipefail

APP_PORT=3000
IMAGE="bkimminich/juice-shop:v17.1.1"   # fija la versión (reproducibilidad); ajusta si quieres 'latest'

# 1. Docker (solo si falta)
if ! command -v docker >/dev/null 2>&1; then
  export DEBIAN_FRONTEND=noninteractive
  apt-get update -y
  apt-get install -y docker.io
  systemctl enable --now docker
fi

# 2. Juice Shop (recrea si ya existía, para aplicar cambios de imagen)
if docker ps -a --format '{{.Names}}' | grep -q '^juiceshop$'; then
  docker rm -f juiceshop || true
fi

docker run -d \
  --name juiceshop \
  --restart unless-stopped \
  -p ${APP_PORT}:3000 \
  --log-driver=gcplogs \
  --log-opt labels=app \
  --label app=juiceshop \
  "${IMAGE}"

# 3. Espera activa a que la app responda (hasta ~2 min)
for _ in $(seq 1 24); do
  if curl -fs -o /dev/null "http://localhost:${APP_PORT}/"; then
    logger -t startup "Juice Shop UP en :${APP_PORT}"
    exit 0
  fi
  sleep 5
done

logger -t startup "ADVERTENCIA: Juice Shop no respondio a tiempo"
exit 0
