#!/usr/bin/env bash

set -euo pipefail

REPOSITORY_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
VERSIONS_FILE="$REPOSITORY_DIR/versions.yaml"

assert_image() {
  local key="$1"
  local source="$2"
  local destination="$3"
  local actual_source actual_destination

  actual_source="$(yq -r ".images.\"$key\".source // \"\"" "$VERSIONS_FILE")"
  actual_destination="$(yq -r ".images.\"$key\".destination // \"\"" "$VERSIONS_FILE")"
  if [ "$actual_source" != "$source" ]; then
    printf 'FAIL: image %s source is %s, expected %s\n' "$key" "$actual_source" "$source" >&2
    exit 1
  fi
  if [ "$actual_destination" != "$destination" ]; then
    printf 'FAIL: image %s destination is %s, expected %s\n' "$key" "$actual_destination" "$destination" >&2
    exit 1
  fi
}

assert_application_image() {
  local file="$1"
  local repository="$2"
  local actual_registry actual_repository

  actual_registry="$(yq -r '.spec.source.helm.valuesObject.global.image.registry // .spec.source.helm.valuesObject.image.registry // ""' "$REPOSITORY_DIR/$file")"
  actual_repository="$(yq -r '.spec.source.helm.valuesObject.image.repository // ""' "$REPOSITORY_DIR/$file")"
  if [ "$actual_registry" != "harbor.localhost" ]; then
    printf 'FAIL: %s image registry is %s\n' "$file" "$actual_registry" >&2
    exit 1
  fi
  if [ "$actual_repository" != "library/images/$repository" ]; then
    printf 'FAIL: %s image repository is %s, expected library/images/%s\n' "$file" "$actual_repository" "$repository" >&2
    exit 1
  fi
}

assert_application_value() {
  local file="$1"
  local expression="$2"
  local expected="$3"
  local actual

  actual="$(yq -r "$expression" "$REPOSITORY_DIR/$file")"
  if [ "$actual" != "$expected" ]; then
    printf 'FAIL: %s value is %s, expected %s\n' "$file" "$actual" "$expected" >&2
    exit 1
  fi
}

while IFS='|' read -r key source destination; do
  assert_image "$key" "$source" "$destination"
