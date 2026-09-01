#!/usr/bin/env bash

# Operator-side ZITADEL bootstrap. This script deliberately changes only the
# Terraform state under .local/zitadel-bootstrap and the documented runtime
# placeholders. It never syncs an Argo CD Application or seals unrelated Secrets.
set -euo pipefail
umask 077

REPOSITORY_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
TERRAFORM_DIR="${REPOSITORY_DIR}/terraform/zitadel-bootstrap"
STATE_DIR="${REPOSITORY_DIR}/.local/zitadel-bootstrap"
STATE_FILE="${STATE_DIR}/terraform.tfstate"
TF_DATA_DIR="${STATE_DIR}/tfdata"
PLAN_FILE="${STATE_DIR}/plan.tfplan"
PLAN_JSON_FILE="${STATE_DIR}/plan.json"
STATE_MARKER="${STATE_DIR}/state.marker"
TEMP_FILES=()
APPLICATION_GATE_TIMEOUT_SECONDS="${ZITADEL_APPLICATION_GATE_TIMEOUT_SECONDS:-600}"
HEALTH_TIMEOUT_SECONDS="${ZITADEL_HEALTH_TIMEOUT_SECONDS:-600}"
POLL_SECONDS="${ZITADEL_BOOTSTRAP_POLL_SECONDS:-5}"
PORT_FORWARD_PID=""
PORT_FORWARD_LOG="${STATE_DIR}/port-forward.log"

MODE=apply
SEAL=0
ROTATE_SECRET=0

usage() {
  cat <<'EOF'
Usage: ./setup-zitadel.sh [--check] [--seal] [--rotate-secret]

Reconcile the operator-owned ZITADEL objects for this deployment and patch the
runtime placeholders in 2-applications. The default is a mutating bootstrap;
--check runs a normal Terraform plan with detailed-exitcode and validates
repository consistency without patching files or sealing anything.

Options:
  --check  Do not apply Terraform, patch manifests, or seal a Secret.
  --seal   After a successful apply, seal only node-scope-management. This does
           not sync or open the application-secrets Argo CD gate. It explicitly
           permits replacing the existing stale one-key SealedSecret.
  --rotate-secret
           With --seal, explicitly authorize replacing a node-scope-management
           SealedSecret that already contains ZITADEL_ROOT_ORG_ID.
  --help   Show this help.

Authentication (precedence order):
  ZITADEL_ACCESS_TOKEN or ZITADEL_PAT     Token supplied directly by the caller.
  ZITADEL_ACCESS_TOKEN_FILE               Restrictive file containing the token.
  Kubernetes Secret unique/iam-admin-pat, key pat (default).

Configuration:
  ZITADEL_URL                              External ZITADEL URL (derived by default).
  UNIQUE_FRONTEND_BASE_URL                 Frontend origin (derived by default).
  ZITADEL_REDIRECT_URIS                    Comma-separated exact redirect override.
  ZITADEL_POST_LOGOUT_REDIRECT_URIS        Comma-separated exact logout override.
  ZITADEL_TARGET_ORG_NAME                  Target organization (default HPE Hosted Trial).
  ZITADEL_OIDC_DEV_MODE=true|false         Optional explicit OIDC dev-mode override.
  ZITADEL_USE_PORT_FORWARD=true|false       Use a local h2c fallback (default false).
  ZITADEL_INSECURE_SKIP_VERIFY_TLS=true     Only for explicitly approved test TLS.

The generated PAT is never printed. It is written only to Terraform state and
the ignored node-scope-management Secret, both kept with mode 0600. Do not
redirect Terraform output to a log or expose the ignored Secret.
EOF
}

die() {
  printf 'ERROR: %s\n' "$1" >&2
  exit 1
}

warn() {
  printf 'WARNING: %s\n' "$1" >&2
}

require_command() {
  command -v "$1" >/dev/null 2>&1 || die "missing required command: $1"
}

while (($# > 0)); do
  case "$1" in
    --check)
      [[ "${MODE}" == apply ]] || die "--check may only be specified once"
      MODE=check
      ;;
    --seal)
      [[ "${MODE}" == apply ]] || die "--seal cannot be combined with --check"
      SEAL=1
      ;;
    --rotate-secret)
      [[ "${MODE}" == apply ]] || die "--rotate-secret cannot be combined with --check"
      ROTATE_SECRET=1
      ;;
    --help|-h)
      usage
      exit 0
      ;;
    *)
      usage >&2
      die "unknown option: $1"
      ;;
  esac
  shift
done

for command in base64 curl git jq kubectl rg terraform yq; do
  require_command "${command}"
done

[[ "${SEAL}" == 0 || "${MODE}" == apply ]] || die "--seal cannot be combined with --check"
[[ "${ROTATE_SECRET}" == 0 || "${SEAL}" == 1 ]] \
  || die "--rotate-secret requires --seal"
[[ "${APPLICATION_GATE_TIMEOUT_SECONDS}" =~ ^[0-9]+$ && "${APPLICATION_GATE_TIMEOUT_SECONDS}" -gt 0 ]] \
  || die "ZITADEL_APPLICATION_GATE_TIMEOUT_SECONDS must be a positive integer"
[[ "${HEALTH_TIMEOUT_SECONDS}" =~ ^[0-9]+$ && "${HEALTH_TIMEOUT_SECONDS}" -gt 0 ]] \
  || die "ZITADEL_HEALTH_TIMEOUT_SECONDS must be a positive integer"
[[ "${POLL_SECONDS}" =~ ^[0-9]+$ && "${POLL_SECONDS}" -gt 0 ]] \
  || die "ZITADEL_BOOTSTRAP_POLL_SECONDS must be a positive integer"
