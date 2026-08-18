#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
CLUSTER_NAME="${KIND_CLUSTER_NAME:-hpe-hosted-trial}"
LOCAL_PATH_VERSION="${LOCAL_PATH_VERSION:-v0.0.36}"
ARGO_CD_CHART_VERSION="${ARGO_CD_CHART_VERSION:-10.3.3}"
ISTIO_VERSION="${ISTIO_VERSION:-1.30.3}"
METRICS_SERVER_CHART_VERSION="${METRICS_SERVER_CHART_VERSION:-3.13.0}"

require_command() {
  command -v "$1" >/dev/null 2>&1 || {
    printf 'missing required command: %s\n' "$1" >&2
    exit 1
  }
}

for command in kind kubectl helm; do
  require_command "${command}"
done

if ! kind get clusters 2>/dev/null | awk -v name="${CLUSTER_NAME}" '$0 == name { found = 1 } END { exit !found }'; then
  kind create cluster \
    --name "${CLUSTER_NAME}" \
    --config "${SCRIPT_DIR}/kind-config.yaml"
fi

kubectl config use-context "kind-${CLUSTER_NAME}" >/dev/null

kubectl create namespace unique --dry-run=client -o yaml | kubectl apply -f -

kubectl apply \
  -f "https://raw.githubusercontent.com/rancher/local-path-provisioner/${LOCAL_PATH_VERSION}/deploy/local-path-storage.yaml"
kubectl -n local-path-storage rollout status \
  deployment/local-path-provisioner \
  --timeout=10m
kubectl annotate storageclass local-path \
  storageclass.kubernetes.io/is-default-class- 2>/dev/null || true
kubectl apply -f "${SCRIPT_DIR}/gl4f-filesystem.storage-class.yaml"

helm repo add metrics-server \
  https://kubernetes-sigs.github.io/metrics-server/ \
  --force-update >/dev/null
helm repo update metrics-server >/dev/null
helm upgrade --install metrics-server metrics-server/metrics-server \
  --version "${METRICS_SERVER_CHART_VERSION}" \
  --namespace kube-system \
  --set 'args[0]=--kubelet-insecure-tls' \
  --wait \
  --timeout 10m

helm repo add istio \
  https://istio-release.storage.googleapis.com/charts \
  --force-update >/dev/null
helm repo update istio >/dev/null
helm upgrade --install istio-base istio/base \
  --version "${ISTIO_VERSION}" \
  --namespace istio-system \
  --create-namespace \
  --wait \
  --timeout 10m
helm upgrade --install istiod istio/istiod \
  --version "${ISTIO_VERSION}" \
  --namespace istio-system \
  --wait \
  --timeout 10m
helm upgrade --install istio-ingressgateway istio/gateway \
  --version "${ISTIO_VERSION}" \
  --namespace istio-system \
  --values "${SCRIPT_DIR}/istio-gateway.values.yaml" \
  --wait \
  --timeout 10m
kubectl apply -f "${SCRIPT_DIR}/ezaf-gateway.yaml"
kubectl apply -f "${SCRIPT_DIR}/local-virtual-services.yaml"

helm upgrade --install argocd \
  oci://ghcr.io/argoproj/argo-helm/argo-cd \
  --version "${ARGO_CD_CHART_VERSION}" \
  --namespace unique \
  --create-namespace \
  --values "${SCRIPT_DIR}/argocd.values.yaml" \
  --wait \
  --timeout 15m

kubectl apply -f "${SCRIPT_DIR}/../../bootstrap.application.yaml"

printf 'kind cluster ready: %s\n' "${CLUSTER_NAME}"
printf 'Argo CD is installed in namespace unique.\n'
printf 'The bootstrap Application starts the progressive 1-system rollout automatically.\n'
printf 'The rollout pauses at the manually synced secrets Application.\n'
