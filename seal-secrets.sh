#!/usr/bin/env bash
set -euo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
HETZNER_STATE="${REPO_ROOT}/.local/hetzner/state/deployment.json"
provider="${CLUSTER_PROVIDER:-}"

require_command() {
  command -v "$1" >/dev/null 2>&1 || {
    printf 'missing required command: %s\n' "$1" >&2
    exit 1
  }
}

# Keep the proven Kind implementation as-is.
if [[ "${provider}" == "kind" ]] ||
  { [[ -z "${provider}" && ! -f "${HETZNER_STATE}" ]] &&
    kubectl config current-context 2>/dev/null | grep -q '^kind-'; }; then
  exec "${REPO_ROOT}/.local/kind/seal-secrets.sh" "$@"
fi

for command in base64 kubectl kubeseal; do
  require_command "${command}"
done

if [[ "${provider}" == "hetzner" || -f "${HETZNER_STATE}" ]]; then
  # shellcheck source=.local/hetzner/common.sh
  source "${REPO_ROOT}/.local/hetzner/common.sh"
  require_state
  write_kubeconfig
  export KUBECONFIG="${KUBECONFIG_FILE}"
elif [[ -n "${provider}" && "${provider}" != "current" ]]; then
  printf 'CLUSTER_PROVIDER must be kind, hetzner, or current\n' >&2
  exit 2
fi

namespace="${SEALED_SECRETS_NAMESPACE:-unique}"
selector="${SEALED_SECRETS_SELECTOR:-sealedsecrets.bitnami.com/sealed-secrets-key=active}"
cert_file="${REPO_ROOT}/public.sealed-secrets.cert.pem"
secret_name=""

for _ in {1..120}; do
  secret_name="$(kubectl -n "${namespace}" get secret --selector "${selector}" \
    -o jsonpath='{.items[0].metadata.name}' 2>/dev/null || true)"
  [[ -n "${secret_name}" ]] && break
  sleep 5
done
if [[ -z "${secret_name}" ]]; then
  printf 'no active Sealed Secrets key found in namespace %s\n' "${namespace}" >&2
  exit 1
fi

if base64 --decode </dev/null >/dev/null 2>&1; then
  decode=(base64 --decode)
else
  decode=(base64 -D)
fi
kubectl -n "${namespace}" get secret "${secret_name}" \
  -o jsonpath='{.data.tls\.crt}' | "${decode[@]}" >"${cert_file}"
[[ -s "${cert_file}" ]] || {
  printf 'failed to download the certificate to %s\n' "${cert_file}" >&2
  exit 1
}
printf 'Downloaded Sealed Secrets certificate to %s\n' "${cert_file}"

args=("$@")
((${#args[@]})) || args=(--all)

process_secret() {
  local input="$1"
  local relative="${input#${REPO_ROOT}/}"
  local output="${input%.secret.yaml}.sealed-secret.yaml"
  printf 'Sealing %s\n' "${relative}"
  kubeseal --cert "${cert_file}" -f "${input}" -o yaml -w "${output}" -n "${namespace}"
}

if [[ "${args[0]}" == "--all" ]]; then
  while IFS= read -r -d '' input; do
    process_secret "${input}"
  done < <(find "${REPO_ROOT}" -type f -name '*.secret.yaml' -print0)
elif ((${#args[@]} == 1)); then
  matches=()
  while IFS= read -r -d '' input; do
    matches+=("${input}")
  done < <(find "${REPO_ROOT}" -type f -name "*${args[0]}*.secret.yaml" -print0)
  if ((${#matches[@]} != 1)); then
    printf 'expected one secret matching %s, found %d\n' "${args[0]}" "${#matches[@]}" >&2
    printf '  %s\n' "${matches[@]#${REPO_ROOT}/}" >&2
    exit 1
  fi
  process_secret "${matches[0]}"
else
  printf 'Usage: %s [--all | secret-name]\n' "$0" >&2
  exit 2
fi
