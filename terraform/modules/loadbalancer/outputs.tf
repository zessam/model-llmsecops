output "lb_ip" {
  description = "Static IP for the ALB. Point your DNS A record here if dns_zone_name is unset."
  value       = google_compute_global_address.lb.address
}

output "static_ip_name" {
  description = "Value for the Ingress kubernetes.io/ingress.global-static-ip-name annotation."
  value       = google_compute_global_address.lb.name
}

output "certificate_name" {
  description = "Value for the Ingress ingress.gcp.kubernetes.io/pre-shared-cert annotation. Empty when no domain is configured (HTTP only)."
  # Return "" rather than null when the cert is absent, so consumers get a
  # consistent string type and don't have to null-check.
  value = length(google_compute_managed_ssl_certificate.app) > 0 ? google_compute_managed_ssl_certificate.app[0].name : ""
}

output "security_policy_name" {
  description = "Value for the BackendConfig spec.securityPolicy.name reference."
  value       = google_compute_security_policy.armor.name
}
