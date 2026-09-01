#!/usr/bin/env bash
set -euo pipefail

# Prepares a finished HPE demo on top of a deployed trial: the HPE theme, a demo
# human user, and a single chat space backed by the LiteLLM-served GLM model.
# Every step is idempotent and safe to re-run.

REPOSITORY_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ASSET_DIR="${REPOSITORY_DIR}/assets/hpe"
TERRAFORM_DIR="${REPOSITORY_DIR}/terraform/zitadel-bootstrap"
STATE_DIR="${REPOSITORY_DIR}/.local/zitadel-bootstrap"

DEMO_USER_EMAIL="${DEMO_USER_EMAIL:-demo@unique.ai}"
DEMO_USER_GIVEN_NAME="${DEMO_USER_GIVEN_NAME:-Demo}"
DEMO_USER_FAMILY_NAME="${DEMO_USER_FAMILY_NAME:-User}"
DEMO_USER_ROLES="${DEMO_USER_ROLES:-chat.chat.basic,chat.chat.unlimited,chat.knowledge.read,chat.knowledge.write,chat.admin.all,admin.space.write}"

SETUP_MACHINE_USERNAME="${SETUP_MACHINE_USERNAME:-hpe-trial-setup}"
SETUP_MACHINE_ROLES="${SETUP_MACHINE_ROLES:-chat.chat.basic,chat.admin.all,admin.space.write,admin.user-management.write}"

THEME_TAB_NAME="${THEME_TAB_NAME:-HPE AI}"
THEME_SUPPORT_EMAIL="${THEME_SUPPORT_EMAIL:-enterprise-support@unique.ai}"

DEMO_SPACE_NAME="${DEMO_SPACE_NAME:-HPE AI Assistant}"
DEMO_SPACE_MODEL="${DEMO_SPACE_MODEL:-litellm:unique-chat-glm-5.3}"
DEMO_SPACE_DESCRIPTION="${DEMO_SPACE_DESCRIPTION:-Chat with GLM 5.3 served through the on-cluster LiteLLM gateway. Upload documents in the chat to ask questions about them.}"
DEMO_SPACE_GREETING="${DEMO_SPACE_GREETING:-How can I help you?}"
# Space names created by node-chat when a company is bootstrapped. These are the
# spaces the demo replaces; see createDefaultAssistants in node-chat.
DEFAULT_SPACE_NAMES="${DEFAULT_SPACE_NAMES:-Internal Knowledge,GPT-4o}"

HEALTH_TIMEOUT_SECONDS="${DEMO_HEALTH_TIMEOUT_SECONDS:-300}"
POLL_SECONDS="${DEMO_POLL_SECONDS:-5}"
ZITADEL_INSECURE_SKIP_VERIFY_TLS="${ZITADEL_INSECURE_SKIP_VERIFY_TLS:-false}"

MODE=apply
KEEP_DEFAULT_SPACES=0
SKIP_THEME=0
SKIP_USER=0
SKIP_SPACES=0

usage() {
  cat <<'USAGE'
Usage: ./setup-demo.sh [--check] [--keep-default-spaces]
                       [--skip-theme] [--skip-user] [--skip-spaces]

Configures the HPE demo on a deployed hosted trial:

  1. reconciles the HPE theme (colors, logos, favicon, tab name);
  2. creates the demo human user and grants it project roles;
  3. creates one chat space backed by the LiteLLM GLM model, makes it the
     company default, grants the Root Group access, and removes the two
     spaces node-chat creates on company bootstrap.

All steps are idempotent. --check reports the intended changes and creates,
updates or deletes nothing, with one exception: reading the theme and the
spaces needs an application token, so a machine key is minted and revoked
again before the script exits.

Authentication:
  The ZITADEL admin token is resolved exactly as in setup-zitadel.sh:
  ZITADEL_ACCESS_TOKEN / ZITADEL_PAT, then ZITADEL_ACCESS_TOKEN_FILE (mode
  0400/0600), then Secret unique/iam-admin-pat. Application APIs are called
  with a short-lived JWT minted for the SETUP_MACHINE_USERNAME machine user,
  which this script creates on first run. No token is printed or written to a
  tracked file.

Options:
  --check                 Report the required changes without applying them.
  --keep-default-spaces   Leave the bootstrap spaces in place.
  --skip-theme            Do not touch the theme.
  --skip-user             Do not create or update the demo user.
  --skip-spaces           Do not touch spaces.

Main environment overrides:
  DEMO_USER_EMAIL         Default: demo@unique.ai
  DEMO_USER_PASSWORD      Required to create the user; ignored once it exists.
  DEMO_USER_PASSWORD_FILE Owner-only file holding the password.
  DEMO_USER_ROLES         Comma-separated project roles for the demo user.
  DEMO_SPACE_NAME         Default: HPE AI Assistant
  DEMO_SPACE_MODEL        Default: litellm:unique-chat-glm-5.3
  DEFAULT_SPACE_NAMES     Bootstrap spaces to remove.
  THEME_TAB_NAME          Browser tab / product name. Default: HPE AI
  ZITADEL_URL             Override the derived identity-provider URL.
  UNIQUE_API_BASE_URL     Override the derived API URL.
USAGE
}

