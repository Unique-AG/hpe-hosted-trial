#!/usr/bin/env bash
set -euo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
provider="${1:-}"

cleanup_local_test_state() {
  # ZITADEL state and operator tokens belong to the cluster being deleted. They
  # must not be reused when a new local test cluster receives different object
  # IDs and credentials.
  rm -rf -- "${REPO_ROOT}/.local/zitadel-bootstrap"
  rm -f -- "${REPO_ROOT}/.local/unique-admin.token"
  printf 'Removed cluster-bound local test state\n'
}

if [[ -z "${provider}" ]]; then
  if [[ -f "${REPO_ROOT}/.local/hetzner/state/deployment.json" ]]; then
    provider=hetzner
  else
    provider=kind
  fi
fi

case "${provider}" in
  kind)
    bash "${REPO_ROOT}/.local/kind/down.sh"
    cleanup_local_test_state
    ;;
  hetzner)
    if [[ -z "${HCLOUD_TOKEN:-}" ]]; then
      printf 'HCLOUD_TOKEN is required to delete Hetzner resources\n' >&2
      exit 1
    fi
    bash "${REPO_ROOT}/.local/hetzner/down.sh"
    cleanup_local_test_state
    ;;
  *)
    printf 'Usage: %s [kind|hetzner]\n' "$0" >&2
    exit 2
    ;;
esac
