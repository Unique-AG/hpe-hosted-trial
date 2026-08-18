#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "${SCRIPT_DIR}/../.." && pwd)"
KIND_CONTEXT="${KIND_CONTEXT:-kind-hpe-hosted-trial}"
SEALED_SECRETS_NAMESPACE="${SEALED_SECRETS_NAMESPACE:-unique}"
SEALED_SECRETS_SECRET="${SEALED_SECRETS_SECRET:-}"
SEALED_SECRETS_SELECTOR="${SEALED_SECRETS_SELECTOR:-sealedsecrets.bitnami.com/sealed-secrets-key=active}"
CERT_FILE="${REPO_ROOT}/public.sealed-secrets.cert.pem"

for command in kubectl base64 kubeseal; do
    if ! command -v "${command}" >/dev/null 2>&1; then
        printf 'missing required command: %s\n' "${command}" >&2
        exit 1
    fi
done

decode_base64() {
    if base64 --decode </dev/null >/dev/null 2>&1; then
        base64 --decode
    else
        base64 -D
    fi
}

if [[ -n "${SEALED_SECRETS_SECRET}" ]]; then
    secret_name="${SEALED_SECRETS_SECRET}"
else
    secret_name="$(
        kubectl --context "${KIND_CONTEXT}" \
            --namespace "${SEALED_SECRETS_NAMESPACE}" \
            get secret \
            --selector "${SEALED_SECRETS_SELECTOR}" \
            -o jsonpath='{.items[0].metadata.name}'
    )"
fi

if [[ -z "${secret_name}" ]]; then
    printf 'no Sealed Secrets key Secret found in namespace %s with selector %s\n' \
        "${SEALED_SECRETS_NAMESPACE}" "${SEALED_SECRETS_SELECTOR}" >&2
    exit 1
fi

printf 'Reading the Sealed Secrets certificate from %s/%s in context %s...\n' \
    "${SEALED_SECRETS_NAMESPACE}" "${secret_name}" "${KIND_CONTEXT}"
certificate="$(
    kubectl --context "${KIND_CONTEXT}" \
        --namespace "${SEALED_SECRETS_NAMESPACE}" \
        get secret "${secret_name}" \
        -o jsonpath='{.data.tls\.crt}'
)"

if [[ -z "${certificate}" ]]; then
    printf 'certificate key tls.crt is empty in Secret %s/%s\n' \
        "${SEALED_SECRETS_NAMESPACE}" "${secret_name}" >&2
    exit 1
fi

printf '%s' "${certificate}" | decode_base64 >"${CERT_FILE}"
if [[ ! -s "${CERT_FILE}" ]]; then
    printf 'failed to write certificate to %s\n' "${CERT_FILE}" >&2
    exit 1
fi

printf 'Wrote certificate to %s\n' "${CERT_FILE}"

if [[ "$#" -eq 0 ]]; then
    set -- --all
fi

cd "${REPO_ROOT}"
exec "${REPO_ROOT}/seal-secrets.sh" "$@"