done <<'EOF'
admin|docker://uniqueapp.azurecr.io/admin:2026.34.0-00119a@sha256:ed63a96bf9f6819754da68c8459740d7fbcd5527a4461236c1c6bfef7d7c6410|docker://harbor.localhost/library/images/admin:2026.34.0-00119a
agentic-ingestion|docker://uniqueapp.azurecr.io/unique/agentic-ingestion:2026.34.0-628a58@sha256:419429d3aa15465a2dbb2e9ab99e133f15202248bb680c0a4b375b3ac234caad|docker://harbor.localhost/library/images/agentic-ingestion:2026.34.0-628a58
assistants-agentic-table|docker://uniqueapp.azurecr.io/assistants-agentic-table:2026.34.0-c2cb33@sha256:ff27106e8bdce1931c5da0ffd9bc191b89054a07055c18d2f4fabe9e414ec036|docker://harbor.localhost/library/images/assistants-agentic-table:2026.34.0-c2cb33
assistants-core|docker://uniqueapp.azurecr.io/assistants-core:2026.34.0-c2cb33@sha256:1f094a077fa991900673c61e7bf7b870eab5b2f8f2b6d838c1b89a57c7141824|docker://harbor.localhost/library/images/assistants-core:2026.34.0-c2cb33
app-repository|docker://uniqueapp.azurecr.io/app-repository:2026.34.0-628a58@sha256:b797e91f7c2eed01614f53b3fa1ace5dffc2b0bcae6e433a64853dddf53ac8fb|docker://harbor.localhost/library/images/app-repository:2026.34.0-628a58
chat|docker://uniqueapp.azurecr.io/chat:2026.34.0-00119a@sha256:ee698ef56f98a0ce0175624b79bd7da1d38d46606419327fa1a1d4f24dd5c8b2|docker://harbor.localhost/library/images/chat:2026.34.0-00119a
chat-widget|docker://uniqueapp.azurecr.io/chat-widget:2026.34.0-628a58@sha256:678c2e7f6535f0d2310401adc9fe99f7942f57a5cfb4d33d8dcf79db6a71d960|docker://harbor.localhost/library/images/chat-widget:2026.34.0-628a58
client-insights-exporter|docker://uniqueapp.azurecr.io/client-insights-exporter:2026.34.0-628a58@sha256:1430d8ddb0244d1a26d8a3455cbd4ba11fd567763607c827957bcd4f7eaf34f4|docker://harbor.localhost/library/images/client-insights-exporter:2026.34.0-628a58
configuration-backend|docker://uniqueapp.azurecr.io/configuration-backend:2026.34.0-628a58@sha256:9600cd5bcce3485bb37cb02cc205df117a9f1daaa40353ce6b6a34caa9a24c90|docker://harbor.localhost/library/images/configuration-backend:2026.34.0-628a58
gatekeeper|docker://uniqueapp.azurecr.io/unique/gatekeeper:2026.34.0-628a58@sha256:d7032c8cfb3ec826590dce8dd7f6087fb13a52662e366902c09634dc181152fc|docker://harbor.localhost/library/images/gatekeeper:2026.34.0-628a58
ingestor|docker://uniqueapp.azurecr.io/ingestor:2026.34.0-628a58@sha256:d5c09f43155549ec2571e6ce94476c29ee8ba5293160c7d21f5fb4bc3b355304|docker://harbor.localhost/library/images/ingestor:2026.34.0-628a58
ingestion|docker://uniqueapp.azurecr.io/ingestion:2026.34.0-628a58@sha256:a130688a63dbb7f4c59e43a9687beceaf6603e9ccbc48e486945bbff0b2dbae1|docker://harbor.localhost/library/images/ingestion:2026.34.0-628a58
ingestion-worker|docker://uniqueapp.azurecr.io/ingestion-worker:2026.34.0-628a58@sha256:3369c20908c5ef392deaef1e8eaaec7c0e75ff19218b2efec83a49bfb426a294|docker://harbor.localhost/library/images/ingestion-worker:2026.34.0-628a58
knowledge-upload|docker://uniqueapp.azurecr.io/knowledge-upload:2026.34.0-00119a@sha256:953c4c82b0596c875b5021d9c3a5381a2aef1aa092b1d857b20e1d52b3867eaf|docker://harbor.localhost/library/images/knowledge-upload:2026.34.0-00119a
mcp-hub|docker://uniqueapp.azurecr.io/mcp-hub:2026.34.0-628a58@sha256:da5c66691ecd71f469794100e344939e23754a4f73183e6a9efcffac5d424dc2|docker://harbor.localhost/library/images/mcp-hub:2026.34.0-628a58
node-chat|docker://uniqueapp.azurecr.io/node-chat:2026.34.0-628a58@sha256:d63e67a7529505ccce80d71ed3031ff302b5574a964eeacf5f38c6cb7f04cf94|docker://harbor.localhost/library/images/node-chat:2026.34.0-628a58
node-scope-management|docker://uniqueapp.azurecr.io/node-scope-management:2026.34.0-628a58@sha256:9dde8043272550b53ce5b4f4b057c960d270cd7005b4ce56228b9b2b04580b3d|docker://harbor.localhost/library/images/node-scope-management:2026.34.0-628a58
reflector|docker://uniqueapp.azurecr.io/unique/reflector:2026.34.0-628a58@sha256:bd0068c0fa0dc97dbd1a6a8547844f25537740d15e17e71844a5e42c20426407|docker://harbor.localhost/library/images/reflector:2026.34.0-628a58
sbx-gateway|docker://uniqueapp.azurecr.io/unique/sbx-gateway:2026.34.0-628a58@sha256:c1b267e0ba015ac17d5e7977c553d839fabec57a8763c68582528dd07bdcde93|docker://harbor.localhost/library/images/sbx-gateway:2026.34.0-628a58
sbx-storage|docker://uniqueapp.azurecr.io/unique/sbx-storage:2026.34.0-628a58@sha256:f410ef80e24aa3d2537baa6f92bd2f661f3ce9bb23ac2b4f7e99b4a7b7b3f688|docker://harbor.localhost/library/images/sbx-storage:2026.34.0-628a58
shell-host|docker://uniqueapp.azurecr.io/shell-host:2026.34.0-628a58@sha256:9767e125334083fbf7e699d125c7f00c2c06cfd0d396000cb3ea23cc0c4b03c8|docker://harbor.localhost/library/images/shell-host:2026.34.0-628a58
speech|docker://uniqueapp.azurecr.io/speech:2026.34.0-628a58@sha256:2774bab7ff6cfbebf66a67dcf158360e625076b2069725001d953f8fadff4a13|docker://harbor.localhost/library/images/speech:2026.34.0-628a58
theme|docker://uniqueapp.azurecr.io/theme:2026.34.0-00119a@sha256:aea8115023df9f23d115a9be26491e566ea4e07a61d0dffb539897fd6699a2c2|docker://harbor.localhost/library/images/theme:2026.34.0-00119a
typescript-service-event-socket|docker://uniqueapp.azurecr.io/typescript-service-event-socket:2026.34.0-628a58@sha256:731dc3cd8b82b89a9ef8b973e9b476e26749d80d3075840ffe2e81c6c8d6a222|docker://harbor.localhost/library/images/typescript-service-event-socket:2026.34.0-628a58
unique-api|docker://uniqueapp.azurecr.io/unique/unique-api:2026.34.0-628a58@sha256:12efaa45c63f8579f7363afb7b11c68ef951d5a92cd97bc0981efb0c6ec11f10|docker://harbor.localhost/library/images/unique-api:2026.34.0-628a58
webhook-scheduler|docker://uniqueapp.azurecr.io/webhook-scheduler:2026.34.0-628a58@sha256:f96ad0365908f2ac4ac962cbbcdbf83ad1f5a7251242d839c3f46fc36ff72e22|docker://harbor.localhost/library/images/webhook-scheduler:2026.34.0-628a58
webhook-worker|docker://uniqueapp.azurecr.io/webhook-worker:2026.34.0-628a58@sha256:ebce722e31b588f3492fc889db792194c6e3c734cba357f80956796617514ee0|docker://harbor.localhost/library/images/webhook-worker:2026.34.0-628a58
EOF

