#!/usr/bin/env bash
# Upload local CSV dictionaries to the EFS volume mounted at /data, then
# trigger a rolling restart of the tagger service so it loads them.
#
# Flow:
#   1. `aws s3 sync` your local data dir → a staging S3 bucket
#   2. `aws ecs run-task` the uploader task → S3-syncs into EFS:/data
#   3. `aws ecs update-service --force-new-deployment` → tagger reloads
#
# Prereqs:
#   - The ECS stack was deployed with EnableEfs=true
#   - aws CLI v2 configured
#
# Usage:
#   AWS_REGION=us-east-1 \
#   ECS_STACK=fst-guardrails-ecs \
#   STAGING_BUCKET=my-account-fst-staging \
#   DATA_DIR=../data \
#   ./upload-dictionaries.sh

set -euo pipefail

AWS_REGION="${AWS_REGION:?Set AWS_REGION}"
ECS_STACK="${ECS_STACK:-fst-guardrails-ecs}"
STAGING_BUCKET="${STAGING_BUCKET:?Set STAGING_BUCKET (an S3 bucket you own in $AWS_REGION)}"
S3_PREFIX="${S3_PREFIX:-dictionaries}"
SERVICE_NAME="${SERVICE_NAME:-fst-guardrails}"
HERE="$(cd "$(dirname "$0")" && pwd)"
DATA_DIR="${DATA_DIR:-$HERE/../data}"

if [[ ! -d "$DATA_DIR" ]]; then
  echo "ERROR: DATA_DIR '$DATA_DIR' does not exist." >&2
  exit 1
fi

echo "==> Reading stack outputs from $ECS_STACK..."
get_output() {
  aws cloudformation describe-stacks --region "$AWS_REGION" --stack-name "$ECS_STACK" \
    --query "Stacks[0].Outputs[?OutputKey=='$1'].OutputValue" --output text
}

CLUSTER="$(get_output ClusterName)"
UPLOADER_TASK_DEF="$(get_output UploaderTaskDefinitionArn)"
SERVICE_SG="$(get_output ServiceSecurityGroupId)"

if [[ -z "$UPLOADER_TASK_DEF" || "$UPLOADER_TASK_DEF" == "None" ]]; then
  echo "ERROR: stack $ECS_STACK was not deployed with EnableEfs=true." >&2
  echo "       Re-deploy with: --parameter-overrides EnableEfs=true ..." >&2
  exit 1
fi

# We need the same subnets the service runs in to launch the uploader task.
SUBNETS_JSON="$(aws ecs describe-services --region "$AWS_REGION" --cluster "$CLUSTER" \
  --services "$SERVICE_NAME" \
  --query "services[0].networkConfiguration.awsvpcConfiguration.subnets" --output json)"
SUBNETS_CSV="$(echo "$SUBNETS_JSON" | python3 -c 'import json,sys; print(",".join(json.load(sys.stdin)))')"

echo "==> Cluster:        $CLUSTER"
echo "==> Uploader task:  $UPLOADER_TASK_DEF"
echo "==> Service SG:     $SERVICE_SG"
echo "==> Subnets:        $SUBNETS_CSV"
echo "==> Local data dir: $DATA_DIR"
echo "==> S3 staging:     s3://$STAGING_BUCKET/$S3_PREFIX/"

echo "==> [1/3] Syncing local CSVs to S3..."
aws s3 sync "$DATA_DIR/" "s3://${STAGING_BUCKET}/${S3_PREFIX}/" \
  --region "$AWS_REGION" --exclude "*" --include "*.csv" --delete

echo "==> [2/3] Launching uploader task to copy S3 → EFS:/data..."
TASK_ARN="$(aws ecs run-task --region "$AWS_REGION" \
  --cluster "$CLUSTER" \
  --task-definition "$UPLOADER_TASK_DEF" \
  --launch-type FARGATE \
  --network-configuration "awsvpcConfiguration={subnets=[${SUBNETS_CSV//,/,}],securityGroups=[$SERVICE_SG],assignPublicIp=ENABLED}" \
  --overrides "{\"containerOverrides\":[{\"name\":\"uploader\",\"command\":[\"s3\",\"sync\",\"s3://${STAGING_BUCKET}/${S3_PREFIX}/\",\"/data/\",\"--delete\"]}]}" \
  --query 'tasks[0].taskArn' --output text)"

echo "    Task: $TASK_ARN"
echo "    Waiting for uploader to finish..."
aws ecs wait tasks-stopped --region "$AWS_REGION" --cluster "$CLUSTER" --tasks "$TASK_ARN"

EXIT_CODE="$(aws ecs describe-tasks --region "$AWS_REGION" --cluster "$CLUSTER" --tasks "$TASK_ARN" \
  --query 'tasks[0].containers[0].exitCode' --output text)"
if [[ "$EXIT_CODE" != "0" ]]; then
  echo "ERROR: uploader task exited with code $EXIT_CODE." >&2
  echo "       Check CloudWatch Logs group /ecs/${SERVICE_NAME} (stream prefix 'uploader')." >&2
  exit 1
fi

echo "==> [3/3] Forcing rolling redeploy of tagger so new dictionaries load..."
aws ecs update-service --region "$AWS_REGION" \
  --cluster "$CLUSTER" --service "$SERVICE_NAME" \
  --force-new-deployment >/dev/null

echo
echo "Done. Watch progress:"
echo "    aws ecs describe-services --region $AWS_REGION --cluster $CLUSTER --services $SERVICE_NAME --query 'services[0].deployments'"