[[ -d "${TERRAFORM_DIR}" ]] || die "Terraform module is missing: ${TERRAFORM_DIR}"
SEALED_NODE_SCOPE_FILE="${REPOSITORY_DIR}/2-applications/1-node-scope-management/node-scope-management.sealed-secret.yaml"

check_seal_authorization() {
  local has_root_org_id
  local encrypted_keys
  (( SEAL == 1 )) || return 0
  [[ -e "${SEALED_NODE_SCOPE_FILE}" ]] || return 0
  encrypted_keys="$(yq -r '(.spec.encryptedData // {}) | keys | sort | join(",")' \
    "${SEALED_NODE_SCOPE_FILE}")"
  [[ "${encrypted_keys}" == ZITADEL_PAT ||
    "${encrypted_keys}" == ZITADEL_PAT,ZITADEL_ROOT_ORG_ID ]] \
    || die "${SEALED_NODE_SCOPE_FILE} is not the expected node-scope-management PAT Secret; refusing to replace unexpected encrypted keys"
  has_root_org_id="$(yq -r '(.spec.encryptedData // {}) | has("ZITADEL_ROOT_ORG_ID")' \
    "${SEALED_NODE_SCOPE_FILE}")"
  if [[ "${has_root_org_id}" == true && "${ROTATE_SECRET}" == 0 ]]; then
    die "${SEALED_NODE_SCOPE_FILE} already contains ZITADEL_ROOT_ORG_ID; refusing rotation. Use --seal --rotate-secret after separately reviewing the replacement"
  fi
}
check_seal_authorization
git -C "${REPOSITORY_DIR}" check-ignore -q .local/zitadel-bootstrap/ \
  || die ".local/zitadel-bootstrap must remain ignored; refusing to create state elsewhere"
[[ ! -L "${STATE_DIR}" ]] || die "bootstrap state directory must not be a symlink: ${STATE_DIR}"
[[ ! -L "${TF_DATA_DIR}" ]] || die "Terraform data directory must not be a symlink: ${TF_DATA_DIR}"
[[ ! -L "${STATE_FILE}" ]] || die "Terraform state must not be a symlink: ${STATE_FILE}"

mkdir -p "${STATE_DIR}" "${TF_DATA_DIR}"
chmod 700 "${STATE_DIR}" "${TF_DATA_DIR}"

# The configured Harbor hostname is the repository's deployment-domain source.
# The HPE manifests use id.<domain> and unique.<domain>; explicit URL variables
# remain available for deployments whose ingress names differ.
CONFIGURED_REGISTRY="$(yq -r '.harbor.registry // ""' "${REPOSITORY_DIR}/versions.yaml")"
[[ -n "${CONFIGURED_REGISTRY}" && "${CONFIGURED_REGISTRY}" != "null" ]] \
  || die "harbor.registry is missing from versions.yaml"
CONFIGURED_DOMAIN="${CONFIGURED_REGISTRY#harbor.}"
[[ "${CONFIGURED_DOMAIN}" != "${CONFIGURED_REGISTRY}" ]] \
  || die "harbor.registry must use the expected harbor.<domain> form"

if [[ "${CONFIGURED_DOMAIN}" == localhost ]]; then
  DEFAULT_SCHEME=http
else
  DEFAULT_SCHEME=https
fi

ZITADEL_URL="${ZITADEL_URL:-${DEFAULT_SCHEME}://id.${CONFIGURED_DOMAIN}}"
UNIQUE_FRONTEND_BASE_URL="${UNIQUE_FRONTEND_BASE_URL:-${DEFAULT_SCHEME}://unique.${CONFIGURED_DOMAIN}}"

[[ "${ZITADEL_URL}" =~ ^(https?)://([^/]+)(/)?$ ]] \
  || die "ZITADEL_URL must be an http(s) URL without a path: ${ZITADEL_URL}"
ZITADEL_SCHEME="${BASH_REMATCH[1]}"
ZITADEL_AUTHORITY="${BASH_REMATCH[2]}"
[[ "${UNIQUE_FRONTEND_BASE_URL}" =~ ^https?://[^/]+/?$ ]] \
  || die "UNIQUE_FRONTEND_BASE_URL must be an http(s) origin without a path"

ZITADEL_DOMAIN="${ZITADEL_DOMAIN:-${ZITADEL_AUTHORITY}}"
ZITADEL_PORT="${ZITADEL_PORT:-}"
if [[ -z "${ZITADEL_PORT}" && "${ZITADEL_AUTHORITY}" =~ ^[^:]+:([0-9]+)$ ]]; then
  ZITADEL_PORT="${BASH_REMATCH[1]}"
  ZITADEL_DOMAIN="${ZITADEL_AUTHORITY%:*}"
fi

case "${ZITADEL_INSECURE:-}" in
  "")
    if [[ "${ZITADEL_SCHEME}" == http ]]; then
      ZITADEL_INSECURE=true
    else
      ZITADEL_INSECURE=false
    fi
    ;;
  true|false) ;;
  *) die "ZITADEL_INSECURE must be true or false" ;;
esac

if [[ -n "${ZITADEL_OIDC_DEV_MODE:-}" ]]; then
  case "${ZITADEL_OIDC_DEV_MODE}" in
    true|false) ;;
    *) die "ZITADEL_OIDC_DEV_MODE must be true or false" ;;
  esac
  OIDC_DEV_MODE="${ZITADEL_OIDC_DEV_MODE}"
elif [[ "${ZITADEL_SCHEME}" == http ]]; then
  OIDC_DEV_MODE=true
