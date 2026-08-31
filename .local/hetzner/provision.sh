#!/usr/bin/env bash

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=common.sh
source "${SCRIPT_DIR}/common.sh"

SERVER_NAME="${HETZNER_SERVER_NAME:-hpe-hosted-trial}"
SERVER_TYPE="${HETZNER_SERVER_TYPE:-ccx43}"
SERVER_LOCATION="${HETZNER_LOCATION:-fsn1}"
SERVER_IMAGE="${HETZNER_IMAGE:-ubuntu-24.04}"
SSH_PUBLIC_KEY_FILE="${HETZNER_SSH_PUBLIC_KEY_FILE:-${HOME}/.ssh/id_rsa.pub}"
SSH_PRIVATE_KEY_FILE="${HETZNER_SSH_PRIVATE_KEY_FILE:-${SSH_PUBLIC_KEY_FILE%.pub}}"
K3S_VERSION="${K3S_VERSION:-v1.36.1+k3s1}"
RUNSC_VERSION="${RUNSC_VERSION:-20250707.0}"

for command in awk curl jq sed ssh ssh-keygen; do
  require_command "${command}"
done
require_hcloud_token

if [[ -e "${STATE_FILE}" ]]; then
  printf 'deployment state already exists: %s\n' "${STATE_FILE}" >&2
  exit 1
fi
if [[ ! -f "${SSH_PUBLIC_KEY_FILE}" || ! -f "${SSH_PRIVATE_KEY_FILE}" ]]; then
  printf 'SSH key pair not found: %s and %s\n' \
    "${SSH_PUBLIC_KEY_FILE}" "${SSH_PRIVATE_KEY_FILE}" >&2
  exit 1
fi

server_id=""
server_ip=""
base_domain=""
firewall_id=""
ssh_key_id=""
ssh_key_created=false

persist_state() {
  mkdir -p "${STATE_DIR}"
  jq -n \
    --arg server_id "${server_id}" \
    --arg firewall_id "${firewall_id}" \
    --arg ssh_key_id "${ssh_key_id}" \
    --argjson ssh_key_created "${ssh_key_created}" \
    --arg server_ip "${server_ip}" \
    --arg base_domain "${base_domain}" \
    --arg ssh_private_key "${SSH_PRIVATE_KEY_FILE}" \
    '{
      server_id: (if $server_id == "" then null else ($server_id | tonumber) end),
      firewall_id: (if $firewall_id == "" then null else ($firewall_id | tonumber) end),
      ssh_key_id: (if $ssh_key_id == "" then null else ($ssh_key_id | tonumber) end),
      ssh_key_created: $ssh_key_created,
      server_ip: (if $server_ip == "" then null else $server_ip end),
      base_domain: (if $base_domain == "" then null else $base_domain end),
      ssh_private_key: $ssh_private_key
    }' >"${STATE_FILE}"
  chmod 600 "${STATE_FILE}"
}

cleanup_provisioning_resources() {
  local cleanup_failed=false

  if [[ -n "${server_id}" ]]; then
    hcloud_delete "/servers/${server_id}" || cleanup_failed=true
    server_deleted=false
    for _ in {1..30}; do
      if [[ "$(hcloud_status GET "/servers/${server_id}")" == "404" ]]; then
        server_deleted=true
        break
      fi
      sleep 2
    done
    if [[ "${server_deleted}" != "true" ]]; then
      cleanup_failed=true
    fi
  fi
  if [[ -n "${firewall_id}" ]]; then
    hcloud_delete "/firewalls/${firewall_id}" || cleanup_failed=true
  fi
  if [[ "${ssh_key_created}" == "true" && -n "${ssh_key_id}" ]]; then
    hcloud_delete "/ssh_keys/${ssh_key_id}" || cleanup_failed=true
  fi
  if [[ "${cleanup_failed}" == "false" ]]; then
    rm -rf "${STATE_DIR}"
  else
    printf 'automatic cleanup failed; recovery state retained at %s\n' "${STATE_FILE}" >&2
  fi
}
trap cleanup_provisioning_resources EXIT