die() {
  printf 'ERROR: %s\n' "$1" >&2
  exit 1
}

warn() {
  printf 'WARNING: %s\n' "$1" >&2
}

note() {
  printf '%s\n' "$1"
}

require_command() {
  command -v "$1" >/dev/null 2>&1 || die "missing required command: $1"
}

while (($# > 0)); do
  case "$1" in
    --check) MODE=check ;;
    --keep-default-spaces) KEEP_DEFAULT_SPACES=1 ;;
    --skip-theme) SKIP_THEME=1 ;;
    --skip-user) SKIP_USER=1 ;;
    --skip-spaces) SKIP_SPACES=1 ;;
    --help|-h) usage; exit 0 ;;
    *) usage >&2; die "unknown option: $1" ;;
  esac
  shift
done

for command in base64 curl jq kubectl openssl yq; do
  require_command "${command}"
done

base64_decode() {
  if base64 --decode </dev/null >/dev/null 2>&1; then
    base64 --decode
  else
    base64 -D
  fi
}

base64_encode() {
  openssl base64 -A
}

base64url() {
  openssl base64 -A | tr '+/' '-_' | tr -d '='
}

check_file_permissions() {
  local file="$1"
  local mode
  [[ -f "${file}" ]] || die "file does not exist: ${file}"
  [[ ! -L "${file}" ]] || die "file must not be a symlink: ${file}"
  [[ -r "${file}" ]] || die "file is not readable: ${file}"
  mode="$(stat -f '%Lp' "${file}" 2>/dev/null || true)"
  if [[ ! "${mode}" =~ ^[0-7]{3,4}$ ]]; then
    mode="$(stat -c '%a' "${file}" 2>/dev/null || true)"
  fi
  [[ "${mode}" =~ ^[0-7]{3,4}$ ]] || die "cannot inspect permissions: ${file}"
  mode="${mode: -3}"
  [[ "${mode}" == 400 || "${mode}" == 600 ]] \
    || die "file must be owner-only (mode 400/600): ${file}"
}

