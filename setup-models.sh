#!/usr/bin/env bash
set -euo pipefail

REPOSITORY_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
CHAT_MODEL_ALIAS="${CHAT_MODEL_ALIAS:-unique-chat-glm-5.3}"
CHAT_MODEL_GROUP="${CHAT_MODEL_GROUP:-TOGETHER_GLM_5_3}"
EMBEDDING_MODEL_ALIAS="${EMBEDDING_MODEL_ALIAS:-unique-embedding-e5}"
EMBEDDING_DIMENSION="${EMBEDDING_DIMENSION:-1024}"
CONFIGURED_DOMAIN=localhost
if [[ -f "${REPOSITORY_DIR}/.hostname" ]]; then
  CONFIGURED_DOMAIN="$(tr -d '[:space:]' <"${REPOSITORY_DIR}/.hostname")"
fi
[[ -n "${CONFIGURED_DOMAIN}" ]] || { printf 'ERROR: .hostname is empty; run ./set-hostname.sh first\n' >&2; exit 1; }
DEFAULT_SCHEME=https
[[ "${CONFIGURED_DOMAIN}" == localhost ]] && DEFAULT_SCHEME=http
UNIQUE_API_BASE_URL="${UNIQUE_API_BASE_URL:-${DEFAULT_SCHEME}://api.${CONFIGURED_DOMAIN}}"
CHAT_GRAPHQL_URL="${CHAT_GRAPHQL_URL:-${UNIQUE_API_BASE_URL}/chat/graphql}"
INGESTION_GRAPHQL_URL="${INGESTION_GRAPHQL_URL:-${UNIQUE_API_BASE_URL}/ingestion/graphql}"
ZITADEL_URL="${ZITADEL_URL:-${UNIQUE_API_BASE_URL/api./id.}}"
SETUP_MACHINE_USERNAME="${SETUP_MACHINE_USERNAME:-hpe-trial-setup}"
TERRAFORM_STATE="${REPOSITORY_DIR}/.local/zitadel-bootstrap/terraform.tfstate"
MODE=apply
UPDATE_ASSISTANTS=false
REEMBED=false

usage() {
  cat <<'USAGE'
Usage: ./setup-models.sh [--check] [--update-assistants] [--reembed]

Registers the Together GLM model with Unique, selects the Together E5 embedding
model for the token's company, and optionally updates all company assistants.

Authentication:
  By default, the script reads the existing ZITADEL admin PAT from Secret
  unique/iam-admin-pat, creates or reuses the hpe-trial-setup machine user,
  and uses a short-lived JWT whose temporary key is revoked on exit.

Optional:
  UNIQUE_ACCESS_TOKEN_FILE   Mode-0400/0600 user token file. When supplied,
                             bypasses automatic ZITADEL authentication.
  ZITADEL_ACCESS_TOKEN       ZITADEL admin PAT override.
  ZITADEL_ACCESS_TOKEN_FILE  Mode-0400/0600 ZITADEL admin PAT file override.
  UNIQUE_API_BASE_URL        Default: the hosted-trial API URL.
  CHAT_GRAPHQL_URL           Override the chat GraphQL endpoint.
  INGESTION_GRAPHQL_URL      Override the ingestion GraphQL endpoint.
  --check                    Inspect configuration without mutation.
  --update-assistants        Set every company assistant to TOGETHER_GLM_5_3.
  --reembed                  Explicitly mark and re-embed all finished content.

The LiteLLM master key is read directly from Kubernetes Secret unique/litellm.
Neither token nor key is printed or passed as a command-line argument.
USAGE
}

die() { printf 'ERROR: %s\n' "$*" >&2; exit 1; }

while (($#)); do
  case "$1" in
    --check) MODE=check ;;
    --update-assistants) UPDATE_ASSISTANTS=true ;;
    --reembed) REEMBED=true ;;
    -h|--help) usage; exit 0 ;;
    *) die "unknown option: $1" ;;
  esac
  shift
