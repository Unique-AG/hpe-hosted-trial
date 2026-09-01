#!/usr/bin/env bash
set -euo pipefail

CLUSTER_NAME="${KIND_CLUSTER_NAME:-hpe-hosted-trial}"

quiesce_node() {
  local node="$1"

  if [[ "$(docker inspect --format '{{.State.Running}}' "${node}")" != "true" ]]; then
    return
  fi

  if ! docker exec "${node}" sh -c '
    set -eu
    timeout 30s systemctl stop kubelet
    timeout 60s systemctl stop containerd
    awk "\$3 == \"nfs\" || \$3 == \"nfs4\" { print \$2 }" /proc/mounts |
      sort -r |
      while IFS= read -r mount_point; do
        umount -fl "$mount_point"
      done
  '; then
    printf 'failed to quiesce %s; restart Docker Desktop, then rerun this script\n' "${node}" >&2
    exit 1
  fi
}

workers=()
control_planes=()
while IFS= read -r node; do
  case "$(docker inspect --format '{{ index .Config.Labels "io.x-k8s.kind.role" }}' "${node}")" in
    worker) workers+=("${node}") ;;
    control-plane) control_planes+=("${node}") ;;
  esac
done < <(
  docker ps -a \
    --filter "label=io.x-k8s.kind.cluster=${CLUSTER_NAME}" \
    --format '{{.Names}}'
)

if ((${#workers[@]} > 0)); then
  for node in "${workers[@]}"; do
    quiesce_node "${node}"
    docker rm -f -v "${node}"
  done
fi

if ((${#control_planes[@]} > 0)) &&
  kubectl --context "kind-${CLUSTER_NAME}" --request-timeout=5s get namespace unique >/dev/null 2>&1; then
  kubectl --context "kind-${CLUSTER_NAME}" \
    --namespace unique \
    delete statefulset nfs-server-provisioner \
    --ignore-not-found \
    --wait=true \
    --timeout=60s
fi

if ((${#control_planes[@]} > 0)); then
  for node in "${control_planes[@]}"; do
    quiesce_node "${node}"
  done
fi

if ((${#control_planes[@]} > 0)); then
  kind delete cluster --name "${CLUSTER_NAME}"
fi
