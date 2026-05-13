# Deploying FST Guard Rails to GCP

A small, opinionated setup that runs the Java Text Tagger as a managed
HTTPS service on **Google Cloud Run** — the simplest GCP path for a
stateless containerized HTTP service. You get:

- Public HTTPS URL out of the box (Google-managed certs)
- Request-concurrency autoscaling, optional scale-to-zero
- Built-in revisions + traffic splitting for safe rollouts
- No VPC / load-balancer / IAM scaffolding to manage
- **Hot-swappable dictionaries** via a Cloud Storage bucket mounted at `/data`
  (Cloud Run's gen2 GCS volume support — no init container, no Filestore)

## Architecture

```
Internet ──HTTPS──► Cloud Run revision (tagger.jar serve)
                              │
                              └─► Cloud Logging (automatic)
   Image pulled from ──► Artifact Registry
   /data mounted from ──► Cloud Storage bucket  (when ENABLE_GCS=true)
```

## Files

| File | Purpose |
|---|---|
| `deploy.sh` | One-shot: enable APIs → Artifact Registry → Cloud Build → Cloud Run deploy (with optional GCS volume) |
| `upload-dictionaries.sh` | `gcloud storage rsync` local CSVs → bucket, then force a new revision so the FST reloads |

## Prerequisites

- [`gcloud` CLI](https://cloud.google.com/sdk/docs/install) installed
- A GCP project with **billing enabled**
- Logged in: `gcloud auth login`
- Default project set: `gcloud config set project <PROJECT_ID>`

You do **not** need Docker installed locally — `deploy.sh` builds the image
remotely with Cloud Build using the Dockerfile already in the repo.

## Simple deploy (image-bundled dictionaries)

```bash
cd fstguardrails/gcp
PROJECT_ID=my-project REGION=us-central1 ./deploy.sh
```

About 3–5 minutes end to end. The script will:

1. Enable Run, Cloud Build, Artifact Registry, and Storage APIs
2. Create an Artifact Registry repo (idempotent)
3. Build & push the image with Cloud Build
4. Deploy the Cloud Run service with public HTTPS

Test:

```bash
URL=$(gcloud run services describe fst-guardrails \
  --region us-central1 --format='value(status.url)')

curl "$URL/health"
curl "$URL/tag?text=Ada+Lovelace+uses+Apache+Lucene+in+New+York+City"
```

## Hot-swappable deploy (GCS volume at /data)

Set `ENABLE_GCS=true` and the script will additionally:

- Create a regional Cloud Storage bucket (`<project>-fst-guardrails-data`)
- Seed it with the bundled `data/*.csv` on first deploy
- Deploy with `--execution-environment=gen2` and:
  - `--add-volume name=data,type=cloud-storage,bucket=<bucket>`
  - `--add-volume-mount volume=data,mount-path=/data`
  - `--update-env-vars DATA=/data`

```bash
cd fstguardrails/gcp
PROJECT_ID=my-project REGION=us-central1 ENABLE_GCS=true ./deploy.sh
```

Update dictionaries any time after that:

```bash
PROJECT_ID=my-project REGION=us-central1 \
DATA_DIR=../data \
./upload-dictionaries.sh
```

The script `gcloud storage rsync`s your local CSVs to the bucket, then bumps
a `DICT_RELOADED_AT` env var on the service to force a new revision. The
tagger reloads its FST at JVM startup, so the new revision step is required
— there's no in-process file watcher.

> **Why force a new revision instead of restarting in place?** Cloud Run
> doesn't expose an in-place restart for revisions. Pushing a new revision is
> the canonical pattern: it's instant, costs nothing, and traffic shifts
> automatically with zero downtime when `MIN_INSTANCES >= 1`.

## Tunable knobs

Override via environment variables before running `deploy.sh`:

| Var | Default | Notes |
|---|---|---|
| `PROJECT_ID` | `gcloud config` value | Required if not set globally |
| `REGION` | `us-central1` | Any Cloud Run region |
| `SERVICE_NAME` | `fst-guardrails` | Cloud Run service name |
| `REPO_NAME` | `fst-guardrails` | Artifact Registry repo |
| `IMAGE_TAG` | timestamp | |
| `MIN_INSTANCES` | `1` | Set to `0` for scale-to-zero (cold-start trade-off) |
| `MAX_INSTANCES` | `5` | Concurrency-based autoscale |
| `CPU` | `1` | vCPU per instance |
| `MEMORY` | `1Gi` | Pair appropriately with `CPU` |
| `CONCURRENCY` | `50` | Concurrent requests per instance before autoscaling |
| `ENABLE_GCS` | `false` | Mount GCS bucket at `/data` |
| `GCS_BUCKET` | `<project>-<service>-data` | Auto-created if missing |

## Sizing guidance

- The bundled sample data uses ~33 KB of FST RAM. Even with multi-MB
  dictionaries, total RSS is typically **< 500 MB**.
- Tagging is CPU-bound. Cloud Run gives full vCPU during request handling
  by default; `--cpu=1` is a good starting point.
- Concurrency 50/instance is conservative for an FST tagger (it's CPU-bound,
  not I/O-bound) — bump it if your traffic pattern allows.

## Updating the service

Re-run `./deploy.sh` — Cloud Run creates a new revision and shifts 100% of
traffic to it (no downtime when `MIN_INSTANCES >= 1`).

To roll back:

```bash
gcloud run revisions list --service fst-guardrails --region us-central1
gcloud run services update-traffic fst-guardrails --region us-central1 \
  --to-revisions <old-revision>=100
```

## Viewing logs

```bash
# Tail live logs
gcloud beta run services logs tail fst-guardrails --region us-central1

# Or query Cloud Logging
gcloud logging read \
  'resource.type=cloud_run_revision AND resource.labels.service_name=fst-guardrails' \
  --limit 50 --format json
```

## Custom domain + managed cert

```bash
gcloud beta run domain-mappings create \
  --service fst-guardrails --domain tagger.yourdomain.com \
  --region us-central1
```

Add the DNS record `gcloud` prints, and Cloud Run provisions and renews the
cert automatically.

## Tearing it down

```bash
gcloud run services delete fst-guardrails --region us-central1 --quiet
gcloud artifacts repositories delete fst-guardrails --location us-central1 --quiet
gcloud storage rm -r "gs://${PROJECT_ID}-fst-guardrails-data" --quiet  # if you used --enable-gcs
```

---

## Cost (rough, us-central1, on-demand)

For 1 instance at 1 vCPU / 1 GiB and `MIN_INSTANCES=1` running 24×7:

- Cloud Run compute: ~$25/mo (always-on); pennies/month if you set `MIN_INSTANCES=0`
- Artifact Registry: pennies for a 6 MB image
- Cloud Storage (5 GiB Standard regional): ~$0.10/mo
- Cloud Logging: free for typical volumes (50 GiB ingest/mo free tier)

**Floor:** ~$25/mo always-on, or **~$2–5/mo** with scale-to-zero for
low-traffic workloads. Cloud Run is comparable to AWS Fargate / Azure
Container Apps for steady traffic and meaningfully cheaper for bursty
workloads thanks to per-100ms billing and scale-to-zero.

## Other GCP options (not provided here)

| Option | When it fits | Notes |
|---|---|---|
| **GKE Autopilot** | You already run Kubernetes at scale | Same Docker image; write a Deployment + Service + Ingress |
| **Compute Engine + systemd** | Single-node dev/test, lowest cost | `java -jar tagger.jar serve` under systemd; pin a static IP |
| **App Engine Flex** | Legacy GCP standardization | Cloud Run is its supported successor — no benefit for new work |
| **Cloud Functions (2nd gen)** | Bursty, event-driven only | Cold-start hurts: FST + dictionary load happens on every cold init. Not recommended for latency-sensitive use |