done
[[ "${MODE}" == apply || "${REEMBED}" == false ]] || die "--check and --reembed cannot be combined"

for command in kubectl curl jq stat base64 mktemp openssl; do
  command -v "${command}" >/dev/null 2>&1 || die "required command not found: ${command}"
done

check_token_file() {
  local file="$1" mode
  [[ -f "${file}" && ! -L "${file}" ]] || die "token file must be a regular file: ${file}"
  mode="$(stat -f '%Lp' "${file}" 2>/dev/null || stat -c '%a' "${file}" 2>/dev/null || true)"
  mode="${mode: -3}"
  [[ "${mode}" == 600 || "${mode}" == 400 ]] \
    || die "token file must have mode 0600 or 0400: ${file}"
}

base64_decode() {
  if base64 --decode </dev/null >/dev/null 2>&1; then base64 --decode; else base64 -D; fi
}
base64url() { openssl base64 -A | tr '+/' '-_' | tr -d '='; }

WORK_DIR="$(mktemp -d "${TMPDIR:-/tmp}/unique-model-setup.XXXXXX")"
chmod 700 "${WORK_DIR}"
AUTH_HEADER_FILE="${WORK_DIR}/app-headers"
ZITADEL_HEADER_FILE="${WORK_DIR}/zitadel-headers"
LITELLM_KEY_FILE="${WORK_DIR}/litellm-key"
SETUP_KEY_ID=""
SETUP_USER_ID=""

zitadel_api() {
  local method="$1" path="$2" body="${3:-}" org="${4:-}" response
  local -a args=(--silent --show-error --fail-with-body --request "${method}"
    --header "@${ZITADEL_HEADER_FILE}")
  [[ -z "${org}" ]] || args+=(--header "x-zitadel-orgid: ${org}")
  [[ -z "${body}" ]] || args+=(--data-binary "${body}")
  response="$(curl "${args[@]}" "${ZITADEL_URL}${path}")" \
    || die "ZITADEL request failed: ${method} ${path}"
  if [[ "$(jq -r 'if type == "object" then (has("code") and has("message")) else false end' <<<"${response}")" == true ]]; then
    die "ZITADEL request failed: $(jq -r '.message' <<<"${response}")"
  fi
  printf '%s' "${response}"
}

cleanup() {
  if [[ -n "${SETUP_KEY_ID}" && -n "${SETUP_USER_ID}" && -f "${ZITADEL_HEADER_FILE}" ]]; then
    zitadel_api DELETE "/management/v1/users/${SETUP_USER_ID}/keys/${SETUP_KEY_ID}" '' \
      "${TARGET_ORG_ID:-}" >/dev/null 2>&1 || true
  fi
  rm -rf "${WORK_DIR}"
}
trap cleanup EXIT

state_output() {
  jq -er --arg name "$1" '.outputs[$name].value' "${TERRAFORM_STATE}" 2>/dev/null
}