else
  OIDC_DEV_MODE=false
fi

ZITADEL_INSECURE_SKIP_VERIFY_TLS="${ZITADEL_INSECURE_SKIP_VERIFY_TLS:-false}"
case "${ZITADEL_INSECURE_SKIP_VERIFY_TLS}" in
  true|false) ;;
  *) die "ZITADEL_INSECURE_SKIP_VERIFY_TLS must be true or false" ;;
esac

ZITADEL_USE_PORT_FORWARD="${ZITADEL_USE_PORT_FORWARD:-false}"
case "${ZITADEL_USE_PORT_FORWARD}" in
  true|false) ;;
  *) die "ZITADEL_USE_PORT_FORWARD must be true or false" ;;
esac

export TF_DATA_DIR
export TF_VAR_zitadel_domain="${ZITADEL_DOMAIN}"
export TF_VAR_zitadel_insecure="${ZITADEL_INSECURE}"
export TF_VAR_oidc_dev_mode="${OIDC_DEV_MODE}"
export TF_VAR_insecure_skip_verify_tls="${ZITADEL_INSECURE_SKIP_VERIFY_TLS}"
export TF_VAR_frontend_base_url="${UNIQUE_FRONTEND_BASE_URL}"
export TF_VAR_transport_headers='{}'
if [[ -n "${ZITADEL_PORT}" ]]; then
  export TF_VAR_zitadel_port="${ZITADEL_PORT}"
else
  unset TF_VAR_zitadel_port
fi
if [[ -n "${ZITADEL_TARGET_ORG_NAME:-}" ]]; then
  export TF_VAR_target_org_name="${ZITADEL_TARGET_ORG_NAME}"
else
  unset TF_VAR_target_org_name
fi
if [[ -n "${ZITADEL_SCOPE_MANAGEMENT_PAT_EXPIRATION_DATE:-}" ]]; then
  export TF_VAR_scope_management_pat_expiration_date="${ZITADEL_SCOPE_MANAGEMENT_PAT_EXPIRATION_DATE}"
else
  unset TF_VAR_scope_management_pat_expiration_date
fi

csv_to_json() {
  local value="$1"
  jq -cn --arg value "${value}" \
    '$value | split(",") | map(gsub("^[[:space:]]+|[[:space:]]+$"; "")) | map(select(length > 0))'
}

REDIRECT_OVERRIDE="${ZITADEL_REDIRECT_URIS:-${ZITADEL_INIT_REDIRECT_URIS:-}}"
POST_LOGOUT_OVERRIDE="${ZITADEL_POST_LOGOUT_REDIRECT_URIS:-${ZITADEL_INIT_POST_LOGOUT_URIS:-}}"
if [[ -n "${REDIRECT_OVERRIDE}" ]]; then
  export TF_VAR_redirect_uris="$(csv_to_json "${REDIRECT_OVERRIDE}")"
else
  unset TF_VAR_redirect_uris
fi
if [[ -n "${POST_LOGOUT_OVERRIDE}" ]]; then
  export TF_VAR_post_logout_redirect_uris="$(csv_to_json "${POST_LOGOUT_OVERRIDE}")"
else
  unset TF_VAR_post_logout_redirect_uris
fi

base64_decode() {
  if base64 --decode </dev/null >/dev/null 2>&1; then
    base64 --decode
  else
    base64 -D
  fi
}

check_token_file_permissions() {
  local file="$1"
  local mode
  [[ -f "${file}" ]] || die "token file does not exist: ${file}"
  [[ ! -L "${file}" ]] || die "token file must not be a symlink: ${file}"
  [[ -r "${file}" ]] || die "token file is not readable: ${file}"
  mode="$(stat -f '%Lp' "${file}" 2>/dev/null || true)"
  if [[ ! "${mode}" =~ ^[0-7]{3,4}$ ]]; then
    mode="$(stat -c '%a' "${file}" 2>/dev/null || true)"
  fi
  [[ "${mode}" =~ ^[0-7]{3,4}$ ]] || die "cannot inspect token-file permissions: ${file}"
  mode="${mode: -3}"
  [[ "${mode}" == 400 || "${mode}" == 600 ]] \
    || die "token file must be owner-only (mode 400/600): ${file}"
}

read_access_token() {
  local encoded=""
  local token_file
  local deadline

  if [[ -n "${ZITADEL_ACCESS_TOKEN:-}" && -n "${ZITADEL_PAT:-}" &&
    "${ZITADEL_ACCESS_TOKEN}" != "${ZITADEL_PAT}" ]]; then
    die "ZITADEL_ACCESS_TOKEN and ZITADEL_PAT disagree; set only one"
  fi

  if [[ -n "${ZITADEL_ACCESS_TOKEN:-}" || -n "${ZITADEL_PAT:-}" ]]; then
    if [[ -n "${ZITADEL_ACCESS_TOKEN:-}" ]]; then
      BOOTSTRAP_TOKEN="${ZITADEL_ACCESS_TOKEN}"
    else
      BOOTSTRAP_TOKEN="${ZITADEL_PAT}"
    fi
  elif [[ -n "${ZITADEL_ACCESS_TOKEN_FILE:-}" ]]; then
    token_file="${ZITADEL_ACCESS_TOKEN_FILE}"
    check_token_file_permissions "${token_file}"
    BOOTSTRAP_TOKEN="$(cat "${token_file}")"
  else
    deadline=$(( $(date +%s) + HEALTH_TIMEOUT_SECONDS ))
    printf 'Waiting for Secret unique/iam-admin-pat key pat ...\n'
    while (( $(date +%s) < deadline )); do
      encoded="$(kubectl --namespace unique get secret iam-admin-pat \
        -o jsonpath='{.data.pat}' 2>/dev/null || true)"
      if [[ -n "${encoded}" ]]; then
        break
      fi
      sleep "${POLL_SECONDS}"
    done
    [[ -n "${encoded}" ]] \
      || die "Secret unique/iam-admin-pat key pat is unavailable; set ZITADEL_ACCESS_TOKEN or ZITADEL_ACCESS_TOKEN_FILE"
    BOOTSTRAP_TOKEN="$(printf '%s' "${encoded}" | base64_decode)"
  fi

  [[ -n "${BOOTSTRAP_TOKEN}" ]] || die "the ZITADEL access token is empty"
  [[ "${BOOTSTRAP_TOKEN}" != *[[:space:]]* ]] \
    || die "the ZITADEL access token contains whitespace"
  export TF_VAR_zitadel_access_token="${BOOTSTRAP_TOKEN}"
}

