#!/usr/bin/env bash
# One-shot deploy of FST Guard Rails to Google Cloud Run.
#
# - Builds the container image with Cloud Build (no local Docker required)
# - Pushes to Artifact Registry
# - Deploys to Cloud Run with public HTTPS, autoscaling, /health probe
# - Optional: ENABLE_GCS=true mounts a GCS bucket at /data for hot-swappable
#   dictionaries (Cloud Run GCS volumes, requires gen2 execution environment)
#
# Prereqs:
#   - gcloud CLI installed and logged in:  gcloud auth login
#   - A project with billing enabled:      gcloud config set project <PROJECT_ID>
#
# Usage:
#   PROJECT_ID=my-proj REGION=us-central1 ./deploy.sh
#   # with hot-swappable dictionaries:
#   PROJECT_ID=my-proj REGION=us-central1 ENABLE_GCS=true ./deploy.sh

set -euo pipefail

PROJECT_ID="${PROJECT_ID:-$(gcloud config get-value project 2>/dev/null)}"
[[ -z "$PROJECT_ID" || "$PROJECT_ID" == "(unset)" ]] && \
  { echo "Set PROJECT_ID or run: gcloud config set project <id>" >&2; exit 1; }

REGION="${REGION:-us-central1}"
SERVICE_NAME="${SERVICE_NAME:-fst-guardrails}"
REPO_NAME="${REPO_NAME:-fst-guardrails}"
IMAGE_TAG="${IMAGE_TAG:-$(date +%Y%m%d-%H%M%S)}"
MIN_INSTANCES="${MIN_INSTANCES:-1}"
MAX_INSTANCES="${MAX_INSTANCES:-5}"
CPU="${CPU:-1}"
MEMORY="${MEMORY:-1Gi}"
CONCURRENCY="${CONCURRENCY:-50}"
ENABLE_GCS="${ENABLE_GCS:-false}"
GCS_BUCKET="${GCS_BUCKET:-${PROJECT_ID}-${SERVICE_NAME}-data}"

HERE="$(cd "$(dirname "$0")" && pwd)"
PROJECT_ROOT="$(cd "$HERE/.." && pwd)"
IMAGE="${REGION}-docker.pkg.dev/${PROJECT_ID}/${REPO_NAME}/${SERVICE_NAME}:${IMAGE_TAG}"

echo "==> Project:  $PROJECT_ID"
echo "==> Region:   $REGION"
echo "==> Service:  $SERVICE_NAME"
echo "==> Image:    $IMAGE"
echo "==> GCS mode: $ENABLE_GCS"

echo "==> [1/5] Enabling required APIs (idempotent)..."
gcloud services enable \
  run.googleapis.com \
  cloudbuild.googleapis.com \
  artifactregistry.googleapis.com \
  storage.googleapis.com \
  --project "$PROJECT_ID" --quiet

echo "==> [2/5] Ensuring Artifact Registry repo exists..."
if ! gcloud artifacts repositories describe "$REPO_NAME" \
      --location "$REGION" --project "$PROJECT_ID" >/dev/null 2>&1; then
  gcloud artifacts repositories create "$REPO_NAME" \
    --repository-format=docker --location "$REGION" \
    --description "FST Guard Rails images" --project "$PROJECT_ID"
fi

echo "==> [3/5] Building image with Cloud Build (no local Docker)..."
gcloud builds submit "$PROJECT_ROOT" \
  --tag "$IMAGE" \
  --project "$PROJECT_ID" --quiet

GCS_FLAGS=()
if [[ "$ENABLE_GCS" == "true" ]]; then
  echo "==> [4a/5] Ensuring GCS bucket gs://$GCS_BUCKET exists..."
  if ! gcloud storage buckets describe "gs://$GCS_BUCKET" --project "$PROJECT_ID" >/dev/null 2>&1; then
    gcloud storage buckets create "gs://$GCS_BUCKET" \
      --location "$REGION" --uniform-bucket-level-access \
      --project "$PROJECT_ID"
  fi

  echo "==> [4b/5] Seeding bucket with bundled CSVs (if empty)..."
  if [[ -z "$(gcloud storage ls "gs://$GCS_BUCKET/" --project "$PROJECT_ID" 2>/dev/null)" ]]; then
    gcloud storage rsync "$PROJECT_ROOT/data/" "gs://$GCS_BUCKET/" \
      --recursive --project "$PROJECT_ID" --quiet
  fi

  GCS_FLAGS=(
    --execution-environment=gen2
    --add-volume="name=data,type=cloud-storage,bucket=$GCS_BUCKET"
    --add-volume-mount="volume=data,mount-path=/data"
    --update-env-vars="DATA=/data"
  )
else
  GCS_FLAGS=(--update-env-vars="DATA=/app/data")
fi

echo "==> [5/5] Deploying Cloud Run service..."
gcloud run deploy "$SERVICE_NAME" \
  --project "$PROJECT_ID" \
  --region "$REGION" \
  --image "$IMAGE" \
  --port 8080 \
  --cpu "$CPU" --memory "$MEMORY" \
  --min-instances "$MIN_INSTANCES" --max-instances "$MAX_INSTANCES" \
  --concurrency "$CONCURRENCY" \
  --allow-unauthenticated \
  --update-env-vars="PORT=8080" \
  "${GCS_FLAGS[@]}" \
  --quiet

URL="$(gcloud run services describe "$SERVICE_NAME" \
  --project "$PROJECT_ID" --region "$REGION" --format='value(status.url)')"

echo
echo "==> Deployed."
echo "    URL:    $URL"
echo "    Health: $URL/health"
echo "    Try:    curl \"$URL/tag?text=Ada+Lovelace+uses+Apache+Lucene\""
if [[ "$ENABLE_GCS" == "true" ]]; then
  echo "    Bucket: gs://$GCS_BUCKET (mounted at /data — use ./upload-dictionaries.sh to update)"
fi
