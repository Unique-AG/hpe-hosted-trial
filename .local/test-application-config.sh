#!/usr/bin/env bash

set -euo pipefail

REPOSITORY_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
command -v rg >/dev/null 2>&1 || {
  printf 'FAIL: ripgrep (rg) is required by the repository validation tests\n' >&2
  exit 1
}
CONFIGURED_DOMAIN="$(yq -r '.harbor.registry' "${REPOSITORY_DIR}/versions.yaml" | sed 's/^harbor\.//')"
if [[ "${CONFIGURED_DOMAIN}" == "localhost" ]]; then
  CONFIGURED_SCHEME=http
else
  CONFIGURED_SCHEME=https
fi

assert_yaml_value() {
  local file="$1"
  local expression="$2"
  local expected="$3"
  local actual

  actual="$(yq -r "$expression" "$REPOSITORY_DIR/$file")"
  if [ "$actual" != "$expected" ]; then
    printf 'FAIL: %s %s is %s, expected %s\n' "$file" "$expression" "$actual" "$expected" >&2
    exit 1
  fi
}

assert_file_contains() {
  local file="$1"
  local pattern="$2"

  if ! rg -q "$pattern" "$REPOSITORY_DIR/$file"; then
    printf 'FAIL: %s does not contain %s\n' "$file" "$pattern" >&2
    exit 1
  fi
}

assert_yaml_value ".local/kind/kind-config.yaml" '.networking.disableDefaultCNI' "true"
assert_file_contains ".local/kind/up.sh" 'CILIUM_CHART_VERSION="\$\{CILIUM_CHART_VERSION:-1\.20\.1\}"'
assert_file_contains ".local/kind/up.sh" 'helm upgrade --install cilium cilium/cilium'
assert_file_contains ".local/kind/up.sh" 'crd/ciliumnetworkpolicies\.cilium\.io'
assert_file_contains ".local/kind/up.sh" 'daemonset kindnet'
assert_file_contains ".local/kind/up.sh" 'set autoscaleEnabled=false'
assert_file_contains ".local/hetzner/deploy.sh" 'set autoscaleEnabled=false'
assert_yaml_value ".local/kind/istio-gateway.values.yaml" '.autoscaling.enabled' "false"

