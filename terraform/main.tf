locals {
  model_bucket_name = var.model_bucket_name != "" ? var.model_bucket_name : "${var.project_id}-model-llmsecops-models"

  labels = {
    app        = "model-llmsecops"
    managed-by = "opentofu"
  }

  # APIs required for the whole stack.
  services = concat([
    "compute.googleapis.com",
    "container.googleapis.com",
    "artifactregistry.googleapis.com",
    "storage.googleapis.com",
    "iam.googleapis.com",
    "serviceusage.googleapis.com",
    ],
    # Only needed when the LB manages a Cloud DNS record set.
    var.enable_load_balancer && var.dns_zone_name != "" ? ["dns.googleapis.com"] : []
  )
}

# ---------------------------------------------------------------------------
# Enable required APIs (project-level, stays in the root module)
# ---------------------------------------------------------------------------
resource "google_project_service" "services" {
  for_each = toset(local.services)

  project = var.project_id
  service = each.value

  # Keep APIs enabled on `terraform destroy` — disabling them is slow and can
  # break other resources during teardown.
  disable_on_destroy = false
}

# ---------------------------------------------------------------------------
# Network — dedicated VPC, subnet, Cloud NAT
# ---------------------------------------------------------------------------
module "network" {
  source = "./modules/network"

  name_prefix = var.cluster_name
  region      = var.region

  depends_on = [google_project_service.services]
}

# ---------------------------------------------------------------------------
# GKE — cluster + node pools + node SA
# ---------------------------------------------------------------------------
module "gke" {
  source = "./modules/gke"

  project_id              = var.project_id
  name                    = var.cluster_name
  zone                    = var.zone
  network_id              = module.network.network_id
  subnet_id               = module.network.subnet_id
  pods_range_name         = module.network.pods_range_name
  services_range_name     = module.network.services_range_name
  app_machine_type        = var.app_machine_type
  serve_machine_type      = var.serve_machine_type
  master_authorized_cidrs = var.master_authorized_cidrs
  labels                  = local.labels

  # Wait for the ENTIRE network module (VPC, subnet, router AND Cloud NAT)
  # before creating the cluster/node pools. Private nodes have no public IP and
  # need NAT egress to pull system pods and become Ready — without this ordering
  # nodes can boot before NAT exists and fail to register.
  depends_on = [google_project_service.services, module.network]
}

# ---------------------------------------------------------------------------
# Artifact Registry — Docker repo for the app image
# ---------------------------------------------------------------------------
module "artifact_registry" {
  source = "./modules/artifact_registry"

  region        = var.region
  repository_id = var.artifact_repo_name

  depends_on = [google_project_service.services]
}

# ---------------------------------------------------------------------------
# Storage — model bucket + workload-identity SA
# ---------------------------------------------------------------------------
module "storage" {
  source = "./modules/storage"

  project_id          = var.project_id
  region              = var.region
  bucket_name         = local.model_bucket_name
  name_prefix         = var.cluster_name
  k8s_namespace       = var.k8s_namespace
  k8s_service_account = var.k8s_service_account

  depends_on = [google_project_service.services]
}

# ---------------------------------------------------------------------------
# Load balancer support — static IP, Cloud Armor, optional cert + DNS
#
# Off by default (see var.enable_load_balancer). The ALB itself is created by
# the in-cluster ingress controller, not here; this module only owns the GCP
# resources the Ingress references by name. See modules/loadbalancer/main.tf.
# ---------------------------------------------------------------------------
module "loadbalancer" {
  source = "./modules/loadbalancer"

  count = var.enable_load_balancer ? 1 : 0

  name_prefix           = var.cluster_name
  domain                = var.app_domain
  dns_zone_name         = var.dns_zone_name
  allowed_source_cidrs  = var.app_allowed_cidrs
  rate_limit_per_minute = var.app_rate_limit_per_minute

  depends_on = [google_project_service.services]
}
