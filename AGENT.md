# HPE Hosted Trial

This repository deploys Unique to one HPE Private Cloud AI cluster. It keeps a
single-cluster layout and reuses compatible versions and settings from the
Unique Azure deployments without copying their tenant structure.
The current compatibility baseline is Unique `2026.32.4`.

## Layout

- `bootstrap.application.yaml` bootstraps `1-system`; the `2-applications`
  source remains commented until that layer is enabled.
- `1-system/` contains ArgoCD `ApplicationSet` inputs for cluster dependencies.
- `2-applications/` contains Unique services and their routes.
- `versions.yaml` is the image-version source for the HPE Harbor mirror.

## ArgoCD

`1-system/system.application-set.yaml` discovers every `1-system/**/app.yaml`
and rolls them out with health-gated progressive syncs. The generated
Applications use named rollout steps: `sealed-secrets`, `secrets`,
`gateway-api`, `operators`, `infrastructure`, `system-services`, and
`platform-services`.
`sealed-secrets` is automatically synced, while `secrets` is a manual gate
because sealed values must be prepared before the remaining system rollout.
The Sealed Secrets chart runs in `unique` with its standard CRD, ServiceAccount,
and cluster RBAC resources. The local Argo CD install enables progressive syncs
in `.local/kind/argocd.values.yaml`; the target Argo CD installation must
enable the same `applicationsetcontroller.enable.progressive.syncs` parameter.

Keep HPE-specific service names, secrets, ingress resources, and the
`gl4f-filesystem` storage class unless a dependent application is updated with
them. Validate chart upgrades with rendered manifests before syncing.

PostgreSQL, Redis, and RabbitMQ are operator-managed. CloudNativePG and the
OT-Container-Kit Redis Operator watch `unique`; the RabbitMQ Cluster Operator
runs in `unique`, depends on cert-manager, and requires Kubernetes 1.31 or
newer. Their custom resources and monitoring objects are kept beside the
corresponding `1-system/2-*` app. These operators still require their
cluster-scoped CRDs and RBAC to be permitted by the cluster administrator.