assert_yaml_value "1-system/6-kong-plugins/app.yaml" '.spec.source.repoURL' "ghcr.io/unique-ag/helm-charts"
assert_yaml_value "1-system/6-kong-plugins/app.yaml" '.spec.source.chart' "kong-plugins"
assert_yaml_value "1-system/6-kong/app.yaml" '.spec.sources[1].helm.valuesObject.gateway.extraObjects[0].data.KONG_LUA_SSL_VERIFY_DEPTH' "5"
assert_yaml_value "1-system/7-litellm/app.yaml" '.spec.sources[0].ref' "values"
assert_yaml_value "1-system/7-litellm/app.yaml" '.spec.sources[1].helm.valueFiles[0]' '$values/1-system/7-litellm/litellm.values.yaml'
assert_yaml_value "1-system/7-litellm/app.yaml" '.spec.sources[1].helm.valuesObject.proxy_config // ""' ""
assert_yaml_value "1-system/7-litellm/litellm.values.yaml" '.proxy_config.model_list[0].model_name' "unique-chat-glm-5.3"
assert_yaml_value "1-system/7-litellm/litellm.values.yaml" '.proxy_config.model_list[0].litellm_params.model' "together_ai/zai-org/GLM-5.3"
assert_yaml_value "1-system/7-litellm/litellm.values.yaml" '.proxy_config.model_list[1].model_name' "unique-embedding-e5"
assert_yaml_value "1-system/7-litellm/litellm.values.yaml" '.proxy_config.model_list[1].litellm_params.model' "together_ai/intfloat/multilingual-e5-large-instruct"
assert_yaml_value "1-system/2-secrets/litellm/litellm.secret.yaml.example" '.stringData.TOGETHERAI_API_KEY' '{{ .togetherAiApiKey }}'
assert_yaml_value "1-system/5-connection-secrets/node-ingestion-connections.external-secret.yaml" '.spec.target.template.data.LITELLM_MASTER_KEY' '{{ .litellmMasterKey }}'
assert_yaml_value "1-system/5-connection-secrets/node-chat-connections.external-secret.yaml" '.spec.target.template.data.LITELLM_MASTER_KEY' '{{ .litellmMasterKey }}'
assert_file_contains "1-system/5-connection-secrets/node-chat-connections.external-secret.yaml" 'AZURE_OPENAI_API_ENDPOINTS_JSON'
assert_file_contains "1-system/5-connection-secrets/node-chat-connections.external-secret.yaml" 'deploymentName.*unique-chat-glm-5\.3'
assert_file_contains "1-system/5-connection-secrets/node-chat-connections.external-secret.yaml" 'key.*\{\{ \.litellmMasterKey \}\}'
assert_yaml_value "2-applications/1-node-ingestion/app.yaml" '.spec.source.helm.valuesObject.env.USE_OPENAI_V1_EMBEDDINGS' "true"
assert_yaml_value "2-applications/1-node-chat/app.yaml" '.spec.source.helm.valuesObject.env.FEATURE_FLAG_USE_OPENAI_V1_13819' "true"
assert_yaml_value "2-applications/1-ingestor/app.yaml" '.spec.source.helm.valuesObject.resources.requests.cpu' "500m"
assert_yaml_value "2-applications/1-ingestor/app.yaml" '.spec.source.helm.valuesObject.volumeMounts | map(.name) | join(",")' "tmp-volume,artifacts-cache,postgres-ca"
assert_yaml_value "2-applications/4-sbx-gateway/app.yaml" '.spec.source.helm.valuesObject.volumeMounts | map(.name) | join(",")' "egress-config,egress-ca,egress-audit,mitmproxy-confdir,tmp,postgres-ca"
assert_yaml_value "2-applications/4-assistants-agentic-table/app.yaml" '.spec.source.helm.valuesObject.volumeMounts | map(.name) | join(",")' "tmp-volume,gunicorn-runtime,postgres-ca"
assert_yaml_value "2-applications/4-mcp-hub/app.yaml" '.spec.source.helm.valuesObject.extraEnvSecrets[]' "node-chat-secrets"
assert_yaml_value "2-applications/4-mcp-hub/app.yaml" '.spec.source.helm.valuesObject.extraRoutes.well-known.parentRefs[0].name' "unique"
assert_yaml_value "2-applications/4-mcp-hub/app.yaml" '.spec.source.helm.valuesObject.extraRoutes.well-known.parentRefs[0].namespace' "unique"
assert_file_contains "setup-models.sh" 'UNIQUE_ACCESS_TOKEN_FILE'
assert_file_contains "setup-models.sh" 'companyMetaUpdate'
assert_file_contains "setup-models.sh" 'markForReembedding'
assert_yaml_value "1-system/6-kong-plugins/app.yaml" '.spec.source.targetRevision' "2.5.0"
if yq -r '.charts | keys | .[]' "$REPOSITORY_DIR/versions.yaml" | rg -qx 'kong-plugins'; then
  printf 'FAIL: public kong-plugins chart is still included in the Harbor mirror\n' >&2
  exit 1
fi

assert_yaml_value "1-system/8-applications/app.yaml" '.spec.source.directory.include' "apps.application-set.yaml"
assert_yaml_value "2-applications/0-secrets/secret.app.yaml" '.spec.source.directory.include' "*.sealed-secret.yaml"
assert_yaml_value "2-applications/apps.application-set.yaml" '.spec.strategy.rollingSync.steps[0].matchExpressions[0].values[0]' "secrets"
assert_yaml_value "2-applications/apps.application-set.yaml" '.spec.strategy.rollingSync.steps[0].maxUpdate' "0"
assert_yaml_value "2-applications/apps.application-set.yaml" '.spec.generators[0].git.files[0].path' "2-applications/0-secrets/secret.app.yaml"
assert_yaml_value "2-applications/apps.application-set.yaml" '.spec.generators[0].git.files[1].path' "2-applications/*/app.yaml"
if [ -f "$REPOSITORY_DIR/2-applications/secret-gate.application-set.yaml" ]; then
  printf 'FAIL: application secrets must be part of the unified ApplicationSet\n' >&2
  exit 1
fi

if [ -f "$REPOSITORY_DIR/2-applications/4-search-proxy/app.yaml" ]; then
  printf 'FAIL: search-proxy app.yaml is still discoverable by the ApplicationSet\n' >&2
  exit 1
fi
if [ ! -f "$REPOSITORY_DIR/2-applications/4-search-proxy/_app.yaml" ]; then
  printf 'FAIL: disabled search-proxy _app.yaml is missing\n' >&2
  exit 1
fi
assert_yaml_value "versions.yaml" '.charts.search-proxy.runtimeFile' "2-applications/4-search-proxy/_app.yaml"

# HPE requires every platform application to stay in the unique namespace.
while IFS= read -r file; do
  relative_file="${file#"${REPOSITORY_DIR}/"}"
  assert_yaml_value "${relative_file}" '.spec.destination.namespace' "unique"
