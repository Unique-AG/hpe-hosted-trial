#!/usr/bin/env bash
set -euo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
provider="${1:-}"

if [[ -z "${provider}" ]]; then
  if [[ -f "${REPO_ROOT}/.local/hetzner/state/deployment.json" ]]; then
    provider=hetzner
  else
    provider=kind
  fi
fi

case "${provider}" in
  kind)
    exec bash "${REPO_ROOT}/.local/kind/down.sh"
    ;;
  hetzner)
    if [[ -z "${HCLOUD_TOKEN:-}" ]]; then
      printf 'HCLOUD_TOKEN is required to delete Hetzner resources\n' >&2
      exit 1
    fi
    exec bash "${REPO_ROOT}/.local/hetzner/down.sh"
    ;;
  *)
    printf 'Usage: %s [kind|hetzner]\n' "$0" >&2
    exit 2
    ;;
esac
