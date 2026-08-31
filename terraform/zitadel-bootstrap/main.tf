locals {
  # These names and roles intentionally mirror cli/src/commands/local/init-zitadel.ts.
  root_org_name    = "Cluster IAM"
  project_name     = "Unique Apps"
  application_name = "Standalone Apps"

  project_roles = toset([
    "chat.chat.basic",
    "chat.chat.unlimited",
    "chat.knowledge.read",
    "chat.knowledge.write",
    "chat.feedback.read",
    "chat.admin.all",
    "chat.data.admin",
    "chat.debug.read",
    "admin.user-management.write",
    "admin.space.write",
    "admin.app-repository.write",
    "connector.admin.read",
    "connector.admin.write",
  ])

  frontend_paths = [
    "/chat",
    "/admin",
    "/knowledge-upload",
    "/theme",
  ]

  derived_frontend_uris = [
    for path in local.frontend_paths : "${trimsuffix(var.frontend_base_url, "/")}${path}"
  ]
  effective_redirect_uris             = length(var.redirect_uris) > 0 ? var.redirect_uris : local.derived_frontend_uris
  effective_post_logout_redirect_uris = length(var.post_logout_redirect_uris) > 0 ? var.post_logout_redirect_uris : local.derived_frontend_uris
  effective_oidc_dev_mode             = var.oidc_dev_mode

  root_org_ids = data.zitadel_organizations.root.ids
  root_org_id  = try(local.root_org_ids[0], "")

  target_org_ids = data.zitadel_organizations.target.ids
  target_org_id  = try(local.target_org_ids[0], "")

  existing_project_ids = length(local.root_org_ids) == 1 ? data.zitadel_projects.managed_candidates["root"].project_ids : []
  existing_application_ids = flatten([
    for candidate in values(data.zitadel_application_oidcs.managed_candidates) : candidate.app_ids
  ])
  existing_machine_user_ids = length(local.root_org_ids) == 1 ? data.zitadel_machine_users.managed_candidates["root"].user_ids : []
}

data "zitadel_organizations" "root" {
  name        = local.root_org_name
  name_method = "TEXT_QUERY_METHOD_EQUALS_IGNORE_CASE"
}

data "zitadel_organizations" "target" {
  name        = var.target_org_name
  name_method = "TEXT_QUERY_METHOD_EQUALS_IGNORE_CASE"
}

# These read-only lookups are consumed by setup-zitadel.sh before apply. They let
# the entrypoint identify a remote object when its local state has disappeared,
# and refuse to create a duplicate instead of guessing an import. The provider's
# case-insensitive equals method matches ZITADEL's name uniqueness semantics.
data "zitadel_projects" "managed_candidates" {
  for_each    = length(local.root_org_ids) == 1 ? { root = local.root_org_id } : {}
  org_id      = each.value
  name        = local.project_name
  name_method = "TEXT_QUERY_METHOD_EQUALS_IGNORE_CASE"
}

data "zitadel_application_oidcs" "managed_candidates" {
  for_each    = toset(local.existing_project_ids)
  org_id      = local.root_org_id
  project_id  = each.value
  name        = local.application_name
  name_method = "TEXT_QUERY_METHOD_EQUALS_IGNORE_CASE"
}

data "zitadel_machine_users" "managed_candidates" {
  for_each         = length(local.root_org_ids) == 1 ? { root = local.root_org_id } : {}
  org_id           = each.value
  user_name        = var.scope_management_user_name
  user_name_method = "TEXT_QUERY_METHOD_EQUALS_IGNORE_CASE"
}

resource "terraform_data" "bootstrap_guard" {
  input = {
    root_org_id   = local.root_org_id
    target_org_id = local.target_org_id
  }

  lifecycle {
    precondition {
      condition     = length(local.root_org_ids) == 1
      error_message = "Exactly one active or existing organization named 'Cluster IAM' is required; inspect duplicate exact root organization names before continuing."
    }
    precondition {
      condition     = length(local.target_org_ids) <= 1
      error_message = "At most one exact target organization named '${var.target_org_name}' may exist."
    }
  }
}

resource "zitadel_project" "unique_apps" {
  name                   = local.project_name
  org_id                 = local.root_org_id
  project_role_assertion = true
  project_role_check     = true
  has_project_check      = true

  depends_on = [terraform_data.bootstrap_guard]
}

resource "zitadel_project_role" "unique_apps" {
  for_each = local.project_roles

  org_id       = local.root_org_id
  project_id   = zitadel_project.unique_apps.id
  role_key     = each.value
  display_name = each.value
  group        = "default"

  depends_on = [terraform_data.bootstrap_guard]
}

resource "zitadel_application_oidc" "standalone_apps" {
  org_id                    = local.root_org_id
  project_id                = zitadel_project.unique_apps.id
  name                      = local.application_name
  redirect_uris             = local.effective_redirect_uris
  post_logout_redirect_uris = local.effective_post_logout_redirect_uris

  app_type                    = "OIDC_APP_TYPE_WEB"
  auth_method_type            = "OIDC_AUTH_METHOD_TYPE_NONE"
  version                     = "OIDC_VERSION_1_0"
  response_types              = ["OIDC_RESPONSE_TYPE_CODE"]
  grant_types                 = ["OIDC_GRANT_TYPE_AUTHORIZATION_CODE", "OIDC_GRANT_TYPE_REFRESH_TOKEN"]
  clock_skew                  = "0s"
  dev_mode                    = local.effective_oidc_dev_mode
  access_token_type           = "OIDC_TOKEN_TYPE_JWT"
  access_token_role_assertion = true
  id_token_role_assertion     = true
  id_token_userinfo_assertion = true

  depends_on = [terraform_data.bootstrap_guard]
}

resource "zitadel_org" "target_tenant" {
  name = var.target_org_name

  depends_on = [terraform_data.bootstrap_guard]
}

resource "zitadel_project_grant" "target_tenant" {
  org_id         = local.root_org_id
  project_id     = zitadel_project.unique_apps.id
  granted_org_id = zitadel_org.target_tenant.id
  role_keys      = local.project_roles

  depends_on = [
    terraform_data.bootstrap_guard,
    zitadel_project_role.unique_apps,
  ]
}

# Do not set user_id here: the provider's ZITADEL 3.x legacy fallback rejects
# custom IDs. setup-zitadel.sh uses this exact username as the state-loss guard.
resource "zitadel_machine_user" "scope_management" {
  org_id            = local.root_org_id
  user_name         = var.scope_management_user_name
  name              = "Scope Management Service"
  description       = "JWT service account for node-scope-management."
  access_token_type = "ACCESS_TOKEN_TYPE_JWT"
  with_secret       = false

  depends_on = [terraform_data.bootstrap_guard]
}

resource "zitadel_instance_member" "scope_management" {
  user_id = zitadel_machine_user.scope_management.id
  roles   = ["IAM_OWNER"]

  depends_on = [terraform_data.bootstrap_guard]
}

resource "zitadel_personal_access_token" "scope_management" {
  org_id          = local.root_org_id
  user_id         = zitadel_machine_user.scope_management.id
  expiration_date = var.scope_management_pat_expiration_date

  depends_on = [zitadel_instance_member.scope_management]
}
