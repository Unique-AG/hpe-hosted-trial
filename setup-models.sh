#!/usr/bin/env bash
set -euo pipefail

REPOSITORY_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
CHAT_MODEL_ALIAS="${CHAT_MODEL_ALIAS:-unique-chat-glm-5.3}"
CHAT_MODEL_GROUP="${CHAT_MODEL_GROUP:-TOGETHER_GLM_5_3}"
EMBEDDING_MODEL_ALIAS="${EMBEDDING_MODEL_ALIAS:-unique-embedding-e5}"
EMBEDDING_DIMENSION="${EMBEDDING_DIMENSION:-1024}"
UNIQUE_API_BASE_URL="${UNIQUE_API_BASE_URL:-https://api.2.28.18.215.sslip.io}"
CHAT_GRAPHQL_URL="${CHAT_GRAPHQL_URL:-${UNIQUE_API_BASE_URL}/chat/graphql}"
INGESTION_GRAPHQL_URL="${INGESTION_GRAPHQL_URL:-${UNIQUE_API_BASE_URL}/ingestion/graphql}"
MODE=apply
UPDATE_ASSISTANTS=false
REEMBED=false

usage() {
  cat <<'USAGE'
Usage: ./setup-models.sh [--check] [--update-assistants] [--reembed]

Registers the Together GLM model with Unique, selects the Together E5 embedding
model for the token's company, and optionally updates all company assistants.

Required:
  UNIQUE_ACCESS_TOKEN_FILE   Mode-0600 file containing a user token with
                             chat.admin.all and ingestion administration access.

Optional:
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

for command in kubectl curl jq stat base64 mktemp; do
  command -v "${command}" >/dev/null 2>&1 || die "required command not found: ${command}"
done
[[ -n "${UNIQUE_ACCESS_TOKEN_FILE:-}" && -f "${UNIQUE_ACCESS_TOKEN_FILE}" ]] \
  || die "UNIQUE_ACCESS_TOKEN_FILE must point to a token file"
if [[ "$(uname -s)" == Darwin ]]; then
  token_mode="$(stat -f '%Lp' "${UNIQUE_ACCESS_TOKEN_FILE}")"
else
  token_mode="$(stat -c '%a' "${UNIQUE_ACCESS_TOKEN_FILE}")"
fi
[[ "${token_mode}" == 600 || "${token_mode}" == 400 ]] \
  || die "UNIQUE_ACCESS_TOKEN_FILE must have mode 0600 or 0400"

UNIQUE_ACCESS_TOKEN="$(<"${UNIQUE_ACCESS_TOKEN_FILE}")"
[[ -n "${UNIQUE_ACCESS_TOKEN}" ]] || die "access token file is empty"
LITELLM_MASTER_KEY="$(kubectl -n unique get secret litellm -o jsonpath='{.data.PROXY_MASTER_KEY}' | base64 -d)"
[[ -n "${LITELLM_MASTER_KEY}" ]] || die "Secret unique/litellm has no PROXY_MASTER_KEY"
AUTH_HEADER_FILE="$(mktemp "${TMPDIR:-/tmp}/unique-model-auth.XXXXXX")"
LITELLM_KEY_FILE="$(mktemp "${TMPDIR:-/tmp}/unique-litellm-key.XXXXXX")"
chmod 600 "${AUTH_HEADER_FILE}" "${LITELLM_KEY_FILE}"
printf 'Content-Type: application/json\nAuthorization: Bearer %s\n' \
  "${UNIQUE_ACCESS_TOKEN}" >"${AUTH_HEADER_FILE}"
printf '%s' "${LITELLM_MASTER_KEY}" >"${LITELLM_KEY_FILE}"
unset UNIQUE_ACCESS_TOKEN LITELLM_MASTER_KEY
trap 'rm -f "${AUTH_HEADER_FILE:-}" "${LITELLM_KEY_FILE:-}"' EXIT

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