health_curl_args=(-fsS --max-time 10)
if [[ "${ZITADEL_INSECURE_SKIP_VERIFY_TLS}" == true ]]; then
  health_curl_args+=(-k)
fi

wait_for_zitadel() {
  local health_url="${ZITADEL_URL%/}/debug/ready"
  local deadline=$(( $(date +%s) + HEALTH_TIMEOUT_SECONDS ))
  printf 'Waiting for ZITADEL health at %s ...\n' "${health_url}"
  while (( $(date +%s) < deadline )); do
    if curl "${health_curl_args[@]}" -o /dev/null "${health_url}"; then
      printf 'ZITADEL health check passed.\n'
      return 0
    fi
    sleep "${POLL_SECONDS}"
  done
  die "ZITADEL did not become ready within ${HEALTH_TIMEOUT_SECONDS}s"
}

wait_for_application_gate() {
  local deadline=$(( $(date +%s) + APPLICATION_GATE_TIMEOUT_SECONDS ))
  local status
  local health
  local sync
  printf 'Waiting for the existing application-secrets Argo CD gate ...\n'
  while (( $(date +%s) < deadline )); do
    status="$(kubectl --namespace unique get application application-secrets \
      -o jsonpath='{.status.health.status}{"|"}{.status.sync.status}' 2>/dev/null || true)"
    if [[ -n "${status}" && "${status}" != '|' ]]; then
      health="${status%%|*}"
      sync="${status#*|}"
      printf 'application-secrets gate: health=%s sync=%s (this script will not sync it)\n' \
        "${health:-unknown}" "${sync:-unknown}"
      if [[ "${MODE}" == apply && "${sync}" != OutOfSync ]]; then
        die "application-secrets gate must be OutOfSync (closed) before a mutating bootstrap; observed ${sync}. This script never opens or syncs the gate"
      fi
      return 0
    fi
    sleep "${POLL_SECONDS}"
  done
  die "application-secrets Application was not observed within ${APPLICATION_GATE_TIMEOUT_SECONDS}s"
}

validate_repository_reference_shape() {
  local file
  local value
  local project_placeholder_count=0
  local project_populated_count=0
  local project_file_count=0
  local frontend_placeholder_count=0
  local frontend_populated_count=0
  local plugin_value
  local root_org_value

  while IFS= read -r -d '' file; do
    value="$(yq -r '.spec.source.helm.valuesObject.env.ZITADEL_PROJECT_ID // ""' "${file}")"
    [[ -n "${value}" ]] || continue
    project_file_count=$((project_file_count + 1))
    case "${value}" in
      __ZITADEL_PROJECT_ID__|change-me|hpe-hosted-trial)
        project_placeholder_count=$((project_placeholder_count + 1))
        ;;
      *)
        project_populated_count=$((project_populated_count + 1))
        ;;
    esac
  done < <(find "${REPOSITORY_DIR}/2-applications" -type f -name app.yaml -print0)
  [[ "${project_file_count}" -gt 0 ]] || die "no application ZITADEL_PROJECT_ID values were found"
  [[ "${project_placeholder_count}" == 0 || "${project_populated_count}" == 0 ]] \
    || die "application ZITADEL_PROJECT_ID values are in a mixed placeholder/populated state; refusing to continue"

  for file in \
    "${REPOSITORY_DIR}/2-applications/3-admin-app/app.yaml" \
    "${REPOSITORY_DIR}/2-applications/3-chat-app/app.yaml" \
    "${REPOSITORY_DIR}/2-applications/3-knowledge-upload-app/app.yaml" \
    "${REPOSITORY_DIR}/2-applications/3-theme-app/app.yaml"; do
    [[ -f "${file}" ]] || die "missing frontend application manifest: ${file}"
    value="$(yq -r '.spec.source.helm.valuesObject.env.ZITADEL_CLIENT_ID // ""' "${file}")"
    [[ -n "${value}" ]] || die "ZITADEL_CLIENT_ID is missing from ${file}"
    case "${value}" in
      __ZITADEL_CLIENT_ID__|change-me)
        frontend_placeholder_count=$((frontend_placeholder_count + 1))
        ;;
      *)
        frontend_populated_count=$((frontend_populated_count + 1))
        ;;
    esac
  done
  [[ "${frontend_placeholder_count}" == 0 || "${frontend_populated_count}" == 0 ]] \
    || die "frontend ZITADEL_CLIENT_ID values are in a mixed placeholder/populated state; refusing to continue"

  root_org_value="$(yq -r '.spec.source.helm.valuesObject.env.ZITADEL_ROOT_ORG_ID // ""' \
    "${REPOSITORY_DIR}/2-applications/1-node-scope-management/app.yaml")"
  [[ -n "${root_org_value}" ]] || die "node-scope-management ZITADEL_ROOT_ORG_ID is missing"

  plugin_value="$(yq -r '.config.zitadel_project_id // ""' \
    "${REPOSITORY_DIR}/2-applications/0-kong-config/jwt-auth.kong-cluster-plugin.yaml")"
  [[ -n "${plugin_value}" ]] || die "Kong zitadel_project_id is missing"
  if (( project_placeholder_count > 0 )); then
    [[ "${root_org_value}" == __ZITADEL_ROOT_ORG_ID__ ]] \
      || die "root organization ID and application project IDs are in a mixed placeholder/populated state"
    [[ "${project_populated_count}" == 0 && \
      ( "${plugin_value}" == __ZITADEL_PROJECT_ID__ || "${plugin_value}" == change-me || \
        "${plugin_value}" == hpe-hosted-trial ) ]] \
      || die "Kong and application project IDs are in a mixed placeholder/populated state; refusing to continue"
    [[ "${frontend_placeholder_count}" == 4 ]] \
      || die "frontend and application ZITADEL IDs are in a mixed placeholder/populated state; refusing to continue"
  else
    [[ "${root_org_value}" != __ZITADEL_ROOT_ORG_ID__ ]] \
      || die "root organization ID and application project IDs are in a mixed placeholder/populated state"
    [[ "${plugin_value}" != __ZITADEL_PROJECT_ID__ && \
      "${plugin_value}" != change-me && "${plugin_value}" != hpe-hosted-trial ]] \
      || die "Kong and application project IDs are in a mixed placeholder/populated state; refusing to continue"
    [[ "${frontend_populated_count}" == 4 ]] \
      || die "frontend and application ZITADEL IDs are in a mixed placeholder/populated state; refusing to continue"
  fi
}

