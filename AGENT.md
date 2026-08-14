# HPE Hosted Trial

This repository deploys Unique to one HPE Private Cloud AI cluster. It keeps a
single-cluster layout and reuses compatible versions and settings from the
Unique Azure deployments without copying their tenant structure.
The current compatibility baseline is Unique `2026.32.4`.

## Layout

- `bootstrap.application.yaml` bootstraps `1-system` and `2-applications`.
- `1-system/` contains ArgoCD `ApplicationSet` inputs for cluster dependencies.
- `2-applications/` contains Unique services and their routes.
- `versions.yaml` is the image-version source for the HPE Harbor mirror.

## ArgoCD

`1-system/system.application-set.yaml` discovers every `1-system/**/app.yaml`.
System resources use sync waves `0` through `5`; application resources use
waves `6` through `10`. Each application manifest owns its chart version and
values.

Keep HPE-specific service names, secrets, ingress resources, and the
`gl4f-filesystem` storage class unless a dependent application is updated with
them. The restricted Sealed Secrets deployment requires the cluster administrator
to preinstall its CRDs and provide the `sealed-secrets-controller` service
account with namespace-only permissions in `unique`. Validate chart upgrades
with rendered manifests before syncing.

PostgreSQL, Redis, and RabbitMQ are operator-managed. CloudNativePG and the
OT-Container-Kit Redis Operator watch `unique`; the RabbitMQ Cluster Operator
runs in `unique`, depends on cert-manager, and requires Kubernetes 1.31 or
newer. Their custom resources and monitoring objects are kept beside the
corresponding `1-system/2-*` app. These operators still require their
cluster-scoped CRDs and RBAC to be permitted by the cluster administrator.
