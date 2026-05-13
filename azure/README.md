# Deploying FST Guard Rails to Azure

A small, opinionated setup that runs the Java Text Tagger as a managed
HTTPS service on **Azure Container Apps** — chosen because it gives you:

- Public HTTPS URL out of the box (no cert wrangling)
- HTTP-concurrency autoscaling, optional scale-to-zero
- No VPC / load-balancer / IAM scaffolding to manage
- Built-in revisions, rolling deploys, and Log Analytics

## Architecture

```
Internet ──HTTPS──► Container Apps ingress ──► Container App replicas (tagger.jar serve)
                                                      │
                                                      └─► Log Analytics workspace
                                  Image pulled from ──► Azure Container Registry (ACR)
```

## Files

| File | Purpose |
|---|---|
| `main.bicep` | Bicep template: Log Analytics + Container Apps Environment + Container App + ACR pull role |
| `deploy.sh` | One-shot: resource group → ACR → remote image build → Bicep deploy |

## Prerequisites

- [Azure CLI](https://learn.microsoft.com/cli/azure/install-azure-cli) v2.50+
- An Azure subscription you can deploy to
- Logged in: `az login` (and `az account set -s <sub-id>` if you have multiple)

You do **not** need Docker installed locally — the script uses `az acr build`
to build the image remotely inside Azure.

## One-shot deploy

```bash
cd fstguardrails/azure
LOCATION=eastus ./deploy.sh
```

That's it. About 4–6 minutes end to end. The script will:

1. Create a resource group (`fst-guardrails-rg` by default)
2. Create an Azure Container Registry (Basic SKU)
3. Build the Docker image **remotely** in ACR (no local Docker needed)
4. Register the `Microsoft.App` and `Microsoft.OperationalInsights` providers
5. Deploy `main.bicep` — Log Analytics, Container Apps Environment, the Container App, and an `AcrPull` role assignment for its managed identity
6. Print the public HTTPS URL

Test it:

```bash
APP_URL=$(az containerapp show -n fst-guardrails -g fst-guardrails-rg \
  --query properties.configuration.ingress.fqdn -o tsv)

curl "https://$APP_URL/health"
curl "https://$APP_URL/tag?text=Ada+Lovelace+uses+Apache+Lucene+in+New+York+City"
```

## Tunable knobs

Override any of these as environment variables before running `deploy.sh`:

| Var | Default | Notes |
|---|---|---|
| `LOCATION` | `eastus` | Any Azure region that supports Container Apps |
| `RESOURCE_GROUP` | `fst-guardrails-rg` | |
| `ACR_NAME` | `fstguardrails<random>` | Must be globally unique, lowercase, 5–50 chars |
| `APP_NAME` | `fst-guardrails` | Used for Container App, log workspace, env |
| `IMAGE_TAG` | timestamp | Push a specific tag |
| `MIN_REPLICAS` | `1` | Set to `0` for scale-to-zero (cold-start trade-off) |
| `MAX_REPLICAS` | `5` | HTTP-concurrency-based autoscale |

Bicep params (edit `main.bicep` or pass `--parameters` directly to `az deployment group create`):

| Param | Default | Notes |
|---|---|---|
| `cpu` | `0.5` | vCPU per replica |
| `memory` | `1Gi` | Must pair correctly with `cpu` (CA quantization rules) |
| `targetPort` | `8080` | Matches the container's `PORT` env |
| `dataPath` | `/app/data` | Where the app reads CSV dictionaries |

## Sizing guidance

- The bundled sample data uses ~33 KB of FST RAM. Even with multi-MB
  dictionaries, total RSS is typically **< 500 MB**.
- Tagging is CPU-bound. Scale CPU before memory.
- The autoscale rule fires at **50 concurrent HTTP requests per replica**.

## Updating the service

Re-run `./deploy.sh` — Container Apps creates a new revision and shifts
traffic to it (no downtime when `MIN_REPLICAS >= 1`).

To roll back:

```bash
az containerapp revision list -n fst-guardrails -g fst-guardrails-rg -o table
az containerapp ingress traffic set -n fst-guardrails -g fst-guardrails-rg \
  --revision-weight <old-revision-name>=100
```

## Viewing logs

```bash
# Tail live logs
az containerapp logs show -n fst-guardrails -g fst-guardrails-rg --follow

# Or query Log Analytics
az monitor log-analytics query \
  --workspace "$(az monitor log-analytics workspace show -g fst-guardrails-rg \
                  -n fst-guardrails-logs --query customerId -o tsv)" \
  --analytics-query "ContainerAppConsoleLogs_CL | where ContainerAppName_s == 'fst-guardrails' | order by TimeGenerated desc | take 50"
```

## Hot-swappable dictionaries (Azure Files)

The base deploy bundles `data/*.csv` into the image, so changing CSVs means
rebuilding. Set **`enableAzureFiles=true`** on the Bicep deploy and the
template will:

- Create a Standard_LRS Storage Account + a 5 GB Azure Files share
- Register it as a `dictionaries` storage definition on the Container Apps
  Environment (using the storage account key, kept inside the env)
- Mount the share at `/data` in the tagger container and set `DATA=/data`

Re-deploy with the flag set (after the first regular deploy):

```bash
cd fstguardrails/azure
LOCATION=eastus ./deploy.sh   # first time, builds image, etc.

# then turn on the share:
IMAGE=$(az containerapp show -n fst-guardrails -g fst-guardrails-rg \
  --query 'properties.template.containers[0].image' -o tsv)

az deployment group create \
  --resource-group fst-guardrails-rg \
  --template-file main.bicep \
  --parameters image="$IMAGE" enableAzureFiles=true
```

Upload dictionaries any time after that:

```bash
RESOURCE_GROUP=fst-guardrails-rg APP_NAME=fst-guardrails \
DATA_DIR=../data \
./upload-dictionaries.sh
```

The script `az storage file upload-batch`'s your local CSVs straight to the
share, then restarts the active revision so the FST reloads. The tagger
loads its FST at JVM startup, so the restart is required — there's no
in-process file watcher.

To swap a single CSV without re-uploading everything:

```bash
az storage file upload --account-name <storage-account> --account-key <key> \
  --share-name dictionaries --source ./data/intent.csv --path intent.csv
az containerapp revision restart -n fst-guardrails -g fst-guardrails-rg \
  --revision $(az containerapp revision list -n fst-guardrails -g fst-guardrails-rg \
                --query "[?properties.active].name | [0]" -o tsv)
```

> Container Apps caches storage definitions, so toggling `enableAzureFiles`
> from `true` back to `false` requires a fresh revision (the next deploy
> creates one automatically).

## Custom domain + managed cert

```bash
# 1. Bind hostname (you'll be asked to add a TXT/CNAME for verification)
az containerapp hostname add -n fst-guardrails -g fst-guardrails-rg \
  --hostname tagger.yourdomain.com

# 2. Issue and bind a free managed certificate
az containerapp hostname bind -n fst-guardrails -g fst-guardrails-rg \
  --hostname tagger.yourdomain.com \
  --environment fst-guardrails-env \
  --validation-method CNAME
```

## Tearing it down

```bash
az group delete --name fst-guardrails-rg --yes --no-wait
```

That removes everything (ACR, Container App, Environment, Log Analytics).

---

## Cost (rough, East US, pay-as-you-go)

For 1 replica at 0.5 vCPU / 1 GiB running 24×7:

- Container Apps compute: ~$15–18/mo (active usage; idle billing is much lower)
- ACR Basic: $5/mo
- Log Analytics: a few $/mo at typical volume

Total floor: **~$25/month**. Set `MIN_REPLICAS=0` to scale to zero between
requests and pay only for active execution time + a small per-request fee —
that drops the floor to roughly $5–10/month for low-traffic workloads.

## Other Azure options (not provided here)

| Option | When it fits | Notes |
|---|---|---|
| **Azure App Service (Web App for Containers)** | You already standardize on App Service / Premium plans | Slightly less elastic; B1 plan ~$13/mo, no scale-to-zero on Linux |
| **Azure Kubernetes Service (AKS)** | You already run Kubernetes at scale | Same Docker image; write a Deployment + Service + Ingress |
| **Azure Container Instances (ACI)** | One-off jobs / short tasks | Single container, no autoscaling, no managed HTTPS — use Container Apps instead for HTTP services |
| **Azure Spring Apps** | Spring Boot only | The tagger is a plain `java -jar`, not Spring; no benefit |
