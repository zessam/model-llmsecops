variable "project_id" {
  description = "GCP project ID to deploy into."
  type        = string
}

variable "region" {
  description = "GCP region for regional resources (Artifact Registry, bucket, subnet)."
  type        = string
  default     = "us-central1"
}

variable "zone" {
  # us-central1-a hit an "GCE out of resources" stockout on e2-highmem-4 (the serve
  # pool machine). The stockout is per-zone, so we relocate to us-central1-c, which
  # keeps the cheapest 32GB machine + the standard CPUS quota (no pricier N2 family,
  # no new N2_CPUS quota). If -c is also short, try -f then -b.
  description = "GCP zone for the (zonal) GKE cluster and its node pools. Must have serve_machine_type capacity."
  type        = string
  default     = "us-central1-c"
}

variable "cluster_name" {
  description = "Name of the GKE cluster (also used as a prefix for network/SA names)."
  type        = string
  default     = "model-llmsecops-cluster"

  # This name is a prefix for service account IDs — modules/gke builds
  # "<cluster_name>-nodes" and modules/storage builds "<cluster_name>-app".
  # A GCP service account ID is capped at 30 characters, so the longest suffix
  # ("-nodes", 6 chars) puts a hard ceiling of 24 on this value. The default
  # sits at 23, i.e. one character of headroom. Without this check, overrunning
  # it surfaces as an opaque API error partway through an apply, after the VPC
  # and cluster already exist.
  validation {
    condition     = length(var.cluster_name) <= 24
    error_message = "cluster_name must be <= 24 chars: it prefixes service account IDs, which GCP caps at 30, and the longest suffix added is \"-nodes\"."
  }

  # Cluster names, and the network/SA names derived from them, must be RFC-1035:
  # lowercase alphanumeric or hyphen, starting with a letter, not ending in one.
  validation {
    condition     = can(regex("^[a-z][-a-z0-9]*[a-z0-9]$", var.cluster_name))
    error_message = "cluster_name must be lowercase RFC-1035: start with a letter, contain only letters/digits/hyphens, and not end with a hyphen."
  }
}

variable "artifact_repo_name" {
  description = "Artifact Registry Docker repository ID for the app image."
  type        = string
  default     = "model-llmsecops"
}

variable "model_bucket_name" {
  description = "Globally-unique GCS bucket for model weights. Leave empty to default to <project_id>-model-llmsecops-models."
  type        = string
  default     = ""
}

variable "app_machine_type" {
  description = "Machine type for the app node pool (Streamlit + pipeline). e2-standard-2 gives ~1930m allocatable CPU (vs ~940m on shared-core e2-medium), enough for the app plus light monitoring."
  type        = string
  default     = "e2-standard-2"
}

variable "serve_machine_type" {
  description = "Machine type for the vLLM CPU serving pool. e2-highmem-4 (4 vCPU / 32GB) gives ~28GB allocatable — comfortable for a 3B model on CPU (needs ~13-15GB) with no OOM risk — while using only 4 vCPU of the free-tier quota."
  type        = string
  default     = "e2-highmem-4"
}

variable "master_authorized_cidrs" {
  description = "CIDRs allowed to reach the GKE control-plane endpoint. Empty = allow all (needed for GitHub-hosted runners). Set to your office/VPN CIDRs to lock it down."
  type        = list(string)
  default     = []
}

variable "k8s_namespace" {
  description = "Kubernetes namespace the vLLM/app workloads run in (for Workload Identity binding)."
  type        = string
  default     = "default"
}

variable "k8s_service_account" {
  description = "Kubernetes ServiceAccount name the vLLM/app pods use (for Workload Identity binding)."
  type        = string
  default     = "model-llmsecops-sa"
}

# ---------------------------------------------------------------------------
# Backend (read during early evaluation — see backend.tf)
# ---------------------------------------------------------------------------

variable "state_bucket" {
  description = "GCS bucket holding OpenTofu state. Created once during bootstrap, NOT by this config. Read before the backend initialises, so it must come from a CLI flag, TF_VAR_ env var, or a .tfvars file."
  type        = string
}

# ---------------------------------------------------------------------------
# Load balancer / ingress
# ---------------------------------------------------------------------------

variable "enable_load_balancer" {
  description = "Create the LB support resources (static IP, Cloud Armor, optional cert/DNS). Off by default: the managed certificate needs a real domain, and the ~$30/mo cost is only worth paying once someone outside the cluster needs to reach the app. `kubectl port-forward` is free."
  type        = bool
  default     = false
}

variable "app_domain" {
  description = "Fully-qualified domain for the app, e.g. model.example.com. Required only when enable_load_balancer is true AND you want HTTPS; leave empty to get the IP and Cloud Armor policy without a managed certificate."
  type        = string
  default     = ""
}

variable "dns_zone_name" {
  description = "Cloud DNS managed zone name to create the A record in. Empty = manage DNS externally (registrar, Cloudflare, etc.)."
  type        = string
  default     = ""
}

variable "app_allowed_cidrs" {
  description = "If non-empty, Cloud Armor denies every source outside these CIDRs. The intended pre-launch posture: reachable by you, nobody else."
  type        = list(string)
  default     = []
}

variable "app_rate_limit_per_minute" {
  description = "Per-IP requests per minute before Cloud Armor returns 429. Matters more than usual here: every request that reaches the app can trigger an LLM call."
  type        = number
  default     = 300
}