# ── URLs ─────────────────────────────────────────────────────────────────────
# The configured Harbor hostname is the repository's deployment-domain source,
# matching setup-zitadel.sh.
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
UNIQUE_API_BASE_URL="${UNIQUE_API_BASE_URL:-${DEFAULT_SCHEME}://api.${CONFIGURED_DOMAIN}}"
ZITADEL_URL="${ZITADEL_URL%/}"
UNIQUE_API_BASE_URL="${UNIQUE_API_BASE_URL%/}"
[[ "${ZITADEL_URL}" =~ ^https?://[^/]+$ ]] \
  || die "ZITADEL_URL must be an http(s) origin without a path: ${ZITADEL_URL}"
[[ "${UNIQUE_API_BASE_URL}" =~ ^https?://[^/]+$ ]] \
  || die "UNIQUE_API_BASE_URL must be an http(s) origin without a path"

CHAT_GRAPHQL_URL="${CHAT_GRAPHQL_URL:-${UNIQUE_API_BASE_URL}/chat/graphql}"
SCOPE_GRAPHQL_URL="${SCOPE_GRAPHQL_URL:-${UNIQUE_API_BASE_URL}/scope-management/graphql}"
# The chart default for configuration-backend; shared Unique prod uses /theme.
THEME_GRAPHQL_URL="${THEME_GRAPHQL_URL:-${UNIQUE_API_BASE_URL}/configuration/graphql}"

curl_args=(--silent --show-error --max-time 60)
if [[ "${ZITADEL_INSECURE_SKIP_VERIFY_TLS}" == true ]]; then
  warn "TLS verification is disabled for identity-provider requests"
  curl_args+=(-k)
fi

WORK_DIR="$(mktemp -d "${TMPDIR:-/tmp}/unique-demo.XXXXXX")"
chmod 700 "${WORK_DIR}"
cleanup() { rm -rf "${WORK_DIR}"; }
trap cleanup EXIT

ZITADEL_HEADER_FILE="${WORK_DIR}/zitadel-headers"
APP_HEADER_FILE="${WORK_DIR}/app-headers"

# ── ZITADEL admin token ──────────────────────────────────────────────────────
read_admin_token() {
  local encoded="" token="" deadline

  if [[ -n "${ZITADEL_ACCESS_TOKEN:-}" && -n "${ZITADEL_PAT:-}" &&
    "${ZITADEL_ACCESS_TOKEN}" != "${ZITADEL_PAT}" ]]; then
    die "ZITADEL_ACCESS_TOKEN and ZITADEL_PAT disagree; set only one"
  fi

  if [[ -n "${ZITADEL_ACCESS_TOKEN:-}" ]]; then
    token="${ZITADEL_ACCESS_TOKEN}"
  elif [[ -n "${ZITADEL_PAT:-}" ]]; then
    token="${ZITADEL_PAT}"
  elif [[ -n "${ZITADEL_ACCESS_TOKEN_FILE:-}" ]]; then
    check_file_permissions "${ZITADEL_ACCESS_TOKEN_FILE}"
    token="$(<"${ZITADEL_ACCESS_TOKEN_FILE}")"
  else
    deadline=$(( $(date +%s) + HEALTH_TIMEOUT_SECONDS ))
    note "Reading Secret unique/iam-admin-pat ..."
    while (( $(date +%s) < deadline )); do
      encoded="$(kubectl --namespace unique get secret iam-admin-pat \
        -o jsonpath='{.data.pat}' 2>/dev/null || true)"
      [[ -z "${encoded}" ]] || break
      sleep "${POLL_SECONDS}"
    done
    [[ -n "${encoded}" ]] \
      || die "Secret unique/iam-admin-pat is unavailable; set ZITADEL_ACCESS_TOKEN or ZITADEL_ACCESS_TOKEN_FILE"
    token="$(printf '%s' "${encoded}" | base64_decode)"
  fi

  [[ -n "${token}" ]] || die "the ZITADEL access token is empty"
  [[ "${token}" != *[[:space:]]* ]] || die "the ZITADEL access token contains whitespace"

  ( umask 077; printf 'Content-Type: application/json\nAuthorization: Bearer %s\n' \
    "${token}" >"${ZITADEL_HEADER_FILE}" )
}

zitadel_api() {
  local method="$1" path="$2" body="${3:-}" org="${4:-}"
  local -a args=("${curl_args[@]}" --request "${method}"
    --header "@${ZITADEL_HEADER_FILE}")
  [[ -z "${org}" ]] || args+=(--header "x-zitadel-orgid: ${org}")
  [[ -z "${body}" ]] || args+=(--data-binary "${body}")
  curl "${args[@]}" "${ZITADEL_URL}${path}"
}

assert_no_zitadel_error() {
  local response="$1" context="$2"
  if [[ "$(jq -r 'if type == "object" then (has("code") and has("message")) else false end' <<<"${response}")" == true ]]; then
    die "${context}: $(jq -r '.message' <<<"${response}")"
  fi
}

wait_for_zitadel() {
  local deadline=$(( $(date +%s) + HEALTH_TIMEOUT_SECONDS ))
  note "Waiting for ZITADEL health at ${ZITADEL_URL}/debug/ready ..."
  while (( $(date +%s) < deadline )); do
    if curl "${curl_args[@]}" --fail -o /dev/null "${ZITADEL_URL}/debug/ready"; then
      return 0
    fi
    sleep "${POLL_SECONDS}"
  done
  die "ZITADEL did not become ready within ${HEALTH_TIMEOUT_SECONDS}s"
}

# ── Identity object discovery ────────────────────────────────────────────────
terraform_output() {
  local name="$1"
  command -v terraform >/dev/null 2>&1 || return 1
  [[ -f "${STATE_DIR}/terraform.tfstate" ]] || return 1
  TF_DATA_DIR="${STATE_DIR}/tfdata" terraform -chdir="${TERRAFORM_DIR}" \
    output -raw "${name}" 2>/dev/null || return 1
}

discover_identity_objects() {
  local response

  PROJECT_ID="${ZITADEL_PROJECT_ID:-$(terraform_output project_id || true)}"
  if [[ -z "${PROJECT_ID}" ]]; then
    # jwt-auth is the deployment's own record of the project the tokens target.
    PROJECT_ID="$(yq -r '.config.zitadel_project_id // ""' \
      "${REPOSITORY_DIR}/2-applications/0-kong-config/jwt-auth.kong-cluster-plugin.yaml" 2>/dev/null || true)"
  fi
  [[ -n "${PROJECT_ID}" && "${PROJECT_ID}" != null ]] \
    || die "cannot determine the ZITADEL project id; set ZITADEL_PROJECT_ID"

  ROOT_ORG_ID="${ZITADEL_ROOT_ORG_ID:-$(terraform_output root_org_id || true)}"
  TARGET_ORG_ID="${ZITADEL_TARGET_ORG_ID:-$(terraform_output target_org_id || true)}"

  if [[ -z "${ROOT_ORG_ID}" || -z "${TARGET_ORG_ID}" ]]; then
    # The project grant identifies both orgs: its owner and its grantee.
    response="$(zitadel_api POST "/management/v1/projects/${PROJECT_ID}/grants/_search" '{}' "${ROOT_ORG_ID}")"
    assert_no_zitadel_error "${response}" "cannot search project grants"
    [[ "$(jq '.result | length' <<<"${response}")" == 1 ]] \
      || die "expected exactly one project grant for ${PROJECT_ID}; set ZITADEL_TARGET_ORG_ID"
    TARGET_ORG_ID="${TARGET_ORG_ID:-$(jq -r '.result[0].grantedOrgId' <<<"${response}")}"
    ROOT_ORG_ID="${ROOT_ORG_ID:-$(jq -r '.result[0].details.resourceOwner' <<<"${response}")}"
  fi

  response="$(zitadel_api POST "/management/v1/projects/${PROJECT_ID}/grants/_search" '{}' "${ROOT_ORG_ID}")"
  assert_no_zitadel_error "${response}" "cannot search project grants"
  PROJECT_GRANT_ID="$(jq -r --arg org "${TARGET_ORG_ID}" \
    'first(.result[] | select(.grantedOrgId == $org) | .grantId) // ""' <<<"${response}")"
  [[ -n "${PROJECT_GRANT_ID}" ]] \
    || die "organization ${TARGET_ORG_ID} holds no grant on project ${PROJECT_ID}"

  note "Project ${PROJECT_ID}, target organization ${TARGET_ORG_ID}, grant ${PROJECT_GRANT_ID}."
}

find_user_by_login_name() {
  local login_name="$1" response
  response="$(zitadel_api POST /v2/users "$(jq -cn --arg login "${login_name}" \
    '{query:{limit:2},queries:[{loginNameQuery:{loginName:$login}}]}')")"
  assert_no_zitadel_error "${response}" "cannot search users"
  local count
  count="$(jq '(.result // []) | length' <<<"${response}")"
  (( count <= 1 )) || die "multiple users match login name ${login_name}"
  jq -r '(.result // [])[0].userId // ""' <<<"${response}"
}

grant_project_roles() {
  local user_id="$1" roles_csv="$2" label="$3" response existing grant_id roles_json
  roles_json="$(jq -cn --arg csv "${roles_csv}" \
    '$csv | split(",") | map(gsub("^\\s+|\\s+$";"")) | map(select(length > 0))')"

  response="$(zitadel_api POST /management/v1/users/grants/_search \
    "$(jq -cn --arg uid "${user_id}" \
      '{queries:[{userIdQuery:{userId:$uid}}]}')" "${TARGET_ORG_ID}")"
  assert_no_zitadel_error "${response}" "cannot search user grants for ${label}"
  existing="$(jq -r --arg proj "${PROJECT_ID}" \
    'first(.result[]? | select(.projectId == $proj)) // empty' <<<"${response}")"

  if [[ -z "${existing}" ]]; then
    if [[ "${MODE}" == check ]]; then
      note "would grant roles to ${label}: ${roles_csv}"
      return 0
    fi
    response="$(zitadel_api POST "/management/v1/users/${user_id}/grants" \
      "$(jq -cn --arg proj "${PROJECT_ID}" --arg grant "${PROJECT_GRANT_ID}" \
        --argjson roles "${roles_json}" \
        '{projectId:$proj,projectGrantId:$grant,roleKeys:$roles}')" "${TARGET_ORG_ID}")"
    assert_no_zitadel_error "${response}" "cannot grant roles to ${label}"
    note "Granted project roles to ${label}."
    return 0
  fi

  local missing
  missing="$(jq -r --argjson want "${roles_json}" \
    '(.roleKeys // []) as $have | [$want[] | select(($have | index(.)) == null)] | join(",")' \
    <<<"${existing}")"
  if [[ -z "${missing}" ]]; then
    note "Project roles for ${label} are already granted."
    return 0
  fi
  if [[ "${MODE}" == check ]]; then
    note "would add missing roles to ${label}: ${missing}"
    return 0
  fi
  grant_id="$(jq -r '.id' <<<"${existing}")"
  # Send the union so roles granted outside this script are not revoked.
  response="$(zitadel_api PUT "/management/v1/users/${user_id}/grants/${grant_id}" \
    "$(jq -cn --argjson want "${roles_json}" \
      --argjson have "$(jq -c '.roleKeys // []' <<<"${existing}")" \
      '{roleKeys:(($have + $want) | unique)}')" "${TARGET_ORG_ID}")"
  assert_no_zitadel_error "${response}" "cannot update roles for ${label}"
  note "Updated project roles for ${label} (added ${missing})."
}

# ── Demo human user ──────────────────────────────────────────────────────────
read_demo_password() {
  if [[ -n "${DEMO_USER_PASSWORD_FILE:-}" ]]; then
    check_file_permissions "${DEMO_USER_PASSWORD_FILE}"
    DEMO_USER_PASSWORD="$(<"${DEMO_USER_PASSWORD_FILE}")"
  fi
  [[ -n "${DEMO_USER_PASSWORD:-}" ]] \
    || die "DEMO_USER_PASSWORD or DEMO_USER_PASSWORD_FILE is required to create ${DEMO_USER_EMAIL}"
  [[ "${DEMO_USER_PASSWORD}" != *[[:space:]]* ]] \
    || die "DEMO_USER_PASSWORD must not contain whitespace"
}

ensure_demo_user() {
  local user_id response payload
  user_id="$(find_user_by_login_name "${DEMO_USER_EMAIL}")"

  if [[ -n "${user_id}" ]]; then
    note "Demo user ${DEMO_USER_EMAIL} already exists (${user_id})."
  else
    if [[ "${MODE}" == check ]]; then
      note "would create demo user ${DEMO_USER_EMAIL} in organization ${TARGET_ORG_ID}"
      return 0
    fi
    read_demo_password
    payload="$(jq -cn \
      --arg email "${DEMO_USER_EMAIL}" --arg org "${TARGET_ORG_ID}" \
      --arg given "${DEMO_USER_GIVEN_NAME}" --arg family "${DEMO_USER_FAMILY_NAME}" \
      --arg password "${DEMO_USER_PASSWORD}" \
      '{username:$email,
        organization:{orgId:$org},
        profile:{givenName:$given,familyName:$family,displayName:($given+" "+$family),preferredLanguage:"en"},
        email:{email:$email,isVerified:true},
        password:{password:$password,changeRequired:false}}')"
    response="$(zitadel_api POST /v2/users/human "${payload}")"
    assert_no_zitadel_error "${response}" "cannot create ${DEMO_USER_EMAIL}"
    user_id="$(jq -r '.userId // ""' <<<"${response}")"
    [[ -n "${user_id}" ]] || die "ZITADEL did not return a user id for ${DEMO_USER_EMAIL}"
    note "Created demo user ${DEMO_USER_EMAIL} (${user_id})."
  fi

  [[ -z "${user_id}" ]] || grant_project_roles "${user_id}" "${DEMO_USER_ROLES}" "${DEMO_USER_EMAIL}"
}

# ── Setup machine user and application token ─────────────────────────────────
ensure_setup_machine_user() {
  local response
  SETUP_USER_ID="$(find_user_by_login_name "${SETUP_MACHINE_USERNAME}@${TARGET_ORG_DOMAIN}")"
  if [[ -z "${SETUP_USER_ID}" ]]; then
    SETUP_USER_ID="$(find_user_by_login_name "${SETUP_MACHINE_USERNAME}")"
  fi

  if [[ -n "${SETUP_USER_ID}" ]]; then
    note "Setup machine user ${SETUP_MACHINE_USERNAME} already exists (${SETUP_USER_ID})."
  elif [[ "${MODE}" == check ]]; then
    note "would create setup machine user ${SETUP_MACHINE_USERNAME}"
    return 0
  else
    response="$(zitadel_api POST /management/v1/users/machine \
      "$(jq -cn --arg name "${SETUP_MACHINE_USERNAME}" \
        '{userName:$name,name:"HPE Trial Setup",
          description:"Automation user for setup-demo.sh (theme, spaces, users)",
          accessTokenType:"ACCESS_TOKEN_TYPE_JWT"}')" "${TARGET_ORG_ID}")"
    assert_no_zitadel_error "${response}" "cannot create ${SETUP_MACHINE_USERNAME}"
    SETUP_USER_ID="$(jq -r '.userId // ""' <<<"${response}")"
    [[ -n "${SETUP_USER_ID}" ]] || die "ZITADEL did not return a user id for ${SETUP_MACHINE_USERNAME}"
    note "Created setup machine user ${SETUP_MACHINE_USERNAME} (${SETUP_USER_ID})."
  fi

  grant_project_roles "${SETUP_USER_ID}" "${SETUP_MACHINE_ROLES}" "${SETUP_MACHINE_USERNAME}"
}

# Mints a fresh private key, exchanges it for an access token, then deletes the
# key again so no long-lived application credential is left behind.
mint_app_token() {
  local response key_file key_id now exp header payload signature assertion scope pem

  response="$(zitadel_api POST "/management/v1/users/${SETUP_USER_ID}/keys" \
    '{"type":"KEY_TYPE_JSON"}' "${TARGET_ORG_ID}")"
  assert_no_zitadel_error "${response}" "cannot create a key for ${SETUP_MACHINE_USERNAME}"
  key_file="${WORK_DIR}/setup-user.key.json"
  ( umask 077; jq -r '.keyDetails' <<<"${response}" | base64_decode >"${key_file}" )
  key_id="$(jq -r '.keyId' "${key_file}")"
  [[ -n "${key_id}" && "${key_id}" != null ]] || die "the machine key response is unusable"
  SETUP_KEY_ID="${key_id}"

  now="$(date +%s)"
  exp=$(( now + 300 ))
  header="$(jq -cn --arg kid "${key_id}" '{alg:"RS256",kid:$kid}' | base64url)"
  payload="$(jq -cn --arg iss "${SETUP_USER_ID}" --arg sub "${SETUP_USER_ID}" \
    --arg aud "${ZITADEL_URL}" --argjson iat "${now}" --argjson exp "${exp}" \
    '{iss:$iss,sub:$sub,aud:$aud,iat:$iat,exp:$exp}' | base64url)"
  pem="${WORK_DIR}/setup-user.pem"
  ( umask 077; jq -r '.key' "${key_file}" >"${pem}" )
  signature="$(printf '%s.%s' "${header}" "${payload}" \
    | openssl dgst -sha256 -sign "${pem}" -binary | base64url)"
  assertion="${header}.${payload}.${signature}"

  # resourceowner is required: the Kong plugin maps that claim to x-company-id,
  # which the Unique services use as the tenant key.
  scope="openid urn:zitadel:iam:org:project:id:${PROJECT_ID}:aud"
  scope+=" urn:zitadel:iam:org:projects:roles urn:zitadel:iam:user:resourceowner"
  response="$(curl "${curl_args[@]}" --request POST "${ZITADEL_URL}/oauth/v2/token" \
    --data-urlencode 'grant_type=urn:ietf:params:oauth:grant-type:jwt-bearer' \
    --data-urlencode "assertion=${assertion}" \
    --data-urlencode "scope=${scope}")"
  local access_token
  access_token="$(jq -r '.access_token // ""' <<<"${response}")"
  [[ -n "${access_token}" ]] \
    || die "token exchange failed: $(jq -r '.error_description // .error // "unknown error"' <<<"${response}")"

  ( umask 077; printf 'Content-Type: application/json\nAuthorization: Bearer %s\n' \
    "${access_token}" >"${APP_HEADER_FILE}" )
  rm -f "${key_file}" "${pem}"
}

revoke_app_key() {
  [[ -n "${SETUP_KEY_ID:-}" && -n "${SETUP_USER_ID:-}" ]] || return 0
  zitadel_api DELETE "/management/v1/users/${SETUP_USER_ID}/keys/${SETUP_KEY_ID}" \
    '' "${TARGET_ORG_ID}" >/dev/null 2>&1 || warn "could not delete the temporary machine key ${SETUP_KEY_ID}"
  SETUP_KEY_ID=""
}

# ── GraphQL ──────────────────────────────────────────────────────────────────
graphql() {
  local url="$1" payload="$2" response
  response="$(curl "${curl_args[@]}" --header "@${APP_HEADER_FILE}" \
    --data-binary "${payload}" "${url}")" || die "GraphQL request failed at ${url}"
  if [[ "$(jq -r 'has("errors")' <<<"${response}" 2>/dev/null)" == true ]]; then
    jq -r '.errors[] | "  - " + .message' <<<"${response}" >&2
    die "GraphQL returned an error at ${url}"
  fi
  [[ "$(jq -r 'has("data")' <<<"${response}" 2>/dev/null)" == true ]] \
    || die "unexpected response from ${url}: ${response:0:200}"
  printf '%s' "${response}"
}

graphql_request() {
  local url="$1" query="$2" variables="${3:-}"
  [[ -n "${variables}" ]] || variables='{}'
  graphql "${url}" "$(jq -cn --arg query "${query}" --argjson variables "${variables}" \
    '{query:$query,variables:$variables}')"
}

# ── Theme ────────────────────────────────────────────────────────────────────
# HPE brand palette mapped onto Unique's 29 semantic theme colors. The
# color-on-* entries are foregrounds and must stay legible on their pair.
theme_colors_json() {
  cat <<'JSON'
{
  "color-primary-cta": "#01A982",
  "color-primary-variant": "#008567",
  "color-secondary": "#425563",
  "color-secondary-variant": "#2E3B44",
  "color-background": "#F7F7F7",
  "color-background-variant": "#EBEBEB",
  "color-surface": "#FFFFFF",
  "color-control": "#C6C9CA",
  "color-info": "#00739D",
  "color-success-light": "#17EBA0",
  "color-success-dark": "#008567",
  "color-error-light": "#FC6161",
  "color-error-dark": "#C54E4B",
  "color-attention": "#FEC901",
  "color-attention-variant": "#7630EA",
  "color-on-primary": "#FFFFFF",
  "color-on-secondary": "#FFFFFF",
  "color-on-background-main": "#444444",
  "color-on-background-dimmed": "#757575",
  "color-on-surface": "#444444",
  "color-on-control-main": "#444444",
  "color-on-control-dimmed": "#ADADAD",
  "color-on-info": "#FFFFFF",
  "color-on-success-light": "#444444",
  "color-on-success-dark": "#FFFFFF",
  "color-on-error-light": "#FFFFFF",
  "color-on-error-dark": "#FFFFFF",
  "color-on-attention": "#444444",
  "color-on-attention-variant": "#FFFFFF"
}
JSON
}

data_uri() {
  local file="$1" mime="$2"
  [[ -f "${file}" ]] || die "missing theme asset: ${file}"
  printf 'data:%s;base64,%s' "${mime}" "$(base64_encode <"${file}")"
}

theme_scalars_json() {
  jq -cn \
    --arg tabName "${THEME_TAB_NAME}" \
    --arg supportEmail "${THEME_SUPPORT_EMAIL}" \
    --arg logoNavbar "$(data_uri "${ASSET_DIR}/hpe-logo-navbar.png" image/png)" \
    --arg logoHeader "$(data_uri "${ASSET_DIR}/hpe-logo-header.png" image/png)" \
    --arg favicon "$(data_uri "${ASSET_DIR}/hpe-favicon.png" image/png)" \
    '{tabName:$tabName,supportEmail:$supportEmail,
      logoNavbar:$logoNavbar,logoHeader:$logoHeader,favicon:$favicon,
      settings:{logoNavbarAlignment:"mr-auto justify-start",hideSupportEmail:false}}'
}

configure_theme() {
  local query response theme_id colors payload scalars

  query='query Theme { theme { id tabName colors { id name hexValue } } }'
  response="$(graphql_request "${THEME_GRAPHQL_URL}" "${query}")"
  theme_id="$(jq -r '.data.theme.id // ""' <<<"${response}")"
  colors="$(theme_colors_json)"

  if [[ -z "${theme_id}" ]]; then
    if [[ "${MODE}" == check ]]; then
      note "would create the HPE theme (${THEME_TAB_NAME}, 29 colors, logos, favicon)"
      return 0
    fi
    scalars="$(theme_scalars_json)"
    payload="$(jq -cn \
      --arg query 'mutation ThemeCreate($input: ThemeCreateInput!) { createTheme(input: $input) { id } }' \
      --argjson scalars "${scalars}" --argjson colors "${colors}" \
      '{query:$query,variables:{input:($scalars + {
          colors:{create:($colors | to_entries | map({name:.key,hexValue:.value}))},
          fontFamilies:{create:[{name:"Inter",family:"sans-serif"}]}
        })}}')"
    response="$(graphql "${THEME_GRAPHQL_URL}" "${payload}")"
    theme_id="$(jq -r '.data.createTheme.id' <<<"${response}")"
    note "Created theme ${theme_id} for the company."
    return 0
  fi

  if [[ "${MODE}" == check ]]; then
    note "would update theme ${theme_id} to the HPE palette and assets"
    return 0
  fi

  # Colors are rows with their own ids: update the ones that exist by name and
  # create the rest, so re-runs neither duplicate nor orphan them.
  scalars="$(theme_scalars_json)"
  payload="$(jq -cn \
    --arg query 'mutation ThemeUpdate($themeId: String!, $input: ThemeUpdateInput!) { updateTheme(themeId: $themeId, input: $input) { id } }' \
    --arg themeId "${theme_id}" \
    --argjson scalars "${scalars}" \
    --argjson colors "${colors}" \
    --argjson existing "$(jq '[.data.theme.colors[]? | {name, id}]' <<<"${response}")" \
    '($existing | map({(.name): .id}) | add // {}) as $byName
     | ($colors | to_entries) as $wanted
     | {query:$query,variables:{themeId:$themeId,input:($scalars + {
         colors: (
           {
             update: [$wanted[] | select($byName[.key] != null)
               | {where:{id:$byName[.key]}, data:{hexValue:.value}}],
             create: [$wanted[] | select($byName[.key] == null)
               | {name:.key, hexValue:.value}]
           }
           | with_entries(select(.value | length > 0))
         )
       })}}')"
  graphql "${THEME_GRAPHQL_URL}" "${payload}" >/dev/null
  note "Updated theme ${theme_id} to the HPE palette and assets."
}