done < <(find "${REPOSITORY_DIR}/2-applications" -type f \( -name 'app.yaml' -o -name '_app.yaml' \) | sort)

# Use chart-native workload and Service names so the charts' default internal
# service URLs work without per-consumer name overrides.
assert_yaml_value "2-applications/1-node-app-repository/app.yaml" '.spec.source.helm.releaseName' "app-repository"
assert_yaml_value "2-applications/1-node-chat/app.yaml" '.spec.source.helm.releaseName' "chat"
assert_yaml_value "2-applications/1-node-ingestion/app.yaml" '.spec.source.helm.releaseName' "ingestion"
assert_yaml_value "2-applications/1-node-scope-management/app.yaml" '.spec.source.helm.releaseName' "scope-management"
assert_yaml_value "2-applications/2-node-ingestion-worker/app.yaml" '.spec.source.helm.releaseName' "ingestion-worker"
assert_yaml_value "2-applications/2-node-ingestion-worker-chat/app.yaml" '.spec.source.helm.releaseName' "ingestion-chat-worker"
assert_yaml_value "2-applications/2-node-webhook-scheduler/app.yaml" '.spec.source.helm.releaseName' "webhook-scheduler"
assert_yaml_value "2-applications/2-node-webhook-worker/app.yaml" '.spec.source.helm.releaseName' "webhook-worker"
while IFS= read -r file; do
  relative_file="${file#"${REPOSITORY_DIR}/"}"
  assert_yaml_value "${relative_file}" '.spec.source.helm.valuesObject.nameOverride // ""' ""
  assert_yaml_value "${relative_file}" '.spec.source.helm.valuesObject.fullnameOverride // ""' ""
done < <(find "${REPOSITORY_DIR}/2-applications" -type f -name 'app.yaml' | sort)

while IFS= read -r file; do
  assert_yaml_value "$file" '.spec.source.helm.valuesObject.internalServices.namespace // ""' ""
done <<'EOF'
2-applications/1-agentic-ingestion/app.yaml
2-applications/1-assistants-core/app.yaml
2-applications/1-configuration-backend/app.yaml
2-applications/1-gatekeeper/app.yaml
2-applications/1-ingestor/app.yaml
2-applications/1-node-app-repository/app.yaml
2-applications/1-node-chat/app.yaml
2-applications/1-node-ingestion/app.yaml
2-applications/1-node-scope-management/app.yaml
2-applications/1-reflector/app.yaml
2-applications/2-node-ingestion-worker/app.yaml
2-applications/2-node-ingestion-worker-chat/app.yaml
2-applications/2-node-webhook-scheduler/app.yaml
2-applications/2-node-webhook-worker/app.yaml
2-applications/3-admin-app/app.yaml
2-applications/3-chat-app/app.yaml
2-applications/3-knowledge-upload-app/app.yaml
2-applications/3-theme-app/app.yaml
2-applications/4-assistants-agentic-table/app.yaml
2-applications/4-client-insights-exporter/app.yaml
2-applications/4-mcp-hub/app.yaml
2-applications/4-sbx-gateway/app.yaml
2-applications/4-speech/app.yaml
2-applications/4-unique-api/app.yaml
EOF

for file in \
  "2-applications/1-gatekeeper/app.yaml" \
  "2-applications/4-mcp-hub/app.yaml"; do
  assert_yaml_value "$file" '.spec.source.helm.valuesObject.postgresql.connection.username.fromSecret.name' "postgres-secret"
  assert_yaml_value "$file" '.spec.source.helm.valuesObject.postgresql.connection.password.fromSecret.name' "postgres-secret"
  assert_yaml_value "$file" '.spec.source.helm.valuesObject.rabbitmq.connection.username.fromSecret.name' "rabbitmq-password-secret"
  assert_yaml_value "$file" '.spec.source.helm.valuesObject.rabbitmq.connection.password.fromSecret.name' "rabbitmq-password-secret"
done

