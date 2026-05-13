#!/usr/bin/env bash
# One-shot deploy of FST Guard Rails to Azure Container Apps.
#
# Prereqs:
#   - Azure CLI installed and logged in:  az login
#   - Docker running locally
#   - Default subscription set:           az account set -s <sub-id>
#
# Usage:
#   LOCATION=eastus ./deploy.sh
#   # or override anything:
#   RESOURCE_GROUP=my-rg ACR_NAME=myacr APP_NAME=tagger LOCATION=westus2 ./deploy.sh

set -euo pipefail

LOCATION="${LOCATION:-eastus}"
RESOURCE_GROUP="${RESOURCE_GROUP:-fst-guardrails-rg}"
APP_NAME="${APP_NAME:-fst-guardrails}"
# ACR names must be globally unique, 5-50 lowercase alphanumerics.
ACR_NAME="${ACR_NAME:-fstguardrails$RANDOM}"
IMAGE_TAG="${IMAGE_TAG:-$(date +%Y%m%d-%H%M%S)}"
MIN_REPLICAS="${MIN_REPLICAS:-1}"
MAX_REPLICAS="${MAX_REPLICAS:-5}"

HERE="$(cd "$(dirname "$0")" && pwd)"
PROJECT_ROOT="$(cd "$HERE/.." && pwd)"

echo "==> Subscription: $(az account show --query name -o tsv)"
echo "==> Region:       $LOCATION"
echo "==> Resource grp: $RESOURCE_GROUP"
echo "==> ACR:          $ACR_NAME"
echo "==> App:          $APP_NAME"

echo "==> [1/5] Creating resource group (idempotent)..."
az group create --name "$RESOURCE_GROUP" --location "$LOCATION" -o none

echo "==> [2/5] Ensuring ACR exists..."
if ! az acr show -n "$ACR_NAME" -g "$RESOURCE_GROUP" >/dev/null 2>&1; then
  az acr create -n "$ACR_NAME" -g "$RESOURCE_GROUP" --sku Basic --admin-enabled false -o none
fi
ACR_LOGIN_SERVER="$(az acr show -n "$ACR_NAME" -g "$RESOURCE_GROUP" --query loginServer -o tsv)"
ACR_ID="$(az acr show -n "$ACR_NAME" -g "$RESOURCE_GROUP" --query id -o tsv)"
IMAGE="${ACR_LOGIN_SERVER}/${APP_NAME}:${IMAGE_TAG}"

echo "==> [3/5] Building image in ACR (no local docker required)..."
# `az acr build` ships the build context to ACR and builds remotely.
az acr build \
  --registry "$ACR_NAME" \
  --image "${APP_NAME}:${IMAGE_TAG}" \
  --image "${APP_NAME}:latest" \
  --file "${PROJECT_ROOT}/Dockerfile" \
  "${PROJECT_ROOT}"

echo "==> [4/5] Ensuring containerapp extension + provider registration..."
az extension add --name containerapp --upgrade -o none 2>/dev/null || true
az provider register --namespace Microsoft.App -o none
az provider register --namespace Microsoft.OperationalInsights -o none

echo "==> [5/5] Deploying Bicep template..."
az deployment group create \
  --resource-group "$RESOURCE_GROUP" \
  --template-file "${HERE}/main.bicep" \
  --parameters \
      name="$APP_NAME" \
      location="$LOCATION" \
      image="$IMAGE" \
      acrResourceId="$ACR_ID" \
      minReplicas="$MIN_REPLICAS" \
      maxReplicas="$MAX_REPLICAS" \
  -o table

APP_URL="$(az containerapp show -n "$APP_NAME" -g "$RESOURCE_GROUP" --query properties.configuration.ingress.fqdn -o tsv)"
echo
echo "==> Deployed."
echo "    URL:    https://${APP_URL}"
echo "    Health: https://${APP_URL}/health"
echo "    Try:    curl \"https://${APP_URL}/tag?text=Ada+Lovelace+uses+Apache+Lucene\""
