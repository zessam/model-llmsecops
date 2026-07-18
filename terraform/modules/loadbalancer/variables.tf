variable "name_prefix" {
  description = "Prefix for LB resource names (usually the cluster name)."
  type        = string
}

variable "domain" {
  description = "Fully-qualified domain for the app, e.g. model.example.com. Empty = no managed certificate (HTTP only)."
  type        = string
  default     = ""

  validation {
    condition     = var.domain == "" || can(regex("^[a-z0-9]([-a-z0-9.]*[a-z0-9])?$", var.domain))
    error_message = "domain must be a bare lowercase FQDN with no scheme, port, path, or trailing dot (e.g. model.example.com)."
  }
}

variable "dns_zone_name" {
  description = "Cloud DNS managed zone name. Empty = manage DNS externally; point an A record at the lb_ip output yourself."
  type        = string
  default     = ""
}

variable "allowed_source_cidrs" {
  description = "If non-empty, Cloud Armor denies every source outside these CIDRs before WAF evaluation."
  type        = list(string)
  default     = []

  # Each CIDR becomes one inIpRange() call in a single CEL expression, and
  # Cloud Armor caps expression complexity. Five is a conservative ceiling that
  # stays well inside the limit; past that, use a Cloud Armor address group and
  # reference it with evaluateAddressGroup() instead of expanding this list.
  validation {
    condition     = length(var.allowed_source_cidrs) <= 5
    error_message = "allowed_source_cidrs supports at most 5 entries (Cloud Armor expression complexity). Use an address group for larger allowlists."
  }

  validation {
    condition     = alltrue([for c in var.allowed_source_cidrs : can(cidrhost(c, 0))])
    error_message = "every entry in allowed_source_cidrs must be valid CIDR notation, e.g. 203.0.113.4/32."
  }
}

variable "rate_limit_per_minute" {
  description = "Per-IP request budget per minute before Cloud Armor returns 429."
  type        = number
  default     = 300

  validation {
    condition     = var.rate_limit_per_minute > 0
    error_message = "rate_limit_per_minute must be greater than 0."
  }
}

variable "waf_rules" {
  description = "OWASP preconfigured WAF expressions and their rule priorities. Priorities must stay between the allowlist rule (500) and the rate limit (2000)."
  type = list(object({
    priority = number
    expr     = string
  }))
  default = [
    { priority = 1000, expr = "sqli-v33-stable" },
    { priority = 1001, expr = "xss-v33-stable" },
    { priority = 1002, expr = "lfi-v33-stable" },
    { priority = 1003, expr = "rce-v33-stable" },
    { priority = 1004, expr = "scannerdetection-v33-stable" },
  ]

  validation {
    condition     = alltrue([for r in var.waf_rules : r.priority > 500 && r.priority < 2000])
    error_message = "waf_rules priorities must be between 501 and 1999: above the allowlist deny at 500, below the rate limit at 2000. Outside that range the rule is either bypassed or unreachable."
  }
}
