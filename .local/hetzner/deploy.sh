#!/usr/bin/env bash

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=common.sh
source "${SCRIPT_DIR}/common.sh"
ARGO_CD_CHART_VERSION="${ARGO_CD_CHART_VERSION:-10.3.3}"
CILIUM_CHART_VERSION="${CILIUM_CHART_VERSION:-1.20.1}"
ISTIO_VERSION="${ISTIO_VERSION:-1.30.3}"
METRICS_SERVER_CHART_VERSION="${METRICS_SERVER_CHART_VERSION:-3.13.0}"
NFS_SERVER_PROVISIONER_CHART_VERSION="${NFS_SERVER_PROVISIONER_CHART_VERSION:-1.8.0}"
NFS_STORAGE_SIZE="${NFS_STORAGE_SIZE:-100Gi}"

for command in helm jq kubectl paste; do
  require_command "${command}"
done
require_state

write_kubeconfig
export KUBECONFIG="${KUBECONFIG_FILE}"
server_ip="$(state_value '.server_ip')"
base_domain="$(state_value '.base_domain')"

helm repo add cilium https://helm.cilium.io --force-update >/dev/null
helm repo update cilium >/dev/null
helm upgrade --install cilium cilium/cilium \
  --version "${CILIUM_CHART_VERSION}" \
  --namespace kube-system \
  --set image.pullPolicy=IfNotPresent \
  --set ipam.mode=kubernetes \
  --set kubeProxyReplacement=false \
  --set k8sServiceHost="${server_ip}" \
  --set k8sServicePort=6443 \
  --set operator.replicas=1 \
  --wait \
  --timeout 10m
kubectl -n kube-system rollout status daemonset/cilium --timeout=10m
kubectl -n kube-system rollout status deployment/cilium-operator --timeout=10m
kubectl wait --for=condition=Ready nodes --all --timeout=10m

kubectl create namespace unique --dry-run=client -o yaml | kubectl apply -f -
kubectl apply -f "${SCRIPT_DIR}/standard-storage-class.yaml"
kubectl annotate storageclass local-path \
  storageclass.kubernetes.io/is-default-class- 2>/dev/null || true

helm repo add nfs-ganesha-server-and-external-provisioner \
  https://kubernetes-sigs.github.io/nfs-ganesha-server-and-external-provisioner/ \
  --force-update >/dev/null
helm repo update nfs-ganesha-server-and-external-provisioner >/dev/null
helm upgrade --install nfs-server-provisioner \
  nfs-ganesha-server-and-external-provisioner/nfs-server-provisioner \
  --version "${NFS_SERVER_PROVISIONER_CHART_VERSION}" \
  --namespace unique \
  --set extraArgs.grace-period=0 \
  --set persistence.enabled=true \
  --set persistence.size="${NFS_STORAGE_SIZE}" \
  --set persistence.storageClass=standard \
  --set 'storageClass.mountOptions[0]=vers=4.1' \
  --set storageClass.name=gl4f-filesystem \
  --wait \
  --timeout 5m

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

helm repo add istio https://istio-release.storage.googleapis.com/charts \
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
  --values "${SCRIPT_DIR}/../kind/istio-gateway.values.yaml" \
  --wait \
  --timeout 10m
kubectl apply -f "${SCRIPT_DIR}/../kind/ezaf-gateway.yaml"

caddy_hosts="$(
  printf '%s\n' \
    "api.${base_domain}" \
    "argocd.${base_domain}" \
    "grafana.${base_domain}" \
    "harbor.${base_domain}" \
    "id.${base_domain}" \
    "litellm.${base_domain}" \
    "rabbitmq.${base_domain}" \
    "rustfs.${base_domain}" \
    "unique.${base_domain}" |
    paste -sd, -
)"
{
  if [[ -n "${CADDY_ACME_EMAIL:-}" ]]; then
    printf '{\n  email %s\n}\n\n' "${CADDY_ACME_EMAIL}"
  fi
  printf '%s {\n' "${caddy_hosts}"
  printf '  reverse_proxy 127.0.0.1:30080\n'
  printf '}\n'
} | run_ssh 'cat >/etc/caddy/Caddyfile && caddy validate --config /etc/caddy/Caddyfile && systemctl restart caddy'

helm upgrade --install argocd \
  oci://ghcr.io/argoproj/argo-helm/argo-cd \
  --version "${ARGO_CD_CHART_VERSION}" \
  --namespace unique \
  --create-namespace \
  --values "${SCRIPT_DIR}/../kind/argocd.values.yaml" \
  --wait \
  --timeout 15m
sed "s|__BASE_DOMAIN__|${base_domain}|g" \
  "${SCRIPT_DIR}/argocd.virtual-service.yaml" |
  kubectl apply -f -
kubectl apply -f "${REPOSITORY_DIR}/bootstrap.application.yaml"

printf 'Argo CD: https://argocd.%s\n' "${base_domain}"
printf 'Unique (after rollout): https://unique.%s\n' "${base_domain}"
printf 'The rollout pauses at the secrets Application.\n'
