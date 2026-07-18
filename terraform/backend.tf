# Remote state in GCS so both the apply and destroy workflows share the same state.
#
# The bucket is NOT created by this configuration (chicken-and-egg) — create it
# once during bootstrap (see terraform/README.md).
#
# Unlike Terraform, OpenTofu (1.8+) evaluates variables *before* the backend is
# initialised, so the bucket name is a plain variable instead of a
# `-backend-config` incantation on every init. Supply it however you like:
#
#   tofu init -var="state_bucket=my-state-bucket"
#   TF_VAR_state_bucket=my-state-bucket tofu init
#   echo 'state_bucket = "my-state-bucket"' >> terraform.tfvars && tofu init
#
# The value must come from a source available before evaluation (CLI flag,
# TF_VAR_ env var, or a .tfvars file) — it cannot depend on a resource, a data
# source, or a module output.
terraform {
  backend "gcs" {
    bucket = var.state_bucket

    # Distinct prefix from the anime-recommender stack. Both stacks can share
    # one bucket safely; they must never share a prefix.
    prefix = "model-llmsecops/state"
  }
}
