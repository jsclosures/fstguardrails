# Deploying FST Guard Rails to AWS

This folder contains Infrastructure-as-Code and a one-shot deploy script for
running the Java Text Tagger as a stateless HTTP service on AWS.

## Recommended path: ECS Fargate behind an ALB

Best fit for this service because it is:

- Containerized and stateless (state lives in the Lucene FST in RAM)
- HTTP-only with a `/health` endpoint
- Latency-sensitive but cheap to scale horizontally

### Architecture

```
Internet ──► ALB (HTTP/HTTPS) ──► Fargate tasks (tagger.jar serve)
                                        │
                                        └─► CloudWatch Logs (/ecs/fst-guardrails)
```

- **ECR** stores the container image.
- **ECS Cluster (Fargate)** runs N copies of the tagger task.
- **Application Load Balancer** terminates HTTP (and optionally HTTPS) and
  health-checks `/health`.
- **Application Auto Scaling** scales tasks on average CPU (target 60%).
- **CloudWatch Logs** captures stdout/stderr.

### Files

| File | Purpose |
|---|---|
| `cloudformation/ecr.yaml` | ECR repository with image scanning + lifecycle policy |
| `cloudformation/ecs-fargate.yaml` | Cluster, task def, ALB, security groups, autoscaling |
| `deploy.sh` | One-shot: build, push, deploy both stacks |
| `apprunner/apprunner.yaml` | Alternative single-service App Runner config |

### Prerequisites

- AWS CLI v2, configured (`aws configure` or SSO)
- Docker Desktop / Docker Engine running
- An AWS account with rights to create ECR / ECS / IAM / ELB / CloudWatch / VPC SG resources
- A VPC with **at least two public subnets in different AZs**
  (the default VPC in any region works)

Find your default VPC and subnets:

```bash
AWS_REGION=us-east-1
aws ec2 describe-vpcs --region $AWS_REGION \
  --filters Name=isDefault,Values=true --query "Vpcs[0].VpcId" --output text

aws ec2 describe-subnets --region $AWS_REGION \
  --filters Name=vpc-id,Values=<vpc-id> Name=default-for-az,Values=true \
  --query "Subnets[].SubnetId" --output text
```

### One-shot deploy

```bash
cd fstguardrails/aws

AWS_REGION=us-east-1 \
VPC_ID=vpc-0123456789abcdef0 \
SUBNET_IDS=subnet-aaa,subnet-bbb \
./deploy.sh
```

The script will:

1. Deploy the ECR stack (`fst-guardrails-ecr`) if not already present.
2. Build the Docker image for `linux/amd64` and push it to ECR with a
   timestamp tag and `:latest`.
3. Deploy the ECS stack (`fst-guardrails-ecs`).
4. Print the ALB URL.

Test it:

```bash
URL=$(aws cloudformation describe-stacks --region $AWS_REGION \
  --stack-name fst-guardrails-ecs \
  --query "Stacks[0].Outputs[?OutputKey=='ServiceUrl'].OutputValue" --output text)

curl "$URL/health"
curl "$URL/tag?text=Ada+Lovelace+uses+Apache+Lucene+in+New+York+City"
```

### Optional: HTTPS

1. Request an ACM certificate in the same region for your domain.
2. Validate it (DNS, easiest with Route 53).
3. Re-deploy with the cert ARN:

```bash
aws cloudformation deploy \
  --region $AWS_REGION \
  --stack-name fst-guardrails-ecs \
  --template-file cloudformation/ecs-fargate.yaml \
  --capabilities CAPABILITY_IAM \
  --parameter-overrides \
    ImageUri=<your-ecr-uri>:latest \
    VpcId=$VPC_ID \
    SubnetIds=$SUBNET_IDS \
    CertificateArn=arn:aws:acm:us-east-1:1234:certificate/abcd
```

Then point a Route 53 alias (or any DNS A/AAAA record) at the ALB DNS name.

### Updating the service

Re-run `./deploy.sh`. ECS does a rolling deploy with `MinHealthyPercent=50`
and `MaxPercent=200`, so there is no downtime as long as `DesiredCount >= 2`.

### Hot-swappable dictionaries (EFS)

The base deploy bundles `data/*.csv` into the image, so changing CSVs means
rebuilding. Set **`EnableEfs=true`** at deploy time and the template will:

- Create an encrypted EFS file system + an access point rooted at `/data`
- Place an EFS mount target in each of the first two `SubnetIds`
- Open NFS (TCP 2049) from the Fargate task SG only
- Mount the access point at `/data` in the tagger container and set `DATA=/data`
- Add a one-shot **uploader task** (`public.ecr.aws/aws-cli/aws-cli`) you
  invoke to copy from S3 → EFS

Re-deploy with EFS:

