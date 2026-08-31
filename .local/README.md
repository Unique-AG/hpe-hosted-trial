# Local test environments

This directory contains internal tooling for testing the HPE deployment on
Kind or an ephemeral Hetzner Cloud server. These environments are not production
configurations.

Run all commands from the repository root.

## Common workflow

The public wrapper scripts provide the same lifecycle for both providers:

```bash
./up.sh kind
# or
HCLOUD_TOKEN='<token>' ./up.sh hetzner
```

Configure the deployment hostname after the cluster is ready:

```bash
./set-hostname.sh .localhost
# Hetzner example; use the suffix printed by up.sh:
./set-hostname.sh .192.0.2.10.sslip.io
```

Then download the new cluster's Sealed Secrets certificate and reseal the
plaintext Secrets:

```bash
./seal-secrets.sh --all
```

`up.sh` applies `bootstrap.application.yaml`. Argo CD automatically starts the
system rollout and pauses at the manual `secrets` Application. Commit and push
hostname and SealedSecret changes before syncing that gate:

```bash
argocd app sync secrets
```

A recreated cluster has a new sealing key. `.hostname` is ignored local state
used by `set-hostname.sh`; changes made to deployment manifests must still be
reviewed and committed.

Remove a cluster with:

```bash
./down.sh kind
HCLOUD_TOKEN='<token>' ./down.sh hetzner
```

`./down.sh` without a provider selects Hetzner when Hetzner state exists and
Kind otherwise. After the provider teardown succeeds, it also removes the
cluster-bound `.local/zitadel-bootstrap` Terraform state and
`.local/unique-admin.token`. This prevents credentials and ZITADEL object IDs
from a deleted cluster being reused by its replacement. The reusable artifact
mirror cache and `.hostname` configuration bookkeeping are retained.

## Kind

### Prerequisites

Install Docker, Kind, `kubectl`, and Helm.

### Start and access the cluster

```bash
./up.sh kind
```

The kubeconfig context is `kind-hpe-hosted-trial`. Argo CD and HPE system
resources use the `unique` namespace.

Open <http://argocd.localhost>. The username is `admin`; retrieve its initial
password with:

```bash
kubectl -n unique get secret argocd-initial-admin-secret \
  -o jsonpath='{.data.password}' | base64 --decode; echo
```

Available local routes are:

```text
http://unique.localhost
http://argocd.localhost
http://api.localhost
http://id.localhost
http://rustfs.localhost/rustfs/console/
http://harbor.localhost
http://rabbitmq.localhost
http://litellm.localhost
http://grafana.localhost
```

The setup installs Cilium, Metrics Server, Istio, Argo CD, the Sealed Secrets
controller, and the `runsc` runtime used by the `gvisor` RuntimeClass. The Istio
gateway is exposed on host ports 80 and 443.

The `standard` StorageClass uses local-path volumes for RWO workloads.
`gl4f-filesystem` uses an NFS-Ganesha server and external provisioner to provide
development RWX semantics. All data is deleted with the cluster.

Kind nodes reach `harbor.localhost` through Docker Desktop and use plain HTTP.
Argo CD also pulls charts from the in-cluster Harbor service over HTTP. Recreate
clusters made before this registry configuration was introduced.

RustFS serves its console at `/rustfs/console/`; S3 and admin API requests on
the same hostname are routed to its API port.

Provider-specific scripts and configuration live in `.local/kind/`. Prefer the
root wrapper scripts unless debugging cluster setup itself.

## Hetzner

### Prerequisites

Provide:

- a Hetzner Cloud API token in `HCLOUD_TOKEN`;
- an SSH key pair (defaults to `~/.ssh/id_rsa` and `~/.ssh/id_rsa.pub`); and
- `curl`, `jq`, SSH tools, Helm, `kubectl`, and OpenSSL.

Override the SSH key paths with `HETZNER_SSH_PUBLIC_KEY_FILE` and
`HETZNER_SSH_PRIVATE_KEY_FILE` when needed.

### Start and access the cluster

```bash
export HCLOUD_TOKEN='<token>'
./up.sh hetzner
```