start_zitadel_port_forward() {
  local forwarded_port=""
  local deadline

  [[ "${ZITADEL_USE_PORT_FORWARD}" == true ]] || return 0
  : >"${PORT_FORWARD_LOG}"
  chmod 600 "${PORT_FORWARD_LOG}"
  kubectl --namespace unique port-forward service/zitadel :8080 \
    >"${PORT_FORWARD_LOG}" 2>&1 &
  PORT_FORWARD_PID=$!
  deadline=$(( $(date +%s) + 30 ))
  while (( $(date +%s) < deadline )); do
    if ! kill -0 "${PORT_FORWARD_PID}" 2>/dev/null; then
      die "ZITADEL port-forward exited early: $(tail -n 1 "${PORT_FORWARD_LOG}")"
    fi
    forwarded_port="$(sed -nE 's/^Forwarding from 127\.0\.0\.1:([0-9]+) -> 8080$/\1/p' \
      "${PORT_FORWARD_LOG}" | head -n1)"
    [[ -n "${forwarded_port}" ]] && break
    sleep 1
  done
  [[ "${forwarded_port}" =~ ^[0-9]+$ ]] \
    || die "could not determine the local ZITADEL port-forward port"

  # The external ingress serves ordinary HTTP/2 but closes the provider's gRPC
  # streams. Connect to the h2c Service directly while preserving the external
  # Host so ZITADEL can select the correct instance.
  export TF_VAR_zitadel_domain=127.0.0.1
  export TF_VAR_zitadel_port="${forwarded_port}"
  export TF_VAR_zitadel_insecure=true
  export TF_VAR_insecure_skip_verify_tls=false
  export TF_VAR_transport_headers
  TF_VAR_transport_headers="$(jq -cn --arg host "${ZITADEL_AUTHORITY}" '{Host: $host}')"
  printf 'Using local h2c port-forward for ZITADEL provider API calls.\n'
}

state_contains_address() {
  local address="$1"
  printf '%s\n' "${STATE_ADDRESSES:-}" | grep -Fqx "${address}"
}

check_state_safety_before_plan() {
  if [[ -f "${STATE_MARKER}" && ! -f "${STATE_FILE}" ]]; then
    die "state marker exists but Terraform state is missing; recover/import the state before continuing"
  fi

  STATE_ADDRESSES=""
  if [[ -f "${STATE_FILE}" ]]; then
    STATE_ADDRESSES="$(terraform -chdir="${TERRAFORM_DIR}" state list 2>/dev/null || true)"
  fi

  if [[ -f "${STATE_MARKER}" ]]; then
    for required_address in \
      zitadel_project.unique_apps \
      zitadel_application_oidc.standalone_apps \
      zitadel_org.target_tenant \
      zitadel_project_grant.target_tenant \
      zitadel_machine_user.scope_management \
      zitadel_instance_member.scope_management \
      zitadel_personal_access_token.scope_management; do
      state_contains_address "${required_address}" \
        || die "state marker exists but ${required_address} is absent; refusing to create a duplicate"
    done
    role_count="$(printf '%s\n' "${STATE_ADDRESSES}" | grep -c '^zitadel_project_role\.unique_apps\[' || true)"
    [[ "${role_count}" == 13 ]] \
      || die "state marker exists but the managed role set is incomplete (${role_count}/13)"
  fi
}

run_terraform_init() {
  terraform -chdir="${TERRAFORM_DIR}" init -reconfigure -input=false
}

run_detailed_plan() {
  local result
  set +e
  terraform -chdir="${TERRAFORM_DIR}" plan \
    -input=false \
    -detailed-exitcode \
    -out="${PLAN_FILE}"
  result=$?
  set -e
  case "${result}" in
    0|2) PLAN_EXIT_CODE="${result}" ;;
    *) die "Terraform plan failed (exit ${result})" ;;
  esac
}