assert_yaml_value "2-applications/1-gatekeeper/app.yaml" '.spec.source.helm.valuesObject.postgresql.connection.database' "gatekeeper"
assert_yaml_value "2-applications/1-gatekeeper/app.yaml" '.spec.source.helm.valuesObject.env.ADMIN_ROOT_USER_ID' "hpe-hosted-trial-root-user"
assert_yaml_value "2-applications/1-gatekeeper/app.yaml" '.spec.source.helm.valuesObject.env.ADMIN_ROOT_COMPANY_ID' "hpe-hosted-trial-root-company"
assert_yaml_value "2-applications/1-configuration-backend/app.yaml" '.spec.source.helm.valuesObject.autoscaling.enabled' "false"
assert_yaml_value "2-applications/1-node-chat/app.yaml" '.spec.source.helm.valuesObject.autoscaling.enabled' "false"
assert_yaml_value "2-applications/4-unique-api/app.yaml" '.spec.source.helm.valuesObject.autoscaling.enabled' "false"
assert_yaml_value "2-applications/4-sbx-gateway/app.yaml" '.spec.source.helm.valuesObject.autoscaling.enabled' "false"
assert_yaml_value "2-applications/1-configuration-backend/app.yaml" '.spec.source.helm.valuesObject.env.MAX_HEAP_MB' "560"
assert_yaml_value "2-applications/1-configuration-backend/app.yaml" '.spec.source.helm.valuesObject.resources.requests.cpu' "100m"
assert_yaml_value "2-applications/1-configuration-backend/app.yaml" '.spec.source.helm.valuesObject.resources.requests.memory' "600Mi"
assert_yaml_value "2-applications/1-configuration-backend/app.yaml" '.spec.source.helm.valuesObject.internalServices.dependencies.chat.name // ""' ""
assert_yaml_value "2-applications/1-configuration-backend/app.yaml" '.spec.source.helm.valuesObject.internalServices.dependencies.scopeManagement.name // ""' ""
assert_yaml_value "2-applications/1-configuration-backend/app.yaml" '.spec.source.helm.valuesObject.internalServices.dependencies.gatekeeper.enabled' "true"
assert_yaml_value "2-applications/4-mcp-hub/app.yaml" '.spec.source.helm.valuesObject.postgresql.connection.database' "chat"
assert_yaml_value "2-applications/4-mcp-hub/app.yaml" '.spec.source.helm.valuesObject.env.NEXT_APP_URL' "${CONFIGURED_SCHEME}://unique.${CONFIGURED_DOMAIN}"
assert_yaml_value "2-applications/1-node-ingestion/app.yaml" '.spec.source.helm.valuesObject.elasticsearch.connection.password.fromSecret.name' "elasticsearch-ingestion-es-elastic-user"
assert_yaml_value "2-applications/1-node-ingestion/app.yaml" '.spec.source.helm.valuesObject.qdrant.connection.host.fromKubernetesService.name' "qdrant-headless"
assert_yaml_value "2-applications/1-node-ingestion/app.yaml" '.spec.source.helm.valuesObject.env.AZURE_OPENAI_API_VERSION' "2023-03-15-preview"
assert_yaml_value "2-applications/1-node-ingestion/app.yaml" '.spec.source.helm.valuesObject.env.FILE_RETENTION_IN_DAYS' "30"
assert_yaml_value "2-applications/1-node-ingestion/app.yaml" '.spec.source.helm.valuesObject.env.MAX_HEAP_MB' "950"
assert_yaml_value "2-applications/1-node-ingestion/app.yaml" '.spec.source.helm.valuesObject.env.INGESTION_UPLOAD_API_URL' "${CONFIGURED_SCHEME}://api.${CONFIGURED_DOMAIN}/scoped/ingestion/upload"
assert_yaml_value "2-applications/1-node-chat/app.yaml" '.spec.source.helm.valuesObject.env.MAX_HEAP_MB' "1400"

