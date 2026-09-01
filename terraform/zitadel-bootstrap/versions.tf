terraform {
  required_version = ">= 1.5.0"

  # The entrypoint also supplies TF_DATA_DIR under this ignored directory. A
  # local backend keeps direct Terraform invocations from creating state beside
  # this tracked module.
  backend "local" {
    path = "../../.local/zitadel-bootstrap/terraform.tfstate"
  }

  required_providers {
    zitadel = {
      source = "zitadel/zitadel"
      # v3.4.0 supports the legacy APIs used by ZITADEL 3.x (including v3.4.11).
      version = "= 3.4.0"
    }
  }
}
