#!/usr/bin/env bash
# Upload local CSV dictionaries to the GCS bucket mounted at /data on the
# Cloud Run service, then trigger a new revision so the FST reloads.
#
# Prereqs:
#   - The service was deployed with ENABLE_GCS=true
#   - gcloud CLI logged in
#
# Usage:
#   PROJECT_ID=my-proj REGION=us-central1 ./upload-dictionaries.sh
#   # optionally:
#   DATA_DIR=../data SERVICE_NAME=fst-guardrails ./upload-dictionaries.sh

set -euo pipefail

PROJECT_ID="${PROJECT_ID:-$(gcloud config get-value project 2>/dev/null)}"
[[ -z "$PROJECT_ID" || "$PROJECT_ID" == "(unset)" ]] && \
  { echo "Set PROJECT_ID or run: gcloud config set project <id>" >&2; exit 1; }

REGION="${REGION:-us-central1}"
SERVICE_NAME="${SERVICE_NAME:-fst-guardrails}"
HERE="$(cd "$(dirname "$0")" && pwd)"
DATA_DIR="${DATA_DIR:-$HERE/../data}"

if [[ ! -d "$DATA_DIR" ]]; then
  echo "ERROR: DATA_DIR '$DATA_DIR' does not exist." >&2
  exit 1
fi

echo "==> Looking up GCS bucket mounted on Cloud Run service $SERVICE_NAME..."
BUCKET="$(gcloud run services describe "$SERVICE_NAME" \
  --project "$PROJECT_ID" --region "$REGION" \
  --format='value(spec.template.spec.volumes[0].csi.volumeAttributes.bucketName)' 2>/dev/null || true)"

# Fallback for the gen2 declarative form: parse from --add-volume metadata
if [[ -z "$BUCKET" ]]; then
  BUCKET="$(gcloud run services describe "$SERVICE_NAME" \
    --project "$PROJECT_ID" --region "$REGION" --format=json 2>/dev/null \
    | python3 -c '
import json, sys
svc = json.load(sys.stdin)
for v in svc.get("spec", {}).get("template", {}).get("spec", {}).get("volumes", []):
    src = v.get("csi", {}) or {}
    attrs = src.get("volumeAttributes", {}) or {}
    if attrs.get("bucketName"):
        print(attrs["bucketName"]); break
    # gen2 representation
    if v.get("name") == "data" and "gcs" in v:
        print(v["gcs"].get("bucket", "")); break
')"
fi

if [[ -z "$BUCKET" ]]; then
  echo "ERROR: service '$SERVICE_NAME' has no GCS volume mounted." >&2
  echo "       Re-deploy with: ENABLE_GCS=true ./deploy.sh" >&2
  exit 1
fi

echo "==> Bucket:        gs://$BUCKET"
echo "==> Local dir:     $DATA_DIR"

echo "==> [1/2] Syncing CSVs to the bucket..."
gcloud storage rsync "$DATA_DIR/" "gs://$BUCKET/" \
  --recursive --delete-unmatched-destination-objects \
  --include-managed-folders \
  --project "$PROJECT_ID" --quiet

echo "==> [2/2] Forcing new Cloud Run revision so the FST reloads..."
# Bumping any annotation/env triggers a new revision. We use a timestamp env
# var so the deploy is idempotent but always changes the revision.
gcloud run services update "$SERVICE_NAME" \
  --project "$PROJECT_ID" --region "$REGION" \
  --update-env-vars="DICT_RELOADED_AT=$(date -u +%Y%m%dT%H%M%SZ)" \
  --quiet

URL="$(gcloud run services describe "$SERVICE_NAME" \
  --project "$PROJECT_ID" --region "$REGION" --format='value(status.url)')"

echo
echo "Done."
echo "    URL:  $URL"
echo "    Try:  curl \"$URL/tag?text=...\""
