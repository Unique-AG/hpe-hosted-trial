#!/usr/bin/env bash
set -euo pipefail

CLUSTER_NAME="${KIND_CLUSTER_NAME:-hpe-hosted-trial}"

if kind get clusters 2>/dev/null | awk -v name="${CLUSTER_NAME}" '$0 == name { found = 1 } END { exit !found }'; then
  kind delete cluster --name "${CLUSTER_NAME}"
fi