check_plan_candidates() {
  local candidate_count
  local address

  terraform -chdir="${TERRAFORM_DIR}" show -json "${PLAN_FILE}" >"${PLAN_JSON_FILE}"
  for candidate in project application target_org machine_user; do
    case "${candidate}" in
      project)
        candidate_count="$(jq -r 'try (.planned_values.outputs.candidate_project_ids.value // []) | length' "${PLAN_JSON_FILE}")"
        address="zitadel_project.unique_apps"
        ;;
      application)
        candidate_count="$(jq -r 'try (.planned_values.outputs.candidate_application_ids.value // []) | length' "${PLAN_JSON_FILE}")"
        address="zitadel_application_oidc.standalone_apps"
        ;;
      target_org)
        candidate_count="$(jq -r 'try (.planned_values.outputs.candidate_target_org_ids.value // []) | length' "${PLAN_JSON_FILE}")"
        address="zitadel_org.target_tenant"
        ;;
      machine_user)
        candidate_count="$(jq -r 'try (.planned_values.outputs.candidate_machine_user_ids.value // []) | length' "${PLAN_JSON_FILE}")"
        address="zitadel_machine_user.scope_management"
        ;;
    esac
    [[ "${candidate_count}" =~ ^[0-9]+$ ]] || die "could not inspect Terraform candidate output for ${candidate}"
    if (( candidate_count > 0 )) && ! state_contains_address "${address}"; then
      die "an existing exact-name ${candidate} was found remotely, but ${address} is not in local state; refusing to create a duplicate"
    fi
  done
}

replace_root_org_placeholder() {
  local file="${REPOSITORY_DIR}/2-applications/1-node-scope-management/app.yaml"
  local current

  current="$(yq -r '.spec.source.helm.valuesObject.env.ZITADEL_ROOT_ORG_ID // ""' "${file}")"
  [[ -n "${current}" ]] || die "ZITADEL_ROOT_ORG_ID is missing from ${file}"
  [[ "${current}" == "${ROOT_ORG_ID}" ]] && return 0
  ZITADEL_BOOTSTRAP_ROOT_ORG_ID="${ROOT_ORG_ID}" yq -i \
    '.spec.source.helm.valuesObject.env.ZITADEL_ROOT_ORG_ID = strenv(ZITADEL_BOOTSTRAP_ROOT_ORG_ID)' \
    "${file}"
}

replace_project_placeholders() {
  local file
  local current
  while IFS= read -r -d '' file; do
    current="$(yq -r '.spec.source.helm.valuesObject.env.ZITADEL_PROJECT_ID // ""' "${file}")"
    [[ -n "${current}" ]] || continue
    [[ "${current}" == "${PROJECT_ID}" ]] && continue
    ZITADEL_BOOTSTRAP_PROJECT_ID="${PROJECT_ID}" yq -i \
      '.spec.source.helm.valuesObject.env.ZITADEL_PROJECT_ID = strenv(ZITADEL_BOOTSTRAP_PROJECT_ID)' \
      "${file}"
  done < <(find "${REPOSITORY_DIR}/2-applications" -type f -name app.yaml -print0)
}

replace_frontend_client_placeholders() {
  local file
  local current
  for file in \
    "${REPOSITORY_DIR}/2-applications/3-admin-app/app.yaml" \
    "${REPOSITORY_DIR}/2-applications/3-chat-app/app.yaml" \
    "${REPOSITORY_DIR}/2-applications/3-knowledge-upload-app/app.yaml" \
    "${REPOSITORY_DIR}/2-applications/3-theme-app/app.yaml"; do
    [[ -f "${file}" ]] || die "missing frontend application manifest: ${file}"
    current="$(yq -r '.spec.source.helm.valuesObject.env.ZITADEL_CLIENT_ID // ""' "${file}")"
    if [[ "${current}" == "${CLIENT_ID}" ]]; then
      continue
    fi
    ZITADEL_BOOTSTRAP_CLIENT_ID="${CLIENT_ID}" yq -i \
      '.spec.source.helm.valuesObject.env.ZITADEL_CLIENT_ID = strenv(ZITADEL_BOOTSTRAP_CLIENT_ID)' \
      "${file}"
  done
}

replace_kong_project_placeholder() {
  local file="${REPOSITORY_DIR}/2-applications/0-kong-config/jwt-auth.kong-cluster-plugin.yaml"
  local current
  [[ -f "${file}" ]] || die "missing Kong JWT plugin manifest"
  current="$(yq -r '.config.zitadel_project_id // ""' "${file}")"
  [[ "${current}" == "${PROJECT_ID}" ]] && return 0
  ZITADEL_BOOTSTRAP_PROJECT_ID="${PROJECT_ID}" yq -i \
    '.config.zitadel_project_id = strenv(ZITADEL_BOOTSTRAP_PROJECT_ID)' "${file}"
}

write_node_scope_management_secret() {
  local file="${REPOSITORY_DIR}/2-applications/1-node-scope-management/node-scope-management.secret.yaml"
  local example="${REPOSITORY_DIR}/2-applications/1-node-scope-management/node-scope-management.secret.yaml.example"
  [[ -f "${example}" ]] || die "missing node-scope-management Secret example"
  if [[ ! -f "${file}" ]]; then
    cp "${example}" "${file}"
  fi
  chmod 600 "${file}"
  git -C "${REPOSITORY_DIR}" check-ignore -q "${file}" \
    || die "node-scope-management.secret.yaml must remain ignored"
  ZITADEL_BOOTSTRAP_PAT="${PAT}" \
  ZITADEL_BOOTSTRAP_ROOT_ORG_ID="${ROOT_ORG_ID}" \
    yq -i '.stringData.ZITADEL_PAT = strenv(ZITADEL_BOOTSTRAP_PAT) |
      .stringData.ZITADEL_ROOT_ORG_ID = strenv(ZITADEL_BOOTSTRAP_ROOT_ORG_ID)' "${file}"
  chmod 600 "${file}"
}

