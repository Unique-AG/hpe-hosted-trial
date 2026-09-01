#!/usr/bin/env bash
set -euo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
provider="${1:-}"

usage() {
  printf 'Usage: %s <kind|hetzner>\n' "$0" >&2
  exit 2
}

case "${provider}" in
  kind)
    exec bash "${REPO_ROOT}/.local/kind/up.sh"
    ;;
  hetzner)
    if [[ -z "${HCLOUD_TOKEN:-}" ]]; then
      printf 'HCLOUD_TOKEN is required for Hetzner Cloud\n' >&2
      exit 1
    fi
    if [[ ! -f "${REPO_ROOT}/.local/hetzner/state/deployment.json" ]]; then
      bash "${REPO_ROOT}/.local/hetzner/provision.sh"
    else
      printf 'Using the existing Hetzner server in .local/hetzner/state.\n'
    fi
    exec bash "${REPO_ROOT}/.local/hetzner/deploy.sh"
    ;;
  *) usage ;;
esac