By default this provisions one amd64 CCX43 server in `fsn1`, then installs k3s,
Cilium, gVisor, Istio, Argo CD, NFS-backed RWX storage, and Caddy-managed HTTPS.
k3s supplies Metrics Server. The script prints the generated `sslip.io` domain
and Argo CD URL.

Hetzner state, kubeconfig, known-hosts data, and Harbor's private CA are kept in
`.local/hetzner/state/`. The state is ignored by Git and must be protected.
Running `./up.sh hetzner` again reuses the recorded server.

The server's local disk and this configuration are intended only for ephemeral
trials. Public ZITADEL access makes generated IAM-admin credentials especially
sensitive; protect and rotate them. The placeholder NVIDIA predictor URLs are
not rewritten automatically, so configure reachable model endpoints before
inference testing.

Delete all provisioned resources when finished:

```bash
HCLOUD_TOKEN='<token>' ./down.sh hetzner
```

## Artifact mirror cache

`./update-versions.sh --mirror` caches downloaded images, OCI charts, and
packaged Git charts in `.local/mirror-cache`. Recreating a test cluster and
running the command again restores unchanged artifacts without contacting their
source registries. Set `MIRROR_CACHE_DIR` to use another directory, or delete
the cache to force a fresh download.

For Kind, workstation mirror clients use plain HTTP to `harbor.localhost` and
store artifacts in `library`. Argo CD uses the in-cluster Harbor service over
HTTP.

For Hetzner, workstation mirroring uses the public HTTPS route. Argo CD uses
`harbor.unique.svc.cluster.local` over HTTPS with the private CA created during
cluster setup.

The cache includes the proprietary Unique images for the release and can be
transferred with a delivery bundle. This lets a customer populate
`library/images` without access to the Unique Azure registries. Public images
continue to use their public sources.

## Hosted models for test environments

Kind and Hetzner use Together AI when on-premise inference is unavailable.
LiteLLM routes are defined in `1-system/7-litellm/litellm.values.yaml`:

- `unique-chat-glm-5.3` uses `zai-org/GLM-5.3`;
- `unique-embedding-e5` uses
  `intfloat/multilingual-e5-large-instruct` with 1024 dimensions.

Both routes read `TOGETHERAI_API_KEY` from the `litellm` Secret. Add the key to
the ignored plaintext Secret without putting it in shell history, then seal
only that Secret:

```bash
read -rsp 'Together AI API key: ' TOGETHERAI_API_KEY; echo
TOGETHERAI_API_KEY="$TOGETHERAI_API_KEY" yq -i \
  '.stringData.TOGETHERAI_API_KEY = strenv(TOGETHERAI_API_KEY)' \
  1-system/2-secrets/litellm/litellm.secret.yaml
unset TOGETHERAI_API_KEY
./seal-secrets.sh litellm
```

Review, commit, and push the SealedSecret. Do not automatically open the
`application-secrets` gate.

After LiteLLM, chat, and ingestion are Healthy, store a user token with
`chat.admin.all` and ingestion administration access in a mode-0600 file:

```bash
install -m 600 /dev/null .local/unique-admin.token
read -rsp 'Unique admin token: ' TOKEN; echo
printf '%s' "$TOKEN" > .local/unique-admin.token
unset TOKEN
UNIQUE_ACCESS_TOKEN_FILE=.local/unique-admin.token \
  ./setup-models.sh --update-assistants
```

`setup-models.sh` idempotently registers the chat model group, selects E5 for
the token's company, and can update all company assistants. Use `--check` for a
read-only check.

Changing an embedding model requires re-embedding existing content. Run this
only during an approved test window because it can saturate ingestion:

```bash
UNIQUE_ACCESS_TOKEN_FILE=.local/unique-admin.token \
  ./setup-models.sh --reembed
```

## Repository checks

The internal checks can be run independently:

```bash
./.local/test-application-config.sh
./.local/test-hetzner-deployment.sh
./.local/test-proprietary-images.sh
./.local/test-update-versions-cache.sh
```

They validate repository configuration and scripts; they do not replace an
end-to-end deployment test.