validate_repository_consistency() {
  local expected_root="${1:-}"
  local expected_project="${2:-}"
  local expected_client="${3:-}"
  local file
  local value
  local project_values=""
  local project_file_count=0
  local frontend_values=""
  local frontend_count=0
  local plugin_value
  local secret_file="${REPOSITORY_DIR}/2-applications/1-node-scope-management/node-scope-management.secret.yaml"
  local app_root
  local secret_root
  local secret_pat

  while IFS= read -r -d '' file; do
    value="$(yq -r '.spec.source.helm.valuesObject.env.ZITADEL_PROJECT_ID // ""' "${file}")"
    [[ -n "${value}" ]] || continue
    project_file_count=$((project_file_count + 1))
    project_values+="${value}"$'\n'
    [[ "${value}" != __ZITADEL_PROJECT_ID__ && "${value}" != change-me && "${value}" != hpe-hosted-trial ]] \
      || die "ZITADEL_PROJECT_ID placeholder remains in ${file}"
    if [[ -n "${expected_project}" && "${value}" != "${expected_project}" ]]; then
      die "ZITADEL_PROJECT_ID in ${file} disagrees with Terraform state"
    fi
  done < <(find "${REPOSITORY_DIR}/2-applications" -type f -name app.yaml -print0)
  [[ "${project_file_count}" -gt 0 ]] || die "no application ZITADEL_PROJECT_ID values were found"
  [[ "$(printf '%s' "${project_values}" | sort -u | sed '/^$/d' | wc -l | tr -d ' ')" == 1 ]] \
    || die "application ZITADEL_PROJECT_ID values are inconsistent"

  for file in \
    "${REPOSITORY_DIR}/2-applications/3-admin-app/app.yaml" \
    "${REPOSITORY_DIR}/2-applications/3-chat-app/app.yaml" \
    "${REPOSITORY_DIR}/2-applications/3-knowledge-upload-app/app.yaml" \
    "${REPOSITORY_DIR}/2-applications/3-theme-app/app.yaml"; do
    value="$(yq -r '.spec.source.helm.valuesObject.env.ZITADEL_CLIENT_ID // ""' "${file}")"
    frontend_count=$((frontend_count + 1))
    frontend_values+="${value}"$'\n'
    [[ -n "${value}" && "${value}" != __ZITADEL_CLIENT_ID__ && "${value}" != change-me ]] \
      || die "ZITADEL_CLIENT_ID placeholder remains in ${file}"
    if [[ -n "${expected_client}" && "${value}" != "${expected_client}" ]]; then
      die "ZITADEL_CLIENT_ID in ${file} disagrees with Terraform state"
    fi
  done
  [[ "${frontend_count}" == 4 ]] || die "expected four frontend client IDs"
  [[ "$(printf '%s' "${frontend_values}" | sort -u | sed '/^$/d' | wc -l | tr -d ' ')" == 1 ]] \
    || die "frontend ZITADEL_CLIENT_ID values are inconsistent"

  app_root="$(yq -r '.spec.source.helm.valuesObject.env.ZITADEL_ROOT_ORG_ID // ""' \
    "${REPOSITORY_DIR}/2-applications/1-node-scope-management/app.yaml")"
  [[ -n "${app_root}" && "${app_root}" != __ZITADEL_ROOT_ORG_ID__ ]] \
    || die "node-scope-management ZITADEL_ROOT_ORG_ID is empty or a placeholder"
  if [[ -n "${expected_root}" && "${app_root}" != "${expected_root}" ]]; then
    die "node-scope-management ZITADEL_ROOT_ORG_ID disagrees with Terraform state"
  fi

  plugin_value="$(yq -r '.config.zitadel_project_id // ""' \
    "${REPOSITORY_DIR}/2-applications/0-kong-config/jwt-auth.kong-cluster-plugin.yaml")"
  [[ -n "${plugin_value}" && "${plugin_value}" != __ZITADEL_PROJECT_ID__ && "${plugin_value}" != change-me ]] \
    || die "Kong zitadel_project_id placeholder remains"
  [[ -z "${expected_project}" || "${plugin_value}" == "${expected_project}" ]] \
    || die "Kong zitadel_project_id disagrees with Terraform state"

  [[ -f "${secret_file}" ]] || die "node-scope-management.secret.yaml is missing"
  git -C "${REPOSITORY_DIR}" check-ignore -q "${secret_file}" \
    || die "node-scope-management.secret.yaml must be ignored"
  secret_root="$(yq -r '.stringData.ZITADEL_ROOT_ORG_ID // ""' "${secret_file}")"
  secret_pat="$(yq -r '.stringData.ZITADEL_PAT // ""' "${secret_file}")"
  [[ -n "${secret_root}" && "${secret_root}" != __ZITADEL_ROOT_ORG_ID__ ]] \
    || die "node-scope-management root organization ID is empty or a placeholder"
  [[ -n "${secret_pat}" && "${secret_pat}" != change-me ]] \
    || die "node-scope-management PAT is empty or a placeholder"
  [[ "${secret_root}" == "${app_root}" ]] \
    || die "node-scope-management manifest and Secret root organization IDs disagree"
  if [[ -n "${expected_root}" && "${secret_root}" != "${expected_root}" ]]; then
    die "node-scope-management root organization ID disagrees with Terraform state"
  fi
}

