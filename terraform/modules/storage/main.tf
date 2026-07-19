# ---------------------------------------------------------------------------
# GCS bucket for model weights (vLLM pulls / mounts the model from here)
# ---------------------------------------------------------------------------
#tfsec:ignore:google-storage-bucket-encryption-customer-key Google-managed encryption at rest is acceptable for this project (no CMEK/KMS to keep free-tier cost/complexity down).
resource "google_storage_bucket" "models" {
  #checkov:skip=CKV_GCP_62:Access logging omitted (would require a second log bucket); not needed for this project.
  name     = var.bucket_name
  location = var.region

  uniform_bucket_level_access = true
  public_access_prevention    = "enforced"
  force_destroy               = true # wipe objects on `terraform destroy`

  versioning {
    enabled = true
  }
}

# ---------------------------------------------------------------------------
# Workload-identity SA the vLLM/app pods use to read the model bucket
# ---------------------------------------------------------------------------
resource "google_service_account" "app" {
  account_id   = "${var.name_prefix}-app"
  display_name = "vLLM / app workload identity SA"
}

# WRITE, not read-only. vLLM downloads the model from HF Hub into this bucket
# through the gcsfuse mount on first start, so the workload has to be able to
# create objects — objectViewer would fail the download with a 403.
#
# objectUser (not objectAdmin) is the narrower of the two write roles: it grants
# object create/read/update/delete but no control over bucket-level IAM.
#
# Trade-off worth being aware of: the serving pod can now overwrite or delete
# the weights it loads. If you later pre-populate the bucket instead of
# downloading at runtime, drop this back to roles/storage.objectViewer and
# make the volume mount readOnly again.
resource "google_storage_bucket_iam_member" "app_model_writer" {
  bucket = google_storage_bucket.models.name
  role   = "roles/storage.objectUser"
  member = "serviceAccount:${google_service_account.app.email}"
}

# Bind the Google SA to the Kubernetes SA (<namespace>/<ksa>) via Workload Identity.
resource "google_service_account_iam_member" "app_wi" {
  service_account_id = google_service_account.app.name
  role               = "roles/iam.workloadIdentityUser"
  member             = "serviceAccount:${var.project_id}.svc.id.goog[${var.k8s_namespace}/${var.k8s_service_account}]"
}
