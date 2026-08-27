#!/usr/bin/env bash

set -euo pipefail

REPOSITORY_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"

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

assert_yaml_value "1-system/6-kong-plugins/app.yaml" '.spec.source.repoURL' "ghcr.io/unique-ag/helm-charts"
assert_yaml_value "1-system/6-kong-plugins/app.yaml" '.spec.source.chart' "kong-plugins"
assert_yaml_value "1-system/6-kong-plugins/app.yaml" '.spec.source.targetRevision' "2.5.0"
if yq -r '.charts | keys | .[]' "$REPOSITORY_DIR/versions.yaml" | rg -qx 'kong-plugins'; then
  printf 'FAIL: public kong-plugins chart is still included in the Harbor mirror\n' >&2
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
assert_yaml_value "2-applications/4-mcp-hub/app.yaml" '.spec.source.helm.valuesObject.postgresql.connection.database' "chat"
assert_yaml_value "2-applications/4-mcp-hub/app.yaml" '.spec.source.helm.valuesObject.env.NEXT_APP_URL' "http://unique.localhost"
assert_yaml_value "2-applications/1-node-ingestion/app.yaml" '.spec.source.helm.valuesObject.elasticsearch.connection.password.fromSecret.name' "elasticsearch-ingestion-es-elastic-user"
assert_yaml_value "2-applications/1-node-ingestion/app.yaml" '.spec.source.helm.valuesObject.qdrant.connection.host.fromKubernetesService.name' "qdrant-headless"
assert_yaml_value "2-applications/1-node-ingestion/app.yaml" '.spec.source.helm.valuesObject.env.AZURE_OPENAI_API_VERSION' "2023-03-15-preview"
assert_yaml_value "2-applications/1-node-ingestion/app.yaml" '.spec.source.helm.valuesObject.env.FILE_RETENTION_IN_DAYS' "30"
assert_yaml_value "2-applications/1-node-ingestion/app.yaml" '.spec.source.helm.valuesObject.env.MAX_HEAP_MB' "950"
assert_yaml_value "2-applications/1-node-ingestion/app.yaml" '.spec.source.helm.valuesObject.env.INGESTION_UPLOAD_API_URL' "http://api.localhost/scoped/ingestion/upload"
assert_yaml_value "2-applications/1-node-chat/app.yaml" '.spec.source.helm.valuesObject.env.MAX_HEAP_MB' "1400"

assert_yaml_value "2-applications/1-ingestor/app.yaml" '.spec.source.helm.valuesObject.env.MAX_CONCURRENT_JOBS_PER_REPLICA' "2"
assert_yaml_value "2-applications/1-ingestor/app.yaml" '.spec.source.helm.valuesObject.env.NUM_THREADS_ACCELERATOR_DEVICE' "4"
assert_yaml_value "2-applications/1-ingestor/app.yaml" '.spec.source.helm.valuesObject.pvc.storageClassName' "standard"
assert_yaml_value "2-applications/2-node-ingestion-worker/app.yaml" '.spec.source.helm.valuesObject.env.MAX_HEAP_MB' "3000"
assert_yaml_value "2-applications/2-node-ingestion-worker/app.yaml" '.spec.source.helm.valuesObject.env.NUMBER_OF_PDF_PAGES_IN_PARALLEL' "10"
assert_yaml_value "2-applications/2-node-ingestion-worker-chat/app.yaml" '.spec.source.helm.valuesObject.env.MAX_HEAP_MB' "1500"
assert_yaml_value "2-applications/2-node-ingestion-worker-chat/app.yaml" '.spec.source.helm.valuesObject.env.NUMBER_OF_PDF_PAGES_IN_PARALLEL' "10"
assert_yaml_value "2-applications/2-node-webhook-scheduler/app.yaml" '.spec.source.helm.valuesObject.env.MAX_HEAP_MB' "200"
assert_yaml_value "2-applications/2-node-webhook-worker/app.yaml" '.spec.source.helm.valuesObject.env.MAX_HEAP_MB' "200"
assert_yaml_value "2-applications/1-node-scope-management/app.yaml" '.spec.source.helm.valuesObject.env.CORS_ALLOWED_ORIGINS' ""
assert_yaml_value "2-applications/1-node-scope-management/app.yaml" '.spec.source.helm.valuesObject.env.MAX_HEAP_MB' "700"
assert_yaml_value "2-applications/1-node-scope-management/app.yaml" '.spec.source.helm.valuesObject.env.ZITADEL_HOST' "http://id.localhost"
assert_yaml_value "2-applications/1-node-scope-management/app.yaml" '.spec.source.helm.valuesObject.env.ZITADEL_ROOT_ORG_ID' "overridden-by-node-scope-management-secrets"
assert_yaml_value "2-applications/1-node-scope-management/node-scope-management.secret.yaml.example" '.stringData.ZITADEL_ROOT_ORG_ID' ""
assert_yaml_value "2-applications/4-client-insights-exporter/app.yaml" '.spec.source.helm.valuesObject.env.MAX_HEAP_MB' "200"
assert_yaml_value "2-applications/4-client-insights-exporter/app.yaml" '.spec.source.helm.valuesObject.env.CLIENT_INSIGHT_SERVER_URL' "https://gateway.unique.app/insights/client-insights"
assert_yaml_value "2-applications/3-admin-app/app.yaml" '.spec.source.helm.valuesObject.env.INGESTION_BACKEND_API_URL' "http://api.localhost/ingestion"
assert_yaml_value "2-applications/3-chat-app/app.yaml" '.spec.source.helm.valuesObject.env.INGESTION_BACKEND_API_URL' "http://api.localhost/ingestion"
assert_yaml_value "2-applications/3-chat-app/app.yaml" '.spec.source.helm.valuesObject.env.REFLECTOR_BACKEND_API_URL' "http://api.localhost"
assert_yaml_value "2-applications/3-knowledge-upload-app/app.yaml" '.spec.source.helm.valuesObject.env.INGESTION_BACKEND_API_URL' "http://api.localhost/ingestion"

assert_yaml_value "1-system/7-zitadel/app.yaml" '.spec.sources[1].helm.valuesObject.serviceAccount.create' "false"
assert_yaml_value "1-system/7-zitadel/app.yaml" '.spec.sources[1].helm.valuesObject.serviceAccount.name' "zitadel"
assert_yaml_value "1-system/7-zitadel/zitadel.service-account.yaml" '.metadata.name' "zitadel"

printf 'PASS: application configuration is compatible with the pinned charts\n'