assert_yaml_value "2-applications/1-ingestor/app.yaml" '.spec.source.helm.valuesObject.env.MAX_CONCURRENT_JOBS_PER_REPLICA' "2"
assert_yaml_value "2-applications/1-ingestor/app.yaml" '.spec.source.helm.valuesObject.env.NUM_THREADS_ACCELERATOR_DEVICE' "4"
assert_yaml_value "2-applications/1-ingestor/app.yaml" '.spec.source.helm.valuesObject.pvc.storageClassName' "gl4f-filesystem"
assert_yaml_value "2-applications/2-node-ingestion-worker/app.yaml" '.spec.source.helm.valuesObject.env.MAX_HEAP_MB' "3000"
assert_yaml_value "2-applications/2-node-ingestion-worker/app.yaml" '.spec.source.helm.valuesObject.keda.enabled' "false"
assert_yaml_value "2-applications/2-node-ingestion-worker-chat/app.yaml" '.spec.source.helm.valuesObject.keda.enabled' "false"
assert_yaml_value "2-applications/4-mcp-hub/app.yaml" '.spec.source.helm.valuesObject.workloadIdentity.azure.enabled' "false"
assert_yaml_value "2-applications/2-node-ingestion-worker/app.yaml" '.spec.source.helm.valuesObject.env.NUMBER_OF_PDF_PAGES_IN_PARALLEL' "10"
assert_yaml_value "2-applications/2-node-ingestion-worker-chat/app.yaml" '.spec.source.helm.valuesObject.env.MAX_HEAP_MB' "1500"
assert_yaml_value "2-applications/2-node-ingestion-worker-chat/app.yaml" '.spec.source.helm.valuesObject.env.NUMBER_OF_PDF_PAGES_IN_PARALLEL' "10"
assert_yaml_value "2-applications/2-node-webhook-scheduler/app.yaml" '.spec.source.helm.valuesObject.env.MAX_HEAP_MB' "200"
assert_yaml_value "2-applications/2-node-webhook-worker/app.yaml" '.spec.source.helm.valuesObject.env.MAX_HEAP_MB' "200"
assert_yaml_value "2-applications/1-node-scope-management/app.yaml" '.spec.source.helm.valuesObject.env.CORS_ALLOWED_ORIGINS' ""
assert_yaml_value "2-applications/1-node-scope-management/app.yaml" '.spec.source.helm.valuesObject.env.GATEKEEPER_RUNNING_MODE' "enforce"
assert_yaml_value "2-applications/1-node-scope-management/app.yaml" '.spec.source.helm.valuesObject.env.MAX_HEAP_MB' "700"
assert_yaml_value "2-applications/1-node-scope-management/app.yaml" '.spec.source.helm.valuesObject.env.ZITADEL_HOST' "${CONFIGURED_SCHEME}://id.${CONFIGURED_DOMAIN}"
assert_yaml_value "2-applications/1-gatekeeper/app.yaml" '.spec.source.helm.valuesObject.internalServices.dependencies.scopeManagement.name // ""' ""
assert_yaml_value "2-applications/1-gatekeeper/app.yaml" '.spec.source.helm.valuesObject.internalServices.dependencies.chat.name // ""' ""
assert_yaml_value "2-applications/1-node-scope-management/app.yaml" '.spec.source.helm.valuesObject.extraEnvSecrets[]' "node-scope-management-secrets"
assert_yaml_value "2-applications/1-node-scope-management/node-scope-management.secret.yaml.example" '.stringData.ZITADEL_ROOT_ORG_ID' ""
assert_yaml_value "2-applications/4-client-insights-exporter/app.yaml" '.spec.source.helm.valuesObject.env.MAX_HEAP_MB' "200"
assert_yaml_value "2-applications/4-client-insights-exporter/app.yaml" '.spec.source.helm.valuesObject.env.CLIENT_INSIGHT_SERVER_URL' "https://gateway.unique.app/insights/client-insights"
assert_yaml_value "2-applications/3-admin-app/app.yaml" '.spec.source.helm.valuesObject.env.INGESTION_BACKEND_API_URL' "${CONFIGURED_SCHEME}://api.${CONFIGURED_DOMAIN}/ingestion"
assert_yaml_value "2-applications/3-chat-app/app.yaml" '.spec.source.helm.valuesObject.env.INGESTION_BACKEND_API_URL' "${CONFIGURED_SCHEME}://api.${CONFIGURED_DOMAIN}/ingestion"
assert_yaml_value "2-applications/3-chat-app/app.yaml" '.spec.source.helm.valuesObject.env.REFLECTOR_BACKEND_API_URL' "${CONFIGURED_SCHEME}://api.${CONFIGURED_DOMAIN}"
assert_yaml_value "2-applications/3-knowledge-upload-app/app.yaml" '.spec.source.helm.valuesObject.env.INGESTION_BACKEND_API_URL' "${CONFIGURED_SCHEME}://api.${CONFIGURED_DOMAIN}/ingestion"

for frontend in admin-app chat-app knowledge-upload-app theme-app; do
  csp="$(yq -r '.spec.source.helm.valuesObject.env.CONTENT_SECURITY_POLICY_VALUE' \
    "${REPOSITORY_DIR}/2-applications/3-${frontend}/app.yaml")"
  for endpoint in "${CONFIGURED_SCHEME}://api.${CONFIGURED_DOMAIN}" "${CONFIGURED_SCHEME}://id.${CONFIGURED_DOMAIN}"; do
    if [[ " ${csp} " != *" ${endpoint} "* ]]; then
      printf 'FAIL: %s CSP connect-src does not allow %s\n' "${frontend}" "${endpoint}" >&2
      exit 1
    fi
  done
done