mint_application_token() {
  local admin_token encoded response existing grant_id key_file now exp header payload pem signature assertion scope access_token

  if [[ -n "${ZITADEL_ACCESS_TOKEN:-}" ]]; then
    admin_token="${ZITADEL_ACCESS_TOKEN}"
  elif [[ -n "${ZITADEL_PAT:-}" ]]; then
    admin_token="${ZITADEL_PAT}"
  elif [[ -n "${ZITADEL_ACCESS_TOKEN_FILE:-}" ]]; then
    check_token_file "${ZITADEL_ACCESS_TOKEN_FILE}"
    admin_token="$(<"${ZITADEL_ACCESS_TOKEN_FILE}")"
  else
    encoded="$(kubectl -n unique get secret iam-admin-pat -o jsonpath='{.data.pat}' 2>/dev/null)"
    [[ -n "${encoded}" ]] || die "Secret unique/iam-admin-pat is unavailable"
    admin_token="$(printf '%s' "${encoded}" | base64_decode)"
  fi
  [[ -n "${admin_token}" && "${admin_token}" != *[[:space:]]* ]] || die "invalid ZITADEL admin token"
  printf 'Content-Type: application/json\nAuthorization: Bearer %s\n' \
    "${admin_token}" >"${ZITADEL_HEADER_FILE}"
  chmod 600 "${ZITADEL_HEADER_FILE}"
  unset admin_token

  [[ -f "${TERRAFORM_STATE}" ]] || die "ZITADEL Terraform state is unavailable: ${TERRAFORM_STATE}"
  PROJECT_ID="$(state_output project_id)"
  ROOT_ORG_ID="$(state_output root_org_id)"
  TARGET_ORG_ID="$(state_output target_org_id)"

  response="$(zitadel_api POST "/management/v1/projects/${PROJECT_ID}/grants/_search" '{}' "${ROOT_ORG_ID}")"
  PROJECT_GRANT_ID="$(jq -er --arg org "${TARGET_ORG_ID}" \
    'first(.result[] | select(.grantedOrgId == $org) | .grantId) // empty' <<<"${response}")" \
    || die "cannot find the target organization project grant"

  response="$(zitadel_api POST /v2/users \
    "$(jq -cn --arg login "${SETUP_MACHINE_USERNAME}" '{query:{limit:2},queries:[{loginNameQuery:{loginName:$login}}]}')")"
  SETUP_USER_ID="$(jq -r '(.result // [])[0].userId // ""' <<<"${response}")"
  if [[ -z "${SETUP_USER_ID}" ]]; then
    response="$(zitadel_api POST /management/v1/users/machine \
      "$(jq -cn --arg name "${SETUP_MACHINE_USERNAME}" \
        '{userName:$name,name:"HPE Trial Setup",description:"Automation user for hosted-trial setup",accessTokenType:"ACCESS_TOKEN_TYPE_JWT"}')" \
      "${TARGET_ORG_ID}")"
    SETUP_USER_ID="$(jq -er '.userId' <<<"${response}")" || die "ZITADEL did not return a machine user id"
  fi

  response="$(zitadel_api POST /management/v1/users/grants/_search \
    "$(jq -cn --arg uid "${SETUP_USER_ID}" '{queries:[{userIdQuery:{userId:$uid}}]}')" "${TARGET_ORG_ID}")"
  existing="$(jq -c --arg project "${PROJECT_ID}" 'first(.result[]? | select(.projectId == $project)) // empty' <<<"${response}")"
  if [[ -z "${existing}" ]]; then
    zitadel_api POST "/management/v1/users/${SETUP_USER_ID}/grants" \
      "$(jq -cn --arg project "${PROJECT_ID}" --arg grant "${PROJECT_GRANT_ID}" \
        '{projectId:$project,projectGrantId:$grant,roleKeys:["chat.admin.all"]}')" "${TARGET_ORG_ID}" >/dev/null
  elif ! jq -e '.roleKeys | index("chat.admin.all")' <<<"${existing}" >/dev/null; then
    grant_id="$(jq -r '.id' <<<"${existing}")"
    zitadel_api PUT "/management/v1/users/${SETUP_USER_ID}/grants/${grant_id}" \
      "$(jq -cn --argjson roles "$(jq -c '.roleKeys' <<<"${existing}")" \
        '{roleKeys:(($roles + ["chat.admin.all"]) | unique)}')" "${TARGET_ORG_ID}" >/dev/null
  fi

  response="$(zitadel_api POST "/management/v1/users/${SETUP_USER_ID}/keys" \
    '{"type":"KEY_TYPE_JSON"}' "${TARGET_ORG_ID}")"
  key_file="${WORK_DIR}/machine-key.json"
  jq -r '.keyDetails' <<<"${response}" | base64_decode >"${key_file}"
  chmod 600 "${key_file}"
  SETUP_KEY_ID="$(jq -er '.keyId' "${key_file}")"
  now="$(date +%s)"; exp=$((now + 300))
  header="$(jq -cn --arg kid "${SETUP_KEY_ID}" '{alg:"RS256",kid:$kid}' | base64url)"
  payload="$(jq -cn --arg id "${SETUP_USER_ID}" --arg aud "${ZITADEL_URL}" \
    --argjson iat "${now}" --argjson exp "${exp}" \
    '{iss:$id,sub:$id,aud:$aud,iat:$iat,exp:$exp}' | base64url)"
  pem="${WORK_DIR}/machine-key.pem"; jq -r '.key' "${key_file}" >"${pem}"; chmod 600 "${pem}"
  signature="$(printf '%s.%s' "${header}" "${payload}" | openssl dgst -sha256 -sign "${pem}" -binary | base64url)"
  assertion="${header}.${payload}.${signature}"
  scope="openid urn:zitadel:iam:org:project:id:${PROJECT_ID}:aud urn:zitadel:iam:org:projects:roles urn:zitadel:iam:user:resourceowner"
  response="$(curl --silent --show-error --fail-with-body --request POST "${ZITADEL_URL}/oauth/v2/token" \
    --data-urlencode 'grant_type=urn:ietf:params:oauth:grant-type:jwt-bearer' \
    --data-urlencode "assertion=${assertion}" --data-urlencode "scope=${scope}")" \
    || die "ZITADEL token exchange failed"
  access_token="$(jq -er '.access_token' <<<"${response}")" || die "ZITADEL returned no application token"
  printf 'Content-Type: application/json\nAuthorization: Bearer %s\n' \
    "${access_token}" >"${AUTH_HEADER_FILE}"
  chmod 600 "${AUTH_HEADER_FILE}"
}

