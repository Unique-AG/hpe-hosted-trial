provider "zitadel" {
  domain                   = var.zitadel_domain
  port                     = var.zitadel_port
  insecure                 = var.zitadel_insecure
  insecure_skip_verify_tls = var.insecure_skip_verify_tls
  access_token             = var.zitadel_access_token
}