```bash
cd fstguardrails/aws
AWS_REGION=us-east-1 VPC_ID=vpc-... SUBNET_IDS=subnet-a,subnet-b \
  ./deploy.sh
# then enable EFS — re-run with the extra parameter:
aws cloudformation deploy --region $AWS_REGION \
  --stack-name fst-guardrails-ecs \
  --template-file cloudformation/ecs-fargate.yaml \
  --capabilities CAPABILITY_IAM \
  --parameter-overrides \
    ImageUri=<ecr-uri>:latest VpcId=$VPC_ID SubnetIds=$SUBNET_IDS \
    EnableEfs=true
```

Upload dictionaries any time after that:

```bash
AWS_REGION=us-east-1 \
STAGING_BUCKET=my-account-fst-staging \
DATA_DIR=../data \
./upload-dictionaries.sh
```

The script S3-syncs your local `data/` to the staging bucket, runs the
uploader task to mirror it into EFS, then forces a rolling redeploy of the
tagger so the new FST loads. The tagger reloads its FST at JVM startup, so
the redeploy step is required — there's no in-process file watcher.

> The first deploy with `EnableEfs=true` takes longer (~3–5 extra minutes)
> because EFS mount targets need to come online before the tagger task can
> start. Subsequent deploys are fast.

### Tearing it down

```bash
aws cloudformation delete-stack --region $AWS_REGION --stack-name fst-guardrails-ecs
aws cloudformation wait stack-delete-complete --region $AWS_REGION --stack-name fst-guardrails-ecs

# Delete images first if you want to also drop the ECR repo
aws ecr batch-delete-image --region $AWS_REGION --repository-name fst-guardrails \
  --image-ids "$(aws ecr list-images --region $AWS_REGION --repository-name fst-guardrails --query 'imageIds[*]' --output json)"
aws cloudformation delete-stack --region $AWS_REGION --stack-name fst-guardrails-ecr
```

---

## Simpler alternative: AWS App Runner

Use this if you want the smallest possible setup (no VPC, no ALB, no IAM
gymnastics) and are OK with App Runner's constraints (single container, ~200ms
cold-starts on scale-to-zero, public-only by default).

1. Push the image to ECR (let `deploy.sh` do steps 1–2, then Ctrl-C).
2. Console → App Runner → Create service → "Container registry" → pick the ECR image.
3. Apply the settings under `apprunner/apprunner.yaml` (port `8080`, env
   `DATA=/app/data`, health check path `/health`).
4. App Runner gives you an HTTPS URL automatically.

CLI equivalent:

```bash
aws apprunner create-service \
  --region $AWS_REGION \
  --service-name fst-guardrails \
  --source-configuration "ImageRepository={ImageIdentifier=<ecr-uri>:latest,ImageRepositoryType=ECR,ImageConfiguration={Port=8080,RuntimeEnvironmentVariables={PORT=8080,DATA=/app/data}}},AutoDeploymentsEnabled=true,AuthenticationConfiguration={AccessRoleArn=<role-arn>}" \
  --instance-configuration "Cpu=1024,Memory=2048" \
  --health-check-configuration "Protocol=HTTP,Path=/health,Interval=10,Timeout=5,HealthyThreshold=1,UnhealthyThreshold=3"
```

(You need an `AppRunnerECRAccessRole` first — App Runner will offer to create
it on the first console deploy, easiest path.)

---

## Other AWS options (not provided here, but valid)

| Option | When it fits | Notes |
|---|---|---|
| **EC2 + systemd** | Single-node dev/test, lowest cost | Run `java -jar tagger.jar serve` under systemd; put an Elastic IP in front. |
| **EKS** | You already run Kubernetes at scale | The same Docker image works; write a Deployment + Service + Ingress. |
| **Lambda (container image)** | Bursty, low-traffic taggers | Cold-start hurts: FST + dictionary load happens on every cold init. Only viable if you keep provisioned concurrency. Not recommended for latency-sensitive use. |

## Sizing guidance

- The bundled sample data builds an FST of ~33 KB. Even with multi-MB
  dictionaries, total RSS is typically **< 500 MB**.
- Start with `Cpu=512` / `Memory=1024` (the default in the template). Scale
  CPU up before memory — tagging is CPU-bound, not memory-bound.
- The autoscaling policy targets **60% average CPU** with min = `DesiredCount`,
  max = `10`. Adjust `MaxCapacity` in `ecs-fargate.yaml` if you need more.

## Cost (rough, us-east-1, on-demand)

For 2 tasks at 0.5 vCPU / 1 GB running 24×7:
- Fargate compute: ~$18/mo
- ALB: ~$17/mo + LCU
- CloudWatch Logs: a few $/mo at typical volume
- ECR: pennies for a 6 MB image

Total floor: **~$35–45/month**. Scale-out is roughly $9/mo per added 0.5-vCPU
task. App Runner is comparable for a single instance and cheaper if you let it
scale to zero.
