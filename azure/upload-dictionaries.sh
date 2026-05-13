#!/usr/bin/env bash
# Upload local CSV dictionaries to the Azure Files share that's mounted at
# /data on the Container App, then trigger a revision restart so the tagger
# reloads its FST.
#
# Prereqs:
#   - The Bicep stack was deployed with enableAzureFiles=true
#   - az CLI logged in
#
# Usage:
#   RESOURCE_GROUP=fst-guardrails-rg APP_NAME=fst-guardrails ./upload-dictionaries.sh
#   # optionally:
#   DATA_DIR=../data ./upload-dictionaries.sh

set -euo pipefail

RESOURCE_GROUP="${RESOURCE_GROUP:-fst-guardrails-rg}"
APP_NAME="${APP_NAME:-fst-guardrails}"
HERE="$(cd "$(dirname "$0")" && pwd)"
DATA_DIR="${DATA_DIR:-$HERE/../data}"

if [[ ! -d "$DATA_DIR" ]]; then
  echo "ERROR: DATA_DIR '$DATA_DIR' does not exist." >&2
  exit 1
fi

echo "==> Looking up storage account + share for app $APP_NAME..."
ENV_NAME="$(az containerapp show -n "$APP_NAME" -g "$RESOURCE_GROUP" \
  --query 'properties.environmentId' -o tsv | awk -F/ '{print $NF}')"

STORAGE_NAME="$(az containerapp env storage list \
  -g "$RESOURCE_GROUP" -n "$ENV_NAME" \
  --query "[?name=='dictionaries'].properties.azureFile.accountName | [0]" -o tsv)"
SHARE_NAME="$(az containerapp env storage list \
  -g "$RESOURCE_GROUP" -n "$ENV_NAME" \
  --query "[?name=='dictionaries'].properties.azureFile.shareName | [0]" -o tsv)"

if [[ -z "$STORAGE_NAME" || -z "$SHARE_NAME" ]]; then
  echo "ERROR: Container Apps environment '$ENV_NAME' has no 'dictionaries' storage." >&2
  echo "       Re-deploy the Bicep stack with enableAzureFiles=true." >&2
  exit 1
fi

echo "==> Storage account: $STORAGE_NAME"
echo "==> File share:      $SHARE_NAME"
echo "==> Local data dir:  $DATA_DIR"

ACCOUNT_KEY="$(az storage account keys list -g "$RESOURCE_GROUP" -n "$STORAGE_NAME" \
  --query "[0].value" -o tsv)"

echo "==> [1/2] Uploading CSVs to the share..."
az storage file upload-batch \
  --account-name "$STORAGE_NAME" --account-key "$ACCOUNT_KEY" \
  --destination "$SHARE_NAME" \
  --source "$DATA_DIR" \
  --pattern "*.csv" \
  --output none

echo "==> [2/2] Restarting the active revision so the FST reloads..."
ACTIVE_REV="$(az containerapp revision list -n "$APP_NAME" -g "$RESOURCE_GROUP" \
  --query "[?properties.active].name | [0]" -o tsv)"
az containerapp revision restart -n "$APP_NAME" -g "$RESOURCE_GROUP" \
  --revision "$ACTIVE_REV" -o none

APP_URL="$(az containerapp show -n "$APP_NAME" -g "$RESOURCE_GROUP" \
  --query properties.configuration.ingress.fqdn -o tsv)"

echo
echo "Done."
echo "    URL:  https://${APP_URL}"
echo "    Try:  curl \"https://${APP_URL}/tag?text=...\""