if [[ -n "${UNIQUE_ACCESS_TOKEN_FILE:-}" ]]; then
  check_token_file "${UNIQUE_ACCESS_TOKEN_FILE}"
  UNIQUE_ACCESS_TOKEN="$(<"${UNIQUE_ACCESS_TOKEN_FILE}")"
  [[ -n "${UNIQUE_ACCESS_TOKEN}" ]] || die "access token file is empty"
  printf 'Content-Type: application/json\nAuthorization: Bearer %s\n' \
    "${UNIQUE_ACCESS_TOKEN}" >"${AUTH_HEADER_FILE}"
  chmod 600 "${AUTH_HEADER_FILE}"
  unset UNIQUE_ACCESS_TOKEN
else
  printf 'No UNIQUE_ACCESS_TOKEN_FILE supplied; minting a short-lived machine token.\n'
  mint_application_token
fi

LITELLM_MASTER_KEY="$(kubectl -n unique get secret litellm -o jsonpath='{.data.PROXY_MASTER_KEY}' | base64_decode)"
[[ -n "${LITELLM_MASTER_KEY}" ]] || die "Secret unique/litellm has no PROXY_MASTER_KEY"
printf '%s' "${LITELLM_MASTER_KEY}" >"${LITELLM_KEY_FILE}"
chmod 600 "${LITELLM_KEY_FILE}"
unset LITELLM_MASTER_KEY

graphql() {
  local url="$1"
  local payload="$2"
  local response
  response="$(curl --fail-with-body --silent --show-error \
    --header "@${AUTH_HEADER_FILE}" --data-binary @- "${url}" <<<"${payload}")" \
    || die "GraphQL request failed at ${url}"
  if [[ "$(jq -r 'has("errors")' <<<"${response}")" == true ]]; then
    jq -r '.errors[] | .message' <<<"${response}" >&2
    die "GraphQL returned an error at ${url}"
  fi
  printf '%s' "${response}"
}

