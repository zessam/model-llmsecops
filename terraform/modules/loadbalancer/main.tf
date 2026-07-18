# ---------------------------------------------------------------------------
# LOAD BALANCER SUPPORT RESOURCES
#
# Deliberately NOT here: google_compute_forwarding_rule, _target_https_proxy,
# _url_map, _backend_service, _health_check.
#
# On GKE the ALB is created and *continuously reconciled* by the in-cluster
# ingress controller from the Ingress object. Declaring those resources here
# would put OpenTofu and the controller in a fight over the same objects: the
# controller rewrites them, the next plan shows a diff, forever. This module
# owns only the resources the controller references *by name* and never mutates.
#
#   OpenTofu owns (here)           Kubernetes owns (k8s/ manifests)
#   ----------------------------   -------------------------------
#   global address                 Ingress
#   managed SSL certificate        BackendConfig / FrontendConfig
#   Cloud Armor security policy    Service annotations
#   DNS A record                   the ALB itself + health checks
# ---------------------------------------------------------------------------

locals {
  # A managed certificate is only possible with a real domain. Without one this
  # module still yields a usable IP + Cloud Armor policy (HTTP only).
  enable_cert = var.domain != ""

  # The A record additionally needs a Cloud DNS zone to write into. With a
  # domain but no zone, DNS is managed externally and you point the record at
  # the `lb_ip` output by hand.
  enable_dns = var.domain != "" && var.dns_zone_name != ""
}

# ---------------------------------------------------------------------------
# Static anycast IP for the global external ALB.
# GLOBAL, not regional — required by the global external Application LB, and
# the reason this is `google_compute_global_address` rather than `_address`.
# ---------------------------------------------------------------------------
resource "google_compute_global_address" "lb" {
  name         = "${var.name_prefix}-lb-ip"
  address_type = "EXTERNAL"
  ip_version   = "IPV4"
}

# ---------------------------------------------------------------------------
# DNS A record.
#
# Ordering matters: the domain must already resolve to this IP BEFORE the
# managed certificate can finish provisioning, because Google validates domain
# ownership over HTTP. Creating both in one apply is fine — the cert simply
# sits in PROVISIONING (typically 15-60 min) until DNS propagates.
# ---------------------------------------------------------------------------
resource "google_dns_record_set" "app" {
  count = local.enable_dns ? 1 : 0

  name         = "${var.domain}." # trailing dot is required by the API
  managed_zone = var.dns_zone_name
  type         = "A"
  ttl          = 300
  rrdatas      = [google_compute_global_address.lb.address]
}

# ---------------------------------------------------------------------------
# Google-managed TLS certificate. Free, auto-renewing, no private key to hold.
#
# `managed.domains` is IMMUTABLE — changing the domain forces replacement.
# create_before_destroy avoids a window where the ALB references a certificate
# that no longer exists, but it requires the replacement to have a different
# name, hence the domain hash suffix.
# ---------------------------------------------------------------------------
resource "google_compute_managed_ssl_certificate" "app" {
  count = local.enable_cert ? 1 : 0

  name = "${var.name_prefix}-cert-${substr(sha256(var.domain), 0, 8)}"

  managed {
    domains = [var.domain]
  }

  lifecycle {
    create_before_destroy = true
  }
}

# ---------------------------------------------------------------------------
# Cloud Armor — WAF + rate limiting. Attached to the backend on the Kubernetes
# side via BackendConfig.spec.securityPolicy.name.
#
# RULE ORDER IS THE SECURITY MODEL. Cloud Armor evaluates rules in ascending
# priority and STOPS AT THE FIRST MATCH, applying that rule's action. Two
# consequences drive the layout below, and both are easy to get wrong:
#
#   1. An `allow` rule for an IP allowlist placed BEFORE the WAF rules exempts
#      those IPs from WAF inspection entirely. So the allowlist is expressed as
#      a *deny everyone else* rule instead — outsiders are dropped at priority
#      500, while allowlisted traffic continues on to be WAF-inspected and
#      rate-limited like any other request.
#
#   2. The throttle rule matches "*" with conform_action = allow, so under the
#      threshold it ALLOWS and evaluation stops. Every rule after it is
#      therefore unreachable, which means a "default deny" at the bottom would
#      be dead config. Default-deny has to happen at priority 500 or not at all.
#
# Evaluation order:
#   500          deny non-allowlisted sources        (only if allowlist set)
#   1000-1004    deny OWASP WAF matches
#   2000         throttle per IP -> 429 over budget
#   2147483647   default: allow
# ---------------------------------------------------------------------------
resource "google_compute_security_policy" "armor" {
  name        = "${var.name_prefix}-armor"
  description = "WAF + rate limiting for the model-llmsecops app"
  type        = "CLOUD_ARMOR"

  # --- Optional pre-launch lockdown ---------------------------------------
  # Inverted allowlist: deny anything NOT in allowed_source_cidrs. Placed first
  # so outsiders never reach the LLM at all, but expressed as a deny so that
  # permitted traffic still falls through to the WAF and rate-limit rules.
  dynamic "rule" {
    for_each = length(var.allowed_source_cidrs) > 0 ? [1] : []
    content {
      action      = "deny(403)"
      priority    = 500
      description = "Deny all sources outside the operator allowlist"
      match {
        expr {
          expression = format(
            "!(%s)",
            join(" || ", [
              for cidr in var.allowed_source_cidrs :
              format("inIpRange(origin.ip, '%s')", cidr)
            ])
          )
        }
      }
    }
  }

  # --- OWASP preconfigured rule sets --------------------------------------
  # sensitivity 1 = fewest false positives. Raise only after reviewing logs;
  # higher sensitivities block legitimate Streamlit payloads readily.
  dynamic "rule" {
    for_each = var.waf_rules
    content {
      action      = "deny(403)"
      priority    = rule.value.priority
      description = "OWASP ${rule.value.expr}"
      match {
        expr {
          expression = "evaluatePreconfiguredWaf('${rule.value.expr}', {'sensitivity': 1})"
        }
      }
    }
  }

  # --- Per-IP rate limit ---------------------------------------------------
  # Streamlit is chatty (WebSocket + polling), so the budget is deliberately
  # generous. Tune from real traffic. This rule carries more weight than a
  # typical rate limit: every request reaching the app can trigger an LLM call,
  # so this is the cost ceiling as much as an abuse control.
  rule {
    action      = "throttle"
    priority    = 2000
    description = "Per-IP rate limit"
    match {
      versioned_expr = "SRC_IPS_V1"
      config {
        src_ip_ranges = ["*"]
      }
    }
    rate_limit_options {
      conform_action = "allow"
      exceed_action  = "deny(429)"
      enforce_on_key = "IP"
      rate_limit_threshold {
        count        = var.rate_limit_per_minute
        interval_sec = 60
      }
    }
  }

  # --- Default rule --------------------------------------------------------
  # Mandatory on every policy; the priority is fixed at int32 max and cannot be
  # changed. Allow — see note (2) above on why default-deny cannot live here.
  rule {
    action      = "allow"
    priority    = 2147483647
    description = "default"
    match {
      versioned_expr = "SRC_IPS_V1"
      config {
        src_ip_ranges = ["*"]
      }
    }
  }

  # VERBOSE logging records which rule matched and why. Worth the log volume
  # while tuning WAF sensitivity; drop to NORMAL once the false positives are
  # settled.
  advanced_options_config {
    log_level = "VERBOSE"
  }
}
