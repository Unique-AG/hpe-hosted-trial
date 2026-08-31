#!/usr/bin/env bash
set -euo pipefail

REPOSITORY_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
HETZNER_DIR="${REPOSITORY_DIR}/.local/hetzner"

assert_file_contains() {
  local file="$1"
  local pattern="$2"
  rg -q -- "${pattern}" "${file}" || {
    printf 'FAIL: %s does not contain %s\n' "${file}" "${pattern}" >&2
    exit 1
  }
}

for script in up.sh down.sh seal-secrets.sh set-hostname.sh; do
  bash -n "${REPOSITORY_DIR}/${script}"
done
for helper in common.sh provision.sh deploy.sh down.sh; do
  bash -n "${HETZNER_DIR}/${helper}"
done

assert_file_contains "${REPOSITORY_DIR}/up.sh" 'kind|hetzner'
assert_file_contains "${REPOSITORY_DIR}/up.sh" 'provision\.sh'
assert_file_contains "${REPOSITORY_DIR}/up.sh" 'deploy\.sh'
assert_file_contains "${REPOSITORY_DIR}/seal-secrets.sh" 'tls\\\.crt'
assert_file_contains "${REPOSITORY_DIR}/set-hostname.sh" 'service_names'
assert_file_contains "${REPOSITORY_DIR}/set-hostname.sh" 'x-forwarded-proto'
assert_file_contains "${REPOSITORY_DIR}/set-hostname.sh" 'harbor-internal-tls'
assert_file_contains "${REPOSITORY_DIR}/1-system/5-harbor/app.yaml" 'secretName: harbor-internal-tls'
harbor_forwarded_proto="$(
  yq -r '.spec.http[0].route[0].headers.request.set."x-forwarded-proto"' \
    "${REPOSITORY_DIR}/1-system/5-harbor/harbor.virtual-service.yaml"
)"
if [[ "${harbor_forwarded_proto}" != "https" ]]; then
  printf 'FAIL: Harbor x-forwarded-proto is %s, expected https\n' \
    "${harbor_forwarded_proto}" >&2
  exit 1
fi
assert_file_contains "${REPOSITORY_DIR}/1-system/5-harbor/harbor.destination-rule.yaml" 'insecureSkipVerify: true'
assert_file_contains "${HETZNER_DIR}/provision.sh" 'HETZNER_SERVER_TYPE:-ccx43'
assert_file_contains "${HETZNER_DIR}/deploy.sh" 'rollout status deployment/metrics-server'
assert_file_contains "${HETZNER_DIR}/deploy.sh" 'create_harbor_internal_tls'
assert_file_contains "${HETZNER_DIR}/deploy.sh" 'configs\.tls\.certificates\.harbor'
assert_file_contains "${HETZNER_DIR}/deploy.sh" "sed 's/,/, /g'"
assert_file_contains "${HETZNER_DIR}/deploy.sh" 'reverse_proxy 127\.0\.0\.1:30080'
assert_file_contains "${HETZNER_DIR}/common.sh" '409|422'
assert_file_contains "${HETZNER_DIR}/common.sh" 'UserKnownHostsFile=.*known_hosts'
assert_file_contains "${HETZNER_DIR}/cloud-init.yaml" 'containerd\.runtimes\.runsc'

git -C "${REPOSITORY_DIR}" check-ignore -q .hostname || {
  printf 'FAIL: .hostname must be ignored local state\n' >&2
  exit 1
}
if rg -q 'helm upgrade --install metrics-server' "${HETZNER_DIR}/deploy.sh"; then
  printf 'FAIL: Hetzner must use the metrics-server packaged with k3s\n' >&2
  exit 1
fi

git -C "${REPOSITORY_DIR}" diff --exit-code -- \
  .local/kind/up.sh .local/kind/down.sh .local/kind/seal-secrets.sh

printf 'PASS: unified cluster lifecycle is structurally valid\n'
