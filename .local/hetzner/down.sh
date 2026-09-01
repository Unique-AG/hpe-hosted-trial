#!/usr/bin/env bash

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=common.sh
source "${SCRIPT_DIR}/common.sh"

for command in curl jq; do
  require_command "${command}"
done
require_hcloud_token
require_state

server_id="$(optional_state_value '.server_id')"
firewall_id="$(optional_state_value '.firewall_id')"
ssh_key_id="$(optional_state_value '.ssh_key_id')"
ssh_key_created="$(state_value '.ssh_key_created')"

server_deleted=false
if [[ -n "${server_id}" ]]; then
  hcloud_delete "/servers/${server_id}"
  for _ in {1..60}; do
    status="$(hcloud_status GET "/servers/${server_id}")"
    if [[ "${status}" == "404" ]]; then
      server_deleted=true
      break
    fi
    sleep 2
  done
else
  server_deleted=true
fi
if [[ "${server_deleted}" != "true" ]]; then
  printf 'server %s was not deleted; retaining deployment state\n' "${server_id}" >&2
  exit 1
fi

if [[ -n "${firewall_id}" ]]; then
  hcloud_delete "/firewalls/${firewall_id}"
fi
if [[ "${ssh_key_created}" == "true" && -n "${ssh_key_id}" ]]; then
  hcloud_delete "/ssh_keys/${ssh_key_id}"
fi

rm -rf "${STATE_DIR}"
printf 'Hetzner deployment deleted\n'
