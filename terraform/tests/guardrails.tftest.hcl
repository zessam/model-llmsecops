# Guardrail tests. Run with `tofu test`.
#
# mock_provider means these assert on the PLAN with no GCP calls: no cluster,
# no cost, no credentials, runs in seconds. That is the capability Terraform
# lacks — `terraform test` would have to actually provision a GKE cluster to
# check any of this.
#
# NOTE ON ADDRESSING: a test file cannot reach into a child module's resources.
# `module.gke` resolves to that module's OUTPUTS only, so
# `module.gke.google_container_node_pool.serve` is a hard error. To assert on
# resources, a `run` block sets `module { source = ... }`, which makes that
# module the root for that run and puts its resources at the top level.
#
# These cover the properties whose regression costs money or leaks data, which
# is the bar for putting a guardrail here at all.

mock_provider "google" {
  # By default the mock invents a random string for every computed attribute.
  # google_service_account.name feeds service_account_id on the Workload
  # Identity binding, which the provider validates against a strict
  # resource-name regex, so a random value fails the plan before any assertion
  # runs. Pin both attributes to realistically-shaped values.
  mock_resource "google_service_account" {
    defaults = {
      name  = "projects/test-project/serviceAccounts/mock-sa@test-project.iam.gserviceaccount.com"
      email = "mock-sa@test-project.iam.gserviceaccount.com"
    }
  }
}

variables {
  project_id   = "test-project"
  state_bucket = "test-state-bucket"
}

# --- GKE ---------------------------------------------------------------------

run "gke_guardrails" {
  command = plan

  module {
    source = "./modules/gke"
  }

  variables {
    project_id          = "test-project"
    name                = "test-cluster"
    zone                = "us-central1-c"
    network_id          = "projects/test-project/global/networks/test-vpc"
    subnet_id           = "projects/test-project/regions/us-central1/subnetworks/test-subnet"
    pods_range_name     = "pods"
    services_range_name = "services"
    app_machine_type    = "e2-standard-2"
    serve_machine_type  = "e2-highmem-4"
  }

  assert {
    condition     = google_container_node_pool.serve.autoscaling[0].min_node_count == 0
    error_message = "Serve pool must scale to zero when idle — it is the expensive node."
  }

  assert {
    condition     = google_container_cluster.primary.private_cluster_config[0].enable_private_nodes == true
    error_message = "Nodes must have no public IPs."
  }

  assert {
    condition     = google_container_cluster.primary.workload_identity_config[0].workload_pool == "test-project.svc.id.goog"
    error_message = "Workload Identity pool must match the project."
  }

  assert {
    condition     = google_container_cluster.primary.enable_shielded_nodes == true
    error_message = "Cluster must enable Shielded Nodes."
  }

  # The default compute SA is project-editor by default. Both pools must use
  # the least-privilege SA this module creates.
  assert {
    condition = alltrue([
      google_container_node_pool.app.node_config[0].service_account == google_service_account.nodes.email,
      google_container_node_pool.serve.node_config[0].service_account == google_service_account.nodes.email,
    ])
    error_message = "Both node pools must use the dedicated node service account, not the default compute SA."
  }

  assert {
    condition = alltrue([
      google_container_node_pool.app.node_config[0].workload_metadata_config[0].mode == "GKE_METADATA",
      google_container_node_pool.serve.node_config[0].workload_metadata_config[0].mode == "GKE_METADATA",
    ])
    error_message = "Both node pools must run the GKE metadata server, or Workload Identity is not actually enforced on the node."
  }
}

# --- Storage -----------------------------------------------------------------

run "bucket_is_private" {
  command = plan

  module {
    source = "./modules/storage"
  }

  variables {
    project_id          = "test-project"
    region              = "us-central1"
    bucket_name         = "test-model-bucket"
    name_prefix         = "test-cluster"
    k8s_namespace       = "default"
    k8s_service_account = "test-sa"
  }

  assert {
    condition     = google_storage_bucket.models.public_access_prevention == "enforced"
    error_message = "Model bucket must enforce public access prevention."
  }

  assert {
    condition     = google_storage_bucket.models.uniform_bucket_level_access == true
    error_message = "Model bucket must use uniform bucket-level access (no legacy ACLs)."
  }

  # Read-only. The pods pull model weights; nothing in the app should be able
  # to overwrite them, which is what makes objectViewer rather than objectAdmin
  # the load-bearing choice here.
  assert {
    condition     = google_storage_bucket_iam_member.app_model_reader.role == "roles/storage.objectViewer"
    error_message = "App SA must have read-only access to the model bucket."
  }
}

# --- Load balancer -----------------------------------------------------------

run "lb_is_off_by_default" {
  command = plan

  assert {
    condition     = length(module.loadbalancer) == 0
    error_message = "Load balancer must stay off unless explicitly enabled — it costs ~$30/mo."
  }
}

run "allowlist_denies_before_waf_evaluates" {
  command = plan

  module {
    source = "./modules/loadbalancer"
  }

  variables {
    name_prefix          = "test-cluster"
    domain               = "model.example.com"
    allowed_source_cidrs = ["203.0.113.4/32"]
  }

  # Guards the ordering bug this module exists to avoid: expressing the
  # allowlist as an `allow` rule ahead of the WAF would exempt those IPs from
  # WAF inspection entirely. It must be a deny-everyone-else rule instead.
  assert {
    condition = anytrue([
      for r in google_compute_security_policy.armor.rule :
      r.priority == 500 && startswith(r.action, "deny")
    ])
    error_message = "With an allowlist set, priority 500 must be a DENY of non-allowlisted sources, so permitted traffic still falls through to WAF and rate limiting."
  }

  # The throttle rule allows on conform and terminates evaluation, so anything
  # after it is unreachable. WAF rules must therefore sit below priority 2000.
  assert {
    condition = alltrue([
      for r in google_compute_security_policy.armor.rule :
      r.priority < 2000 if startswith(r.description, "OWASP")
    ])
    error_message = "WAF rules must evaluate before the rate-limit rule at priority 2000, which terminates evaluation on conform."
  }

  assert {
    condition     = length(google_compute_managed_ssl_certificate.app) == 1
    error_message = "A managed certificate must be planned when a domain is set."
  }
}

run "no_certificate_without_a_domain" {
  command = plan

  module {
    source = "./modules/loadbalancer"
  }

  variables {
    name_prefix = "test-cluster"
    domain      = ""
  }

  # A managed cert with no domain is not creatable; the module must degrade to
  # IP + Cloud Armor rather than fail the apply.
  assert {
    condition     = length(google_compute_managed_ssl_certificate.app) == 0
    error_message = "No managed certificate should be planned when domain is empty."
  }

  assert {
    condition     = length(google_dns_record_set.app) == 0
    error_message = "No DNS record should be planned without a domain."
  }
}
