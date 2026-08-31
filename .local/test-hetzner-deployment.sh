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
assert_file_contains "${HETZNER_DIR}/provision.sh" 'HETZNER_SERVER_TYPE:-ccx43'
assert_file_contains "${HETZNER_DIR}/deploy.sh" 'reverse_proxy 127\.0\.0\.1:30080'
assert_file_contains "${HETZNER_DIR}/cloud-init.yaml" 'containerd\.runtimes\.runsc'

git -C "${REPOSITORY_DIR}" diff --exit-code -- \
  .local/kind/up.sh .local/kind/down.sh .local/kind/seal-secrets.sh

printf 'PASS: unified cluster lifecycle is structurally valid\n'
