#!/usr/bin/env bash
# Build, push, and deploy FST Guard Rails (Java Text Tagger) to AWS ECS Fargate.
#
# Prereqs:
#   - aws CLI v2 configured (aws configure)
#   - docker installed and running
#   - You have rights to create ECR/ECS/IAM/ALB/CloudWatch resources
#
# Usage:
#   AWS_REGION=us-east-1 \
#   VPC_ID=vpc-xxxx \
#   SUBNET_IDS=subnet-aaa,subnet-bbb \
#   ./deploy.sh

set -euo pipefail

AWS_REGION="${AWS_REGION:?Set AWS_REGION, e.g. us-east-1}"
VPC_ID="${VPC_ID:?Set VPC_ID (use the default VPC if you don\'t have one)}"
SUBNET_IDS="${SUBNET_IDS:?Set SUBNET_IDS as comma-separated public subnet IDs in 2+ AZs}"

REPO_NAME="${REPO_NAME:-fst-guardrails}"
SERVICE_NAME="${SERVICE_NAME:-fst-guardrails}"
IMAGE_TAG="${IMAGE_TAG:-$(date +%Y%m%d-%H%M%S)}"
ECR_STACK="${ECR_STACK:-fst-guardrails-ecr}"
ECS_STACK="${ECS_STACK:-fst-guardrails-ecs}"
DESIRED_COUNT="${DESIRED_COUNT:-2}"

HERE="$(cd "$(dirname "$0")" && pwd)"
PROJECT_ROOT="$(cd "$HERE/.." && pwd)"
ACCOUNT_ID="$(aws sts get-caller-identity --query Account --output text)"
ECR_URI="${ACCOUNT_ID}.dkr.ecr.${AWS_REGION}.amazonaws.com/${REPO_NAME}"

echo "==> Region:   $AWS_REGION"
echo "==> Account:  $ACCOUNT_ID"
echo "==> Image:    ${ECR_URI}:${IMAGE_TAG}"

echo "==> [1/4] Ensuring ECR repository stack exists ($ECR_STACK)..."
aws cloudformation deploy \
  --region "$AWS_REGION" \
  --stack-name "$ECR_STACK" \
  --template-file "$HERE/cloudformation/ecr.yaml" \
  --parameter-overrides "RepositoryName=$REPO_NAME" \
  --no-fail-on-empty-changeset

echo "==> [2/4] Building and pushing Docker image..."
aws ecr get-login-password --region "$AWS_REGION" \
  | docker login --username AWS --password-stdin "${ACCOUNT_ID}.dkr.ecr.${AWS_REGION}.amazonaws.com"

docker build --platform linux/amd64 -t "${REPO_NAME}:${IMAGE_TAG}" "$PROJECT_ROOT"
docker tag  "${REPO_NAME}:${IMAGE_TAG}" "${ECR_URI}:${IMAGE_TAG}"
docker tag  "${REPO_NAME}:${IMAGE_TAG}" "${ECR_URI}:latest"
docker push "${ECR_URI}:${IMAGE_TAG}"
docker push "${ECR_URI}:latest"

echo "==> [3/4] Deploying ECS Fargate stack ($ECS_STACK)..."
aws cloudformation deploy \
  --region "$AWS_REGION" \
  --stack-name "$ECS_STACK" \
  --template-file "$HERE/cloudformation/ecs-fargate.yaml" \
  --capabilities CAPABILITY_IAM \
  --parameter-overrides \
    "ServiceName=$SERVICE_NAME" \
    "ImageUri=${ECR_URI}:${IMAGE_TAG}" \
    "VpcId=$VPC_ID" \
    "SubnetIds=$SUBNET_IDS" \
    "DesiredCount=$DESIRED_COUNT" \
  --no-fail-on-empty-changeset

echo "==> [4/4] Outputs:"
aws cloudformation describe-stacks \
  --region "$AWS_REGION" \
  --stack-name "$ECS_STACK" \
  --query "Stacks[0].Outputs" \
  --output table

echo
echo "Done. Try:  curl \$(aws cloudformation describe-stacks --region $AWS_REGION --stack-name $ECS_STACK --query \"Stacks[0].Outputs[?OutputKey=='HealthUrl'].OutputValue\" --output text)"