while IFS= read -r file; do
  relative_file="${file#"${REPOSITORY_DIR}/"}"
  assert_yaml_value "${relative_file}" '.spec.source.helm.valuesObject.env.NODE_EXTRA_CA_CERTS' "/etc/ssl/postgres/ca.crt"
  assert_yaml_value "${relative_file}" '.spec.source.helm.valuesObject.volumes[] | select(.name == "postgres-ca") | .secret.secretName' "postgres-ca"
  assert_yaml_value "${relative_file}" '.spec.source.helm.valuesObject.volumeMounts[] | select(.name == "postgres-ca") | .mountPath' "/etc/ssl/postgres/ca.crt"
done < <(rg -l 'host: postgres-rw\.unique\.svc\.cluster\.local' \
  "${REPOSITORY_DIR}/2-applications" --glob '*.yaml')

if yq -r '.spec.sources[1].helm.valuesObject | keys | .[]' \
  "$REPOSITORY_DIR/1-system/7-zitadel/app.yaml" | rg -qx 'serviceAccount'; then
  printf 'FAIL: Zitadel must use the chart hook-managed ServiceAccount\n' >&2
  exit 1
fi
if [ -f "$REPOSITORY_DIR/1-system/7-zitadel/zitadel.service-account.yaml" ]; then
  printf 'FAIL: standalone Zitadel ServiceAccount runs after the chart PreSync hooks\n' >&2
  exit 1
fi

# Operator-side ZITADEL bootstrap invariants. These checks deliberately inspect
# structure and placeholders only; they never contact a cluster or reveal a PAT.
bash -n "$REPOSITORY_DIR/setup-zitadel.sh"
assert_file_contains "setup-zitadel.sh" 'kubectl --namespace unique get secret iam-admin-pat'
assert_file_contains "setup-zitadel.sh" 'TF_DATA_DIR=.*STATE_DIR.*tfdata'
assert_file_contains "setup-zitadel.sh" 'detailed-exitcode'
assert_file_contains "setup-zitadel.sh" 'application-secrets'
assert_file_contains "setup-zitadel.sh" 'sync.*!= OutOfSync'
assert_file_contains "setup-zitadel.sh" 'refusing rotation'
assert_file_contains "setup-zitadel.sh" '\-\-rotate-secret requires \-\-seal'
assert_file_contains "setup-zitadel.sh" 'encrypted_keys'
assert_file_contains "setup-zitadel.sh" 'has_root_org_id'
assert_file_contains "setup-zitadel.sh" 'The generated PAT is never printed'
assert_file_contains "setup-zitadel.sh" 'ZITADEL_USE_PORT_FORWARD:-false'
assert_file_contains "setup-zitadel.sh" 'port-forward service/zitadel :8080'
assert_file_contains ".local/hetzner/deploy.sh" 'reverse_proxy h2c://127.0.0.1:30080'
assert_yaml_value "1-system/7-zitadel/zitadel.virtual-service.yaml" \
  '.spec.http[0].route[0].headers.request.set.X-Forwarded-Proto' "https"
assert_file_contains "setup-zitadel.sh" 'TF_VAR_transport_headers'
assert_file_contains "terraform/zitadel-bootstrap/provider.tf" 'transport_headers.*var.transport_headers'
assert_file_contains "terraform/zitadel-bootstrap/outputs.tf" 'sensitive = true'
if rg -q "ZITADEL_PAT=%s" "$REPOSITORY_DIR/setup-zitadel.sh"; then
  printf 'FAIL: setup-zitadel.sh must never print the generated PAT\n' >&2
  exit 1
fi
if rg -q 'argocd[[:space:]]+app[[:space:]]+sync' "$REPOSITORY_DIR/setup-zitadel.sh"; then
  printf 'FAIL: setup-zitadel.sh must never sync an Argo CD Application\n' >&2
  exit 1
fi
assert_file_contains "terraform/zitadel-bootstrap/versions.tf" 'source = "zitadel/zitadel"'
assert_file_contains "terraform/zitadel-bootstrap/versions.tf" 'version = "= 3\.4\.0"'
assert_file_contains "terraform/zitadel-bootstrap/main.tf" 'OIDC_APP_TYPE_WEB'
assert_file_contains "terraform/zitadel-bootstrap/main.tf" 'OIDC_AUTH_METHOD_TYPE_NONE'
assert_file_contains "terraform/zitadel-bootstrap/main.tf" 'OIDC_TOKEN_TYPE_JWT'
assert_file_contains "terraform/zitadel-bootstrap/main.tf" 'effective_oidc_dev_mode'
assert_file_contains "terraform/zitadel-bootstrap/main.tf" 'dev_mode                    = local.effective_oidc_dev_mode'
assert_file_contains "terraform/zitadel-bootstrap/variables.tf" 'variable "oidc_dev_mode"'
assert_file_contains "terraform/zitadel-bootstrap/variables.tf" 'default     = false'
assert_file_contains "setup-zitadel.sh" 'ZITADEL_OIDC_DEV_MODE'
assert_file_contains "terraform/zitadel-bootstrap/main.tf" 'id_token_userinfo_assertion = true'
role_count="$(rg -c '^    "(chat|admin|connector)\.' \
  "$REPOSITORY_DIR/terraform/zitadel-bootstrap/main.tf")"