# ── Spaces ───────────────────────────────────────────────────────────────────
root_group_id() {
  local response
  response="$(graphql_request "${SCOPE_GRAPHQL_URL}" \
    'query AllGroups($where: GroupWhereInput) { allGroups(where: $where) { id name } }' \
    '{"where":{"name":{"equals":"Root Group"}}}')"
  jq -r 'first(.data.allGroups[]? | select(.name == "Root Group") | .id) // ""' <<<"${response}"
}

unique_ai_module_template_id() {
  local response
  response="$(graphql_request "${CHAT_GRAPHQL_URL}" \
    'query ModuleTemplates { moduleTemplates { id templateName name } }')"
  jq -r 'first(.data.moduleTemplates[]? | select(.name == "UniqueAi") | .id) // ""' <<<"${response}"
}

configure_spaces() {
  local response spaces space_id group_id template_id payload

  response="$(graphql_request "${CHAT_GRAPHQL_URL}" \
    'query AllAssistants { allAssistants { id name defaultForCompanyId } }')"
  spaces="$(jq -c '.data.allAssistants' <<<"${response}")"
  space_id="$(jq -r --arg name "${DEMO_SPACE_NAME}" \
    'first(.[] | select(.name == $name) | .id) // ""' <<<"${spaces}")"

  if [[ -n "${space_id}" ]]; then
    note "Space ${DEMO_SPACE_NAME} already exists (${space_id})."
  elif [[ "${MODE}" == check ]]; then
    note "would create space ${DEMO_SPACE_NAME} using ${DEMO_SPACE_MODEL}"
  else
    group_id="$(root_group_id)"
    [[ -n "${group_id}" ]] || die "cannot find the company Root Group in scope-management"
    template_id="$(unique_ai_module_template_id)"
    [[ -n "${template_id}" ]] || die "cannot find the UniqueAi module template in node-chat"

    payload="$(jq -cn \
      --arg query 'mutation CreateAssistant($input: AssistantCreateInput!, $assistantAccessCreateInput: [AssistantAccessCreateDto!]) { createAssistant(input: $input, assistantAccessCreateInput: $assistantAccessCreateInput) { id name } }' \
      --arg name "${DEMO_SPACE_NAME}" \
      --arg explanation "${DEMO_SPACE_DESCRIPTION}" \
      --arg greeting "${DEMO_SPACE_GREETING}" \
      --arg model "${DEMO_SPACE_MODEL}" \
      --arg template "${template_id}" \
      --arg group "${group_id}" \
      '{query:$query,variables:{
          input:{
            name:$name, title:$greeting, explanation:$explanation,
            fallbackModule:"UniqueAi", chatUpload:"ENABLED", uiType:"UNIQUE_AI",
            isPinned:true, access:[],
            settings:{allowUserMemory:false,imageUpload:true,
                      showPdfHighlighting:true,deviceAvailability:"ALL_DEVICES"},
            modules:{create:[{
              name:"UniqueAi", weight:500, isExternal:false, toolDefinition:{},
              configuration:{languageModel:$model, tools:[]},
              moduleTemplate:{connect:{id:$template}}
            }]}
          },
          assistantAccessCreateInput:[
            {entityId:$group, entityType:"GROUP", type:"USE"},
            {entityId:$group, entityType:"GROUP", type:"UPLOAD"}
          ]}}')"
    response="$(graphql "${CHAT_GRAPHQL_URL}" "${payload}")"
    space_id="$(jq -r '.data.createAssistant.id' <<<"${response}")"
    note "Created space ${DEMO_SPACE_NAME} (${space_id}) using ${DEMO_SPACE_MODEL}."
  fi

  # The company default must move off a bootstrap space before it can be
  # deleted, otherwise the company is left without a default space.
  if [[ -n "${space_id}" ]]; then
    local current_default
    current_default="$(jq -r 'first(.[] | select(.defaultForCompanyId != null) | .id) // ""' <<<"${spaces}")"
    if [[ "${current_default}" == "${space_id}" ]]; then
      note "Space ${DEMO_SPACE_NAME} is already the company default."
    elif [[ "${MODE}" == check ]]; then
      note "would make ${DEMO_SPACE_NAME} the company default space"
    else
      graphql_request "${CHAT_GRAPHQL_URL}" \
        'mutation SetDefault($id: String!) { updateDefaultAssistant(newDefaultAssistantId: $id) { id } }' \
        "$(jq -cn --arg id "${space_id}" '{id:$id}')" >/dev/null
      note "Made ${DEMO_SPACE_NAME} the company default space."
    fi
  fi

  if (( KEEP_DEFAULT_SPACES == 1 )); then
    note "Keeping the bootstrap spaces as requested."
    return 0
  fi

  local names_json
  names_json="$(jq -cn --arg csv "${DEFAULT_SPACE_NAMES}" \
    '$csv | split(",") | map(gsub("^\\s+|\\s+$";"")) | map(select(length > 0))')"

  local remove_id remove_name
  while IFS=$'\t' read -r remove_id remove_name; do
    [[ -n "${remove_id}" ]] || continue
    if [[ "${remove_id}" == "${space_id}" ]]; then
      warn "refusing to delete ${remove_name}: it is the demo space"
      continue
    fi
    if [[ "${MODE}" == check ]]; then
      note "would delete bootstrap space ${remove_name} (${remove_id})"
      continue
    fi
    graphql_request "${CHAT_GRAPHQL_URL}" \
      'mutation DeleteAssistant($id: String!) { deleteAssistant(id: $id) { id } }' \
      "$(jq -cn --arg id "${remove_id}" '{id:$id}')" >/dev/null
    note "Deleted bootstrap space ${remove_name} (${remove_id})."
  done < <(jq -r --argjson names "${names_json}" \
    '.[] | select(.name as $n | $names | index($n)) | [.id, .name] | @tsv' <<<"${spaces}")
}

