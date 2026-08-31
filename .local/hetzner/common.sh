#!/usr/bin/env bash

set -euo pipefail

HETZNER_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPOSITORY_DIR="$(cd "${HETZNER_DIR}/../.." && pwd)"
STATE_DIR="${HETZNER_DIR}/state"
STATE_FILE="${STATE_DIR}/deployment.json"
KUBECONFIG_FILE="${STATE_DIR}/kubeconfig.yaml"
HCLOUD_API_URL="https://api.hetzner.cloud/v1"

require_command() {
  local command="$1"

  if ! command -v "${command}" >/dev/null 2>&1; then
    printf 'missing required command: %s\n' "${command}" >&2
    exit 1
  fi
}

require_state() {
  if [[ ! -f "${STATE_FILE}" ]]; then
    printf 'deployment state not found; run %s/up.sh hetzner first\n' "${REPOSITORY_DIR}" >&2
    exit 1
  fi
}

state_value() {
  jq -er "$1" "${STATE_FILE}"
}

optional_state_value() {
  jq -r "$1 // empty" "${STATE_FILE}"
}

require_hcloud_token() {
  if [[ -z "${HCLOUD_TOKEN:-}" ]]; then
    printf 'HCLOUD_TOKEN is required\n' >&2
    exit 1
  fi
}

hcloud_api() {
  local method="$1"
  local path="$2"
  local data="${3:-}"
  local -a arguments=(
    --fail-with-body
    --silent
    --show-error
    --request "${method}"
    --header "Authorization: Bearer ${HCLOUD_TOKEN}"
    --header "Content-Type: application/json"
  )

  if [[ -n "${data}" ]]; then
    arguments+=(--data "${data}")
  fi

  curl "${arguments[@]}" "${HCLOUD_API_URL}${path}"
}

hcloud_status() {
  local method="$1"
  local path="$2"

  curl \
    --silent \
    --show-error \
    --output /dev/null \
    --write-out '%{http_code}' \
    --request "${method}" \
    --header "Authorization: Bearer ${HCLOUD_TOKEN}" \
    "${HCLOUD_API_URL}${path}"
}

hcloud_delete() {
  local path="$1"
  local status
  local attempt

  # Hetzner can report a server as deleted shortly before its firewall and SSH
  # key attachments are released. Retry those temporary "resource in use"
  # responses so teardown remains idempotent.
  for attempt in {1..60}; do
    status="$(hcloud_status DELETE "${path}")"
    case "${status}" in
      200|201|202|204|404)
        return 0
        ;;
      409|422)
        if (( attempt < 60 )); then
          if (( attempt == 1 )); then
            printf 'Waiting for Hetzner to release %s (HTTP %s)...\n' \
              "${path}" "${status}" >&2
          fi
          sleep 2
          continue
        fi
        ;;
      *) break ;;
    esac
  done

  printf 'Hetzner API deletion failed for %s with HTTP %s\n' "${path}" "${status}" >&2
  return 1
}

ssh_arguments() {
  local private_key
  local server_ip

  private_key="$(state_value '.ssh_private_key')"
  server_ip="$(state_value '.server_ip')"
  printf '%s\n' \
    "-i" "${private_key}" \
    "-o" "BatchMode=yes" \
    "-o" "ConnectTimeout=10" \
    "-o" "StrictHostKeyChecking=accept-new" \
    "-o" "UserKnownHostsFile=${STATE_DIR}/known_hosts" \
    "root@${server_ip}"
}

run_ssh() {
  local -a arguments=()

  while IFS= read -r argument; do
    arguments+=("${argument}")
  done < <(ssh_arguments)

  ssh "${arguments[@]}" "$@"
}

write_kubeconfig() {
  local server_ip
  local kubeconfig

  server_ip="$(state_value '.server_ip')"
  kubeconfig="$(run_ssh 'cat /etc/rancher/k3s/k3s.yaml')"
  mkdir -p "${STATE_DIR}"
  printf '%s\n' "${kubeconfig/127.0.0.1/${server_ip}}" >"${KUBECONFIG_FILE}"
  chmod 600 "${KUBECONFIG_FILE}"
}
