variable "zitadel_domain" {
  description = "ZITADEL host name without a scheme, for example id.example.com."
  type        = string
  default     = "id.example.invalid"
}

variable "zitadel_port" {
  description = "Optional ZITADEL API port. Leave null for the provider default."
  type        = string
  default     = null
  nullable    = true
}

variable "zitadel_insecure" {
  description = "Use an HTTP connection to ZITADEL."
  type        = bool
  default     = false
}

variable "insecure_skip_verify_tls" {
  description = "Disable TLS certificate verification only when explicitly required by the operator."
  type        = bool
  default     = false
}

variable "oidc_dev_mode" {
  description = "Enable OIDC development mode. The secure module default is false; setup-zitadel.sh derives true only for HTTP/local deployments unless explicitly overridden."
  type        = bool
  default     = false
}

variable "transport_headers" {
  description = "Headers sent to ZITADEL. The bootstrap uses Host while connecting through a local Kubernetes port-forward."
  type        = map(string)
  default     = {}
}

variable "zitadel_access_token" {
  description = "Personal access token used by the provider; supplied by setup-zitadel.sh through TF_VAR."
  type        = string
  sensitive   = true
  default     = ""
}

variable "target_org_name" {
  description = "Exact name of the tenant organization that receives the Unique Apps project grant."
  type        = string
  default     = "HPE Hosted Trial"

  validation {
    condition     = length(trimspace(var.target_org_name)) > 0
    error_message = "target_org_name must not be empty."
  }
}

variable "scope_management_user_name" {
  description = "Username of the JWT machine user used by node-scope-management."
  type        = string
  default     = "scope-management"

  validation {
    condition     = length(trimspace(var.scope_management_user_name)) > 0
    error_message = "scope_management_user_name must not be empty."
  }
}

variable "scope_management_pat_expiration_date" {
  description = "RFC3339 expiration for the node-scope-management PAT. The explicit provider maximum avoids perpetual replacement after ZITADEL normalizes an omitted value."
  type        = string
  default     = "9999-12-31T23:59:59Z"
}

variable "frontend_base_url" {
  description = "Unique frontend origin; the default redirect URI set appends the four deployed frontend paths."
  type        = string
  default     = "https://unique.example.invalid"

  validation {
    condition     = can(regex("^https?://[^/]+/?$", var.frontend_base_url))
    error_message = "frontend_base_url must be an http(s) origin without a path."
  }
}

variable "redirect_uris" {
  description = "Optional exact redirect URI override list. An empty list derives the four deployed paths from frontend_base_url."
  type        = list(string)
  default     = []
}

variable "post_logout_redirect_uris" {
  description = "Optional exact post-logout URI override list. An empty list derives the four deployed paths from frontend_base_url."
  type        = list(string)
  default     = []
}