# ── Run ──────────────────────────────────────────────────────────────────────
note "Deployment domain ${CONFIGURED_DOMAIN} (${MODE} mode)."
read_admin_token
wait_for_zitadel
discover_identity_objects

TARGET_ORG_DOMAIN=""
org_response="$(zitadel_api GET "/management/v1/orgs/me" '' "${TARGET_ORG_ID}")"
TARGET_ORG_DOMAIN="$(jq -r '.org.primaryDomain // ""' <<<"${org_response}")"

if (( SKIP_USER == 0 )); then
  ensure_demo_user
else
  note "Skipping the demo user."
fi

if (( SKIP_THEME == 1 && SKIP_SPACES == 1 )); then
  note "Nothing further to do."
  exit 0
fi

ensure_setup_machine_user
if [[ "${MODE}" == check && -z "${SETUP_USER_ID:-}" ]]; then
  note "Cannot inspect the theme or spaces before the setup machine user exists."
  exit 0
fi

mint_app_token
trap 'revoke_app_key; cleanup' EXIT

if (( SKIP_THEME == 0 )); then
  configure_theme
else
  note "Skipping the theme."
fi

if (( SKIP_SPACES == 0 )); then
  configure_spaces
else
  note "Skipping spaces."
fi

revoke_app_key

if [[ "${MODE}" == check ]]; then
  note "Check completed; nothing was changed."
else
  note "Demo configuration completed."
  note "Sign in at ${DEFAULT_SCHEME}://unique.${CONFIGURED_DOMAIN}/chat as ${DEMO_USER_EMAIL}."
fi