model_query='query Model($deployment: String!) {
  externalLanguageModelFindMany(where: {deploymentName: {equals: $deployment}}) {
    id deploymentName endpoint model version maxTokens apiVersion authHeaderName authHeaderPrefix
    languageModelGroups { groupName }
  }
}'
model_response="$(graphql "${CHAT_GRAPHQL_URL}" "$(jq -cn \
  --arg query "${model_query}" --arg deployment "${CHAT_MODEL_ALIAS}" \
  '{query:$query,variables:{deployment:$deployment}}')")"
model_count="$(jq '.data.externalLanguageModelFindMany | length' <<<"${model_response}")"

if [[ "${model_count}" == 0 ]]; then
  [[ "${MODE}" == apply ]] || die "chat model ${CHAT_MODEL_ALIAS} is not registered"
  create_model='mutation CreateModel($group: String!, $input: ExternalLanguageModelCreateInput!) {
    externalLanguageModelCreate(groupName: $group, input: $input) { id deploymentName }
  }'
  graphql "${CHAT_GRAPHQL_URL}" "$(jq -cn \
    --arg query "${create_model}" --arg group "${CHAT_MODEL_GROUP}" \
    --arg endpoint 'http://litellm.unique.svc.cluster.local:4000/v1' \
    --arg deployment "${CHAT_MODEL_ALIAS}" --rawfile token "${LITELLM_KEY_FILE}" \
    '{query:$query,variables:{group:$group,input:{apiVersion:"v1",authHeaderName:"Authorization",authHeaderPrefix:"Bearer",authHeaderValue:$token,deploymentName:$deployment,endpoint:$endpoint,internalDescription:"Together AI GLM-5.3 through the in-cluster LiteLLM gateway",maxTokens:131072,model:"zai-org/GLM-5.3",version:"GLM-5.3"}}}')" >/dev/null
  printf 'Registered chat model alias %s in group %s.\n' "${CHAT_MODEL_ALIAS}" "${CHAT_MODEL_GROUP}"
elif [[ "${model_count}" == 1 ]]; then
  actual_group="$(jq -r '.data.externalLanguageModelFindMany[0].languageModelGroups[0].groupName // ""' <<<"${model_response}")"
  [[ "${actual_group}" == "${CHAT_MODEL_GROUP}" ]] \
    || die "${CHAT_MODEL_ALIAS} exists in unexpected group ${actual_group}"
  jq -e '.data.externalLanguageModelFindMany[0] |
    .endpoint == "http://litellm.unique.svc.cluster.local:4000/v1" and
    .model == "zai-org/GLM-5.3" and .version == "GLM-5.3" and
    .apiVersion == "v1" and .authHeaderName == "Authorization" and
    .authHeaderPrefix == "Bearer"' <<<"${model_response}" >/dev/null \
    || die "${CHAT_MODEL_ALIAS} exists but its non-secret configuration differs"
  printf 'Chat model alias %s is already registered.\n' "${CHAT_MODEL_ALIAS}"
else
  die "multiple external models use deployment name ${CHAT_MODEL_ALIAS}"
fi

# A brand-new ingestion database has no CompanyMeta row until its first content
# operation. Automatic authentication knows the target company, so initialize
# that otherwise-empty bootstrap row without overwriting any existing values.
if [[ "${MODE}" == apply && -n "${TARGET_ORG_ID:-}" ]]; then
  [[ "${TARGET_ORG_ID}" =~ ^[0-9]+$ ]] || die "unexpected target organization id"
  postgres_pod="$(kubectl -n unique get pods \
    -l 'cnpg.io/cluster=postgres,role=primary' \
    -o jsonpath='{.items[0].metadata.name}' 2>/dev/null || true)"
  [[ -n "${postgres_pod}" ]] || die "cannot find the primary postgres pod"
  kubectl -n unique exec "${postgres_pod}" -- psql -U postgres -d ingestion \
    -v ON_ERROR_STOP=1 -q \
    -c "INSERT INTO \"CompanyMeta\" (\"companyId\", \"collectionName\") VALUES ('${TARGET_ORG_ID}', '${TARGET_ORG_ID}') ON CONFLICT (\"companyId\") DO NOTHING;" \
    >/dev/null