if [ "$role_count" != 13 ]; then
  printf 'FAIL: expected all 13 init-zitadel project roles, found %s\n' "$role_count" >&2
  exit 1
fi
assert_yaml_value "1-system/7-zitadel/app.yaml" \
  '.spec.sources[1].helm.valuesObject.zitadel.configmapConfig.FirstInstance.Org.Human.Username' \
  "root@cluster-iam.localhost"
assert_yaml_value "1-system/7-zitadel/app.yaml" \
  '.spec.sources[1].helm.valuesObject.zitadel.configmapConfig.FirstInstance.Org.Human.Password' \
  "RootPassword1!"
assert_yaml_value "1-system/7-zitadel/app.yaml" \
  '.spec.sources[1].helm.valuesObject.zitadel.configmapConfig.FirstInstance.Org.Human.PasswordChangeRequired // false' \
  "true"
assert_file_contains "1-system/7-zitadel/app.yaml" 'password immediately after the first login'
assert_yaml_value "1-system/7-zitadel/app.yaml" \
  '.spec.sources[1].helm.valuesObject.zitadel.configmapConfig.FirstInstance.Org.Machine.Pat.ExpirationDate' \
  "2029-01-01T00:00:00Z"
project_files="$(rg -l --glob 'app.yaml' '^[[:space:]]*ZITADEL_PROJECT_ID:' \
  "$REPOSITORY_DIR/2-applications" || true)"
project_manifest_count="$(printf '%s\n' "$project_files" | sed '/^$/d' | wc -l | tr -d ' ')"
if [ "$project_manifest_count" -ne 24 ]; then
  printf 'FAIL: expected 24 application ZITADEL_PROJECT_ID values, found %s\n' "$project_manifest_count" >&2
  exit 1
fi
project_placeholder_count=0
while IFS= read -r file; do
  [ -n "$file" ] || continue
  value="$(sed -nE 's/^[[:space:]]*ZITADEL_PROJECT_ID:[[:space:]]*([^[:space:]]+).*$/\1/p' "$file" | head -n1 | tr -d '"')"
  if [ "$(yq -r '.spec.source.helm.valuesObject.env.ZITADEL_PROJECT_ID | tag' "$file")" != '!!str' ]; then
    printf 'FAIL: %s ZITADEL_PROJECT_ID must be a YAML string\n' "$file" >&2
    exit 1
  fi
  case "$value" in
    __ZITADEL_PROJECT_ID__|change-me|hpe-hosted-trial)
      project_placeholder_count=$((project_placeholder_count + 1))
      ;;
  esac
done <<< "$project_files"
if [ "$project_manifest_count" -eq 0 ]; then
  printf 'FAIL: no application ZITADEL_PROJECT_ID values were found\n' >&2
  exit 1
fi
if [ "$project_placeholder_count" -ne 0 ] && [ "$project_placeholder_count" -ne "$project_manifest_count" ]; then
  printf 'FAIL: application ZITADEL_PROJECT_ID values are in a mixed placeholder/populated state\n' >&2
  exit 1
fi
project_values="$(printf '%s\n' "$project_files" | while IFS= read -r file; do
  [ -n "$file" ] || continue
  yq -r '.spec.source.helm.valuesObject.env.ZITADEL_PROJECT_ID // ""' "$file"
done)"
project_value_count="$(printf '%s\n' "$project_values" | sed '/^$/d' | wc -l | tr -d ' ')"
project_unique_count="$(printf '%s\n' "$project_values" | sort -u | sed '/^$/d' | wc -l | tr -d ' ')"
if [ "$project_placeholder_count" -eq 0 ]; then
  if [ "$project_value_count" != "$project_manifest_count" ] || [ "$project_unique_count" != 1 ]; then
    printf 'FAIL: populated application ZITADEL_PROJECT_ID values are inconsistent\n' >&2
    exit 1
  fi
  expected_project_id="$(printf '%s\n' "$project_values" | sed '/^$/d' | head -n1)"
  case "$expected_project_id" in
    ''|__ZITADEL_PROJECT_ID__|change-me|hpe-hosted-trial)
      printf 'FAIL: populated application ZITADEL_PROJECT_ID is still a placeholder\n' >&2
      exit 1
      ;;
  esac
