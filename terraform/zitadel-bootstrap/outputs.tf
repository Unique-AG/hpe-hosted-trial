output "root_org_id" {
  description = "ID of the Helm-created Cluster IAM organization."
  value       = local.root_org_id
}

output "project_id" {
  description = "ID of the Unique Apps project."
  value       = zitadel_project.unique_apps.id
}

output "client_id" {
  description = "Client ID of the Standalone Apps WEB PKCE application."
  value       = zitadel_application_oidc.standalone_apps.client_id
}

output "target_org_id" {
  description = "ID of the configured tenant organization."
  value       = zitadel_org.target_tenant.id
}

output "scope_management_user_id" {
  description = "ID of the node-scope-management JWT machine user."
  value       = zitadel_machine_user.scope_management.id
}

output "pat" {
  description = "PAT for the node-scope-management machine user."
  value       = zitadel_personal_access_token.scope_management.token
  sensitive   = true
}

# Non-sensitive remote candidates are intentionally exposed so the Bash entrypoint
# can stop safely if this module's local state is lost before an apply.
output "candidate_root_org_ids" {
  description = "Exact-name root organization IDs found before reconciliation."
  value       = local.root_org_ids
}

output "candidate_project_ids" {
  description = "Existing exact-name project IDs found before reconciliation."
  value       = local.existing_project_ids
}

output "candidate_application_ids" {
  description = "Existing exact-name OIDC application IDs found before reconciliation."
  value       = local.existing_application_ids
}

output "candidate_target_org_ids" {
  description = "Existing exact-name target organization IDs found before reconciliation."
  value       = local.target_org_ids
}

output "candidate_machine_user_ids" {
  description = "Existing exact-name machine-user IDs found before reconciliation."
  value       = local.existing_machine_user_ids
}