fi

company_query='query CompanyEmbedding { companyMeta { embeddingModel embeddingDimension } }'
company_response="$(graphql "${INGESTION_GRAPHQL_URL}" "$(jq -cn --arg query "${company_query}" '{query:$query}')")"
current_embedding="$(jq -r '.data.companyMeta.embeddingModel // ""' <<<"${company_response}")"
current_dimension="$(jq -r '.data.companyMeta.embeddingDimension // 0' <<<"${company_response}")"
if [[ "${current_embedding}" != "${EMBEDDING_MODEL_ALIAS}" || "${current_dimension}" != "${EMBEDDING_DIMENSION}" ]]; then
  [[ "${MODE}" == apply ]] \
    || die "company embedding is ${current_embedding:-unset}/${current_dimension}, expected ${EMBEDDING_MODEL_ALIAS}/${EMBEDDING_DIMENSION}"
  company_meta='mutation SelectEmbedding($model: String!, $dimension: Float!) {
    companyMetaUpdate(embeddingModel: $model, embeddingDimension: $dimension) { embeddingModel embeddingDimension }
  }'
  graphql "${INGESTION_GRAPHQL_URL}" "$(jq -cn \
    --arg query "${company_meta}" --arg model "${EMBEDDING_MODEL_ALIAS}" \
    --argjson dimension "${EMBEDDING_DIMENSION}" \
    '{query:$query,variables:{model:$model,dimension:$dimension}}')" >/dev/null
  printf 'Selected embedding model %s (%s dimensions) for the token company.\n' \
    "${EMBEDDING_MODEL_ALIAS}" "${EMBEDDING_DIMENSION}"
else
  printf 'Embedding model %s is already selected for the token company.\n' "${EMBEDDING_MODEL_ALIAS}"
fi

if [[ "${UPDATE_ASSISTANTS}" == true ]]; then
  assistants_query='query Assistants { assistants { id name languageModel } }'
  assistants_response="$(graphql "${CHAT_GRAPHQL_URL}" "$(jq -cn --arg query "${assistants_query}" '{query:$query}')")"
  while IFS=$'\t' read -r assistant_id current_model; do
    [[ -n "${assistant_id}" && "${current_model}" != "${CHAT_MODEL_GROUP}" ]] || continue
    [[ "${MODE}" == apply ]] || die "assistant ${assistant_id} does not use ${CHAT_MODEL_GROUP}"
    update_assistant='mutation UpdateAssistant($id: String!, $model: String!) {
      updateAssistant(id: $id, input: {languageModel: $model}) { id languageModel }
    }'
    graphql "${CHAT_GRAPHQL_URL}" "$(jq -cn --arg query "${update_assistant}" \
      --arg id "${assistant_id}" --arg model "${CHAT_MODEL_GROUP}" \
      '{query:$query,variables:{id:$id,model:$model}}')" >/dev/null
    printf 'Updated assistant %s.\n' "${assistant_id}"
  done < <(jq -r '.data.assistants[] | [.id, (.languageModel // "")] | @tsv' <<<"${assistants_response}")
fi

if [[ "${REEMBED}" == true ]]; then
  printf 'Re-embedding all finished content; this can heavily load ingestion.\n'
  mark_query='mutation MarkForReembedding { markForReembedding(where: {}) }'
  run_query='mutation ReembedFiles { reembedFiles }'
  graphql "${INGESTION_GRAPHQL_URL}" "$(jq -cn --arg query "${mark_query}" '{query:$query}')" >/dev/null
  graphql "${INGESTION_GRAPHQL_URL}" "$(jq -cn --arg query "${run_query}" '{query:$query}')" >/dev/null
fi

printf 'Model configuration %s completed.\n' "${MODE}"
