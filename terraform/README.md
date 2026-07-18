# Infrastructure (OpenTofu)

GKE stack for model-llmsecops: dedicated VPC with Cloud NAT, a zonal GKE cluster
with two node pools, Artifact Registry, and a GCS model bucket wired to
Workload Identity.

**This is OpenTofu, not Terraform.** Use `tofu`. `backend.tf` references
`var.state_bucket` inside the backend block, which relies on OpenTofu's early
variable evaluation — Terraform rejects variables in backend blocks at any
version and will fail on `init`.

## Bootstrap (once per project)

The state bucket cannot be created by the configuration that stores its state in
it, so create it by hand:

```bash
PROJECT=your-gcp-project
BUCKET=your-tfstate-bucket

gcloud storage buckets create "gs://$BUCKET" \
  --project="$PROJECT" --location=us-central1 \
  --uniform-bucket-level-access
gcloud storage buckets update "gs://$BUCKET" --versioning
```

Then:

```bash
cp terraform.tfvars.example terraform.tfvars
# set project_id and state_bucket
```

`terraform.tfvars` is gitignored. Because `state_bucket` is read during early
evaluation, `tofu init` picks it up from that file with no flags.

## Usage

```bash
tofu init          # no -backend-config needed
tofu test          # guardrail tests, mocked providers, no cloud calls
tofu plan
tofu apply
```

Re-run `tofu init` after adding or changing a `module` block **in a test file** —
those modules are installed separately from the root configuration, and `tofu
test` fails with "Module not installed" until you do.

Without a `terraform.tfvars`, pass the values explicitly:

```bash
tofu init -var="state_bucket=$BUCKET"
tofu plan -var="project_id=$PROJECT" -var="state_bucket=$BUCKET"
```

## Layout

| Path | Contents |
|---|---|
| `main.tf` | API enablement + module wiring |
| `modules/network/` | VPC, subnet with secondary ranges, router, Cloud NAT |
| `modules/gke/` | Cluster, app + serve node pools, node SA and IAM |
| `modules/artifact_registry/` | Docker repo for the app image |
| `modules/storage/` | Model bucket, app SA, Workload Identity binding |
| `modules/loadbalancer/` | Static IP, Cloud Armor, optional cert + DNS (off by default) |
| `policy/` | Conftest/OPA policies evaluated against plan JSON |
| `tests/` | `tofu test` guardrails |

## Cost notes

The serve pool (`e2-highmem-4`, for vLLM) autoscales from **0**, so it costs
nothing while idle. Keep it that way — it is the expensive node.

The load balancer is **off by default** (`enable_load_balancer = false`) and
costs roughly $30/mo when on (~$18 ALB + ~$12 Cloud Armor Standard).
`kubectl port-forward` is free and is the right answer until someone outside the
cluster needs to reach the app. Enabling it without a real domain gives you an
IP and a Cloud Armor policy but no HTTPS, since a Google-managed certificate
requires a domain that resolves to the LB IP.

## Policy checks

```bash
tofu plan -out=tfplan.binary
tofu show -json tfplan.binary > tfplan.json
conftest test --policy policy/ tfplan.json
trivy config .
checkov -d .
```

The plan JSON schema is identical to Terraform's, so the Rego policies and the
inline `#tfsec:ignore` / `#checkov:skip` suppressions work unchanged.

## Teardown

```bash
tofu destroy
```

`deletion_protection = false` on the cluster, `force_destroy = true` on the model
bucket, and `disable_on_destroy = false` on the APIs are all set deliberately so
this succeeds without manual cleanup.