secure_local_state_files() {
  local file
  for file in "${STATE_FILE}" "${STATE_FILE}.backup" "${PLAN_FILE}" "${PLAN_JSON_FILE}" "${STATE_MARKER}"; do
    [[ -e "${file}" ]] || continue
    if [[ -L "${file}" ]]; then
      printf 'ERROR: refusing to follow symlink in local bootstrap state: %s\n' "${file}" >&2
      return 1
    fi
    chmod 600 "${file}"
  done
}

cleanup_local_plan() {
  if [[ -n "${PORT_FORWARD_PID}" ]]; then
    kill "${PORT_FORWARD_PID}" 2>/dev/null || true
    wait "${PORT_FORWARD_PID}" 2>/dev/null || true
  fi
  rm -f "${PLAN_FILE}" "${PLAN_JSON_FILE}" "${PORT_FORWARD_LOG}"
  ((${#TEMP_FILES[@]} == 0)) || rm -f "${TEMP_FILES[@]}"
  secure_local_state_files
}
trap cleanup_local_plan EXIT

validate_repository_reference_shape
read_access_token
wait_for_zitadel
wait_for_application_gate
start_zitadel_port_forward
run_terraform_init
secure_local_state_files
check_state_safety_before_plan
run_detailed_plan
check_plan_candidates

if [[ "${MODE}" == check ]]; then
  if [[ -f "${STATE_FILE}" ]]; then
    CHECK_ROOT_ORG_ID="$(terraform -chdir="${TERRAFORM_DIR}" output -raw root_org_id 2>/dev/null || true)"
    CHECK_PROJECT_ID="$(terraform -chdir="${TERRAFORM_DIR}" output -raw project_id 2>/dev/null || true)"
    CHECK_CLIENT_ID="$(terraform -chdir="${TERRAFORM_DIR}" output -raw client_id 2>/dev/null || true)"
  else
    CHECK_ROOT_ORG_ID=""
    CHECK_PROJECT_ID=""
    CHECK_CLIENT_ID=""
  fi
  validate_repository_consistency "${CHECK_ROOT_ORG_ID}" "${CHECK_PROJECT_ID}" "${CHECK_CLIENT_ID}"
  if [[ "${PLAN_EXIT_CODE}" == 2 ]]; then
    warn "Terraform reports drift or pending changes (detailed-exitcode=2)"
    exit 2
  fi
  printf 'PASS: ZITADEL Terraform state and deployment references are consistent.\n'
  exit 0
fi

# ZITADEL serializes event writes through its event store. Applying independent
# projects, roles, users, and applications concurrently can race on a fresh
# PostgreSQL database and produce duplicate events2 primary keys.
terraform -chdir="${TERRAFORM_DIR}" apply -parallelism=1 -input=false "${PLAN_FILE}"
ROOT_ORG_ID="$(terraform -chdir="${TERRAFORM_DIR}" output -raw root_org_id)"
PROJECT_ID="$(terraform -chdir="${TERRAFORM_DIR}" output -raw project_id)"
CLIENT_ID="$(terraform -chdir="${TERRAFORM_DIR}" output -raw client_id)"
PAT="$(terraform -chdir="${TERRAFORM_DIR}" output -raw pat)"
[[ -n "${ROOT_ORG_ID}" && -n "${PROJECT_ID}" && -n "${CLIENT_ID}" && -n "${PAT}" ]] \
  || die "Terraform did not return all required ZITADEL outputs"

replace_root_org_placeholder
replace_project_placeholders
replace_frontend_client_placeholders
replace_kong_project_placeholder
write_node_scope_management_secret
validate_repository_consistency "${ROOT_ORG_ID}" "${PROJECT_ID}" "${CLIENT_ID}"

cat >"${STATE_MARKER}" <<EOF
format=1
root_org_id=${ROOT_ORG_ID}
project_id=${PROJECT_ID}
client_id=${CLIENT_ID}
managed_resources=zitadel_project.unique_apps,zitadel_project_role.unique_apps,zitadel_application_oidc.standalone_apps,zitadel_org.target_tenant,zitadel_project_grant.target_tenant,zitadel_machine_user.scope_management,zitadel_instance_member.scope_management,zitadel_personal_access_token.scope_management
EOF
chmod 600 "${STATE_MARKER}"
secure_local_state_files
unset TF_VAR_zitadel_access_token BOOTSTRAP_TOKEN

if (( SEAL == 1 )); then
  printf 'Sealing only node-scope-management (the Argo CD gate remains closed) ...\n'
  "${REPOSITORY_DIR}/seal-secrets.sh" node-scope-management
fi

printf '\nZITADEL bootstrap complete. The generated PAT was written only to the\n'
printf 'ignored node-scope-management Secret and restrictive Terraform state.\n'
printf 'ZITADEL_ROOT_ORG_ID=%s\n' "${ROOT_ORG_ID}"
printf 'ZITADEL_PROJECT_ID=%s\n' "${PROJECT_ID}"
printf 'ZITADEL_CLIENT_ID=%s\n' "${CLIENT_ID}"
printf '\nNext steps:\n'
printf '  1. Review the tracked manifest diff and the generated node-scope-management sealed Secret.\n'
printf '  2. Commit and push the reviewed changes.\n'
printf '  3. Manually sync application-secrets after review; this script never opens or syncs that gate.\n'
if (( SEAL == 0 )); then
  printf '  4. If the application Secret should be sealed now, rerun with --seal (only node-scope-management is sealed).\n'
fi

unset TF_VAR_zitadel_access_token BOOTSTRAP_TOKEN PAT