public_key="$(<"${SSH_PUBLIC_KEY_FILE}")"
ssh_fingerprint="$(
  ssh-keygen -E md5 -lf "${SSH_PUBLIC_KEY_FILE}" |
    awk '{ sub(/^MD5:/, "", $2); print $2 }'
)"
client_ip="$(curl --fail --silent --show-error --ipv4 https://api.ipify.org)"
ssh_key_id="$(
  hcloud_api GET '/ssh_keys?per_page=50' |
    jq -er --arg fingerprint "${ssh_fingerprint}" \
      'first(.ssh_keys[] | select(.fingerprint == $fingerprint) | .id) // empty'
)" || true
if [[ -z "${ssh_key_id}" ]]; then
  ssh_key_payload="$(
    jq -n \
      --arg name "${SERVER_NAME}-$(date +%s)" \
      --arg public_key "${public_key}" \
      '{name: $name, public_key: $public_key}'
  )"
  ssh_key_response="$(
    hcloud_api POST /ssh_keys "${ssh_key_payload}"
  )"
  ssh_key_id="$(jq -er '.ssh_key.id' <<<"${ssh_key_response}")"
  ssh_key_created=true
  persist_state
fi

firewall_payload="$(
  jq -n \
    --arg name "${SERVER_NAME}-$(date +%s)" \
    --arg ssh_source "${client_ip}/32" \
    '{
      name: $name,
      rules: [
        {direction: "in", protocol: "tcp", port: "22", source_ips: [$ssh_source]},
        {direction: "in", protocol: "tcp", port: "6443", source_ips: [$ssh_source]},
        {direction: "in", protocol: "tcp", port: "80", source_ips: ["0.0.0.0/0", "::/0"]},
        {direction: "in", protocol: "tcp", port: "443", source_ips: ["0.0.0.0/0", "::/0"]}
      ]
    }'
)"
firewall_response="$(
  hcloud_api POST /firewalls "${firewall_payload}"
)"
firewall_id="$(jq -er '.firewall.id' <<<"${firewall_response}")"
persist_state

cloud_init="$(
  sed \
    -e "s|__K3S_VERSION__|${K3S_VERSION}|g" \
    -e "s|__RUNSC_VERSION__|${RUNSC_VERSION}|g" \
    "${SCRIPT_DIR}/cloud-init.yaml"
)"
server_payload="$(
  jq -n \
    --arg name "${SERVER_NAME}" \
    --arg server_type "${SERVER_TYPE}" \
    --arg location "${SERVER_LOCATION}" \
    --arg image "${SERVER_IMAGE}" \
    --arg user_data "${cloud_init}" \
    --argjson ssh_key_id "${ssh_key_id}" \
    --argjson firewall_id "${firewall_id}" \
    '{
      name: $name,
      server_type: $server_type,
      location: $location,
      image: $image,
      user_data: $user_data,
      ssh_keys: [$ssh_key_id],
      firewalls: [{firewall: $firewall_id}],
      labels: {deployment: "hpe-hosted-trial"},
      start_after_create: true
    }'
)"
server_response="$(
  hcloud_api POST /servers "${server_payload}"
)"
server_id="$(jq -er '.server.id' <<<"${server_response}")"
server_ip="$(jq -er '.server.public_net.ipv4.ip' <<<"${server_response}")"
base_domain="${server_ip}.sslip.io"
persist_state
trap - EXIT

for _ in {1..60}; do
  if run_ssh true >/dev/null 2>&1; then
    break
  fi
  sleep 5
done
if ! run_ssh true >/dev/null 2>&1; then
  printf 'server did not become reachable over SSH: %s\n' "${server_ip}" >&2
  exit 1
fi

run_ssh 'cloud-init status --wait'
write_kubeconfig

printf 'Hetzner server ready: %s (%s)\n' "${SERVER_NAME}" "${server_ip}"
printf 'Base domain: %s\n' "${base_domain}"
printf 'Cluster provisioning complete.\n'