else
  expected_project_id=__ZITADEL_PROJECT_ID__
fi

root_org_id="$(yq -r '.spec.source.helm.valuesObject.env.ZITADEL_ROOT_ORG_ID // ""' \
  "$REPOSITORY_DIR/2-applications/1-node-scope-management/app.yaml")"
if [ "$expected_project_id" = __ZITADEL_PROJECT_ID__ ]; then
  [ "$root_org_id" = __ZITADEL_ROOT_ORG_ID__ ] || {
    printf 'FAIL: root organization ID and project IDs are in a mixed placeholder/populated state\n' >&2
    exit 1
  }
else
  case "$root_org_id" in
    ''|__ZITADEL_ROOT_ORG_ID__|"$expected_project_id")
      printf 'FAIL: populated root organization ID is missing, a placeholder, or the project ID\n' >&2
      exit 1
      ;;
  esac
fi

frontend_files="2-applications/3-admin-app/app.yaml
2-applications/3-chat-app/app.yaml
2-applications/3-knowledge-upload-app/app.yaml
2-applications/3-theme-app/app.yaml"
frontend_values="$(printf '%s\n' "$frontend_files" | while IFS= read -r file; do
  yq -r '.spec.source.helm.valuesObject.env.ZITADEL_CLIENT_ID // ""' "$REPOSITORY_DIR/$file"
done)"
frontend_placeholder_count=0
while IFS= read -r value; do
  case "$value" in
    __ZITADEL_CLIENT_ID__|change-me)
      frontend_placeholder_count=$((frontend_placeholder_count + 1))
      ;;
  esac
done <<< "$frontend_values"
if [ "$frontend_placeholder_count" -ne 0 ] && [ "$frontend_placeholder_count" -ne 4 ]; then
  printf 'FAIL: frontend ZITADEL_CLIENT_ID values are in a mixed placeholder/populated state\n' >&2
  exit 1
fi
frontend_value_count="$(printf '%s\n' "$frontend_values" | sed '/^$/d' | wc -l | tr -d ' ')"
frontend_unique_count="$(printf '%s\n' "$frontend_values" | sort -u | sed '/^$/d' | wc -l | tr -d ' ')"
if [ "$frontend_placeholder_count" -eq 0 ]; then
  if [ "$frontend_value_count" != 4 ] || [ "$frontend_unique_count" != 1 ]; then
    printf 'FAIL: populated frontend ZITADEL_CLIENT_ID values are inconsistent\n' >&2
    exit 1
  fi
  case "$(printf '%s\n' "$frontend_values" | sed '/^$/d' | head -n1)" in
    ''|__ZITADEL_CLIENT_ID__|change-me)
      printf 'FAIL: populated frontend ZITADEL_CLIENT_ID is still a placeholder\n' >&2
      exit 1
      ;;
  esac
fi

plugin_project_id="$(yq -r '.config.zitadel_project_id // ""' \
  "$REPOSITORY_DIR/2-applications/0-kong-config/jwt-auth.kong-cluster-plugin.yaml")"
if [ "$expected_project_id" = "__ZITADEL_PROJECT_ID__" ]; then
  case "$plugin_project_id" in
    __ZITADEL_PROJECT_ID__|change-me|hpe-hosted-trial) ;;
    *)
      printf 'FAIL: Kong and application project IDs are in a mixed placeholder/populated state\n' >&2
      exit 1
      ;;
  esac
elif [ "$plugin_project_id" != "$expected_project_id" ]; then
  printf 'FAIL: Kong project ID disagrees with populated application project IDs\n' >&2
  exit 1
fi
if ! git -C "$REPOSITORY_DIR" check-ignore -q .local/zitadel-bootstrap/; then
  printf 'FAIL: Terraform state directory must be ignored\n' >&2
  exit 1
fi
if git -C "$REPOSITORY_DIR" ls-files --error-unmatch \
  2-applications/1-node-scope-management/node-scope-management.secret.yaml >/dev/null 2>&1; then
  printf 'FAIL: node-scope-management plaintext Secret must not be tracked\n' >&2
  exit 1
fi

printf 'PASS: application configuration and ZITADEL bootstrap structure are valid\n'