while IFS='|' read -r file repository; do
  assert_application_image "$file" "$repository"
done <<'EOF'
2-applications/1-agentic-ingestion/app.yaml|agentic-ingestion
2-applications/1-assistants-core/app.yaml|assistants-core
2-applications/1-configuration-backend/app.yaml|configuration-backend
2-applications/1-gatekeeper/app.yaml|gatekeeper
2-applications/1-ingestor/app.yaml|ingestor
2-applications/1-node-app-repository/app.yaml|app-repository
2-applications/1-node-chat/app.yaml|node-chat
2-applications/1-node-ingestion/app.yaml|ingestion
2-applications/1-node-scope-management/app.yaml|node-scope-management
2-applications/1-reflector/app.yaml|reflector
2-applications/2-node-ingestion-worker/app.yaml|ingestion-worker
2-applications/2-node-ingestion-worker-chat/app.yaml|ingestion-worker
2-applications/2-node-webhook-scheduler/app.yaml|webhook-scheduler
2-applications/2-node-webhook-worker/app.yaml|webhook-worker
2-applications/3-admin-app/app.yaml|admin
2-applications/3-chat-app/app.yaml|chat
2-applications/3-knowledge-upload-app/app.yaml|knowledge-upload
2-applications/3-theme-app/app.yaml|theme
2-applications/4-assistants-agentic-table/app.yaml|assistants-agentic-table
2-applications/4-client-insights-exporter/app.yaml|client-insights-exporter
2-applications/4-mcp-hub/app.yaml|mcp-hub
2-applications/4-sbx-gateway/app.yaml|sbx-gateway
2-applications/4-sbx-storage/app.yaml|sbx-storage
2-applications/4-speech/app.yaml|speech
2-applications/4-unique-api/app.yaml|unique-api
2-applications/4-search-proxy/_app.yaml|search-proxy
2-applications/4-outlook-semantic-mcp/_app.yaml|outlook-semantic-mcp
2-applications/4-sharepoint-connector/_app.yaml|sharepoint-connector
EOF

assert_application_value \
  "2-applications/0-agent-sandbox-controller/app.yaml" \
  '.spec.source.helm.valuesObject.router.image.repository' \
  'harbor.localhost/library/images/sandbox-router'
assert_application_value \
  "2-applications/4-sbx-templates-unique-polyagent-001/app.yaml" \
  '.spec.source.helm.valuesObject.sandboxTemplate.image.repository' \
  'harbor.localhost/library/images/unique-polyagent-001'
assert_application_value \
  "2-applications/0-agent-sandbox-controller/app.yaml" \
  '.spec.source.helm.valuesObject.router.image | (has("digest") and .digest == "")' \
  'true'
assert_application_value \
  "2-applications/4-sbx-templates-unique-polyagent-001/app.yaml" \
  '.spec.source.helm.valuesObject.sandboxTemplate.image | (has("digest") and .digest == "")' \
  'true'

printf 'PASS: proprietary images are mirrored through library/images\n'
