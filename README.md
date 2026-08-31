# HPE Hosted Trial

Deploy Unique to an HPE Private Cloud AI Kubernetes cluster with Argo CD.

## Prerequisites

Before starting, provide:

- A Kubernetes cluster with Argo CD installed in the `unique` namespace, and a
  kubeconfig context with read access to `unique` Secrets and Applications
- `kubectl`, `argocd`, `kubeseal`, `helm`, `terraform` (1.5+), `git`, `yq`,
  `jq`, `curl`, `rg`, `oras`, and `skopeo`
- Credentials for every source registry
- Access to `charts.external-secrets.io` and `ghcr.io/external-secrets`
- DNS records for the configured ingress domains

## Deployment

### 1. Fork and configure the repository

Fork this repository, clone the fork, and create the deployment branch:

```bash
git clone https://github.com/<organization>/hpe-hosted-trial.git
cd hpe-hosted-trial
git checkout -b <deployment-branch>
```

Replace repository and revision references so Argo CD reads from the fork and
deployment branch:

```bash
rg -n 'https://github.com/Unique-AG/hpe-hosted-trial|feat/upgrade-to-2026' .
```

Commit and push every deployment change before syncing Argo CD.

### 2. Configure storage and ingress

Review every storage class and domain reference:

```bash
rg -n 'storageClass|storageClassName|gl4f-filesystem|localhost|HPE:' \
  1-system 2-applications
```

Set RWO and RWX storage classes supported by the target cluster. Replace all
local domains with the HPE ingress domains and ensure their DNS records resolve
to the ingress endpoint. Lines prefixed with `HPE:` identify values that differ
between local Kind and HPE.

Commit and push the configuration.

### 3. Bootstrap the system rollout

Apply the bootstrap Application:

```bash
kubectl apply -f bootstrap.application.yaml
argocd app sync argocd-bootstrap
```

Argo CD automatically deploys the `1-system` applications until it reaches the
manual `secrets` gate.

### 4. Seal and sync the system secrets

Copy every required `*.secret.yaml.example` file to the adjacent
`*.secret.yaml`, then fill in the real values. Leave
`2-applications/1-node-scope-management/node-scope-management.secret.yaml.example`
un-copied; `setup-zitadel.sh` creates and populates that ignored file after the
ZITADEL first-instance PAT is available. Plaintext `*.secret.yaml` files are
ignored by Git.

Application database, RabbitMQ, RustFS, and LiteLLM credentials are generated
automatically from their system Secrets. Do not duplicate those values in
application secret files.

Seal all secrets with the production certificate:

```bash
./seal-secrets.sh --all
```

Review, commit, and push the generated `*.sealed-secret.yaml` files. Then open
the first gate:

```bash
argocd app sync secrets
```

### 5. Wait for `1-system`

Watch the system rollout:

```bash
kubectl -n unique get applications.argoproj.io -w
```

Do not continue until the preceding system applications are Healthy and the
`application-secrets` Application exists. All application entries are generated
at this point, but the application rollout remains paused at the OutOfSync
`application-secrets` gate. The `connection-secrets` Application derives
application and LiteLLM connection Secrets during the infrastructure rollout.

### 6. Mirror artifacts

Populate the HPE Harbor mirror before bootstrapping the application references.
The mirror script authenticates its tools against the destination Harbor using
`harbor-password-secret`. When initially building the delivery cache, the
operator also needs credentials for the private source registries referenced by
`versions.yaml`.

Mirror all pinned OCI charts, Git-hosted charts, and container images:

```bash
./update-versions.sh --mirror
```

The command records mirrored chart digests and updates runtime references.
For local Kind, the mirror clients use plain HTTP for the in-cluster Harbor
exposed at `harbor.localhost` and store artifacts in its `library` project.
Argo CD pulls charts through `harbor.unique.svc.cluster.local`: Kind uses HTTP,
while Hetzner provisions a private CA and uses HTTPS for this cluster-internal
connection. Only workstation-to-Harbor mirroring uses the public Hetzner route.
Downloaded images and OCI charts, along with packaged Git charts, are cached in
the git-ignored `.local/mirror-cache` directory. After recreating the Kind
cluster, the same command restores artifacts from this cache without contacting
their source registries. Set `MIRROR_CACHE_DIR` to use another cache location,
or remove the cache directory to force a fresh download.
The cache contains the complete proprietary Unique image set for the release.
It can be transferred with the deployment bundle so the customer can populate
`library/images` without access to Unique Azure registries. Public images remain
configured to pull from their public sources.

Do not sync `application-secrets` or commit the mirror changes yet; the next
step updates the ZITADEL-dependent manifests before the reviewed commit.

### 7. Bootstrap ZITADEL operator resources

Wait for the ZITADEL Application to be Healthy and for the
`application-secrets` Application to exist as the closed manual gate. The
pinned ZITADEL Helm chart preserves the initial `root@cluster-iam.localhost`
human console user and also creates the `iam-admin` first-instance machine. The
initial human password is a bootstrap credential and must be changed immediately
after the first login; retain that required password-change behavior. The
machine PAT is kept in `unique/iam-admin-pat` under key `pat`.

Run the bootstrap from the repository root:

```bash
./setup-zitadel.sh
```

The script derives `https://id.<configured-domain>` and
`https://unique.<configured-domain>` from `versions.yaml`. Set
`ZITADEL_URL` and/or `UNIQUE_FRONTEND_BASE_URL` for a different ingress. The
OIDC redirect and post-logout defaults are the four deployed frontend paths
(`/chat`, `/admin`, `/knowledge-upload`, and `/theme`); override either list
with a comma-separated `ZITADEL_REDIRECT_URIS` or
`ZITADEL_POST_LOGOUT_REDIRECT_URIS` value. Set `ZITADEL_TARGET_ORG_NAME` to
change the default `HPE Hosted Trial` target organization.

OIDC `dev_mode` defaults to `false` for HTTPS and `true` only for an HTTP/local
endpoint. Set `ZITADEL_OIDC_DEV_MODE=true|false` only when an explicit override
is reviewed. The Hetzner Caddy route preserves h2c for ZITADEL provider gRPC
calls, so the script uses the external ingress by default. If an environment's
proxy terminates provider streams, set `ZITADEL_USE_PORT_FORWARD=true` to open a
temporary local h2c port-forward while retaining the external Host used for
instance selection. Use `ZITADEL_ACCESS_TOKEN` or a mode-restricted
`ZITADEL_ACCESS_TOKEN_FILE` only when the Kubernetes Secret is unavailable.
Terraform state and its `TF_DATA_DIR` are kept below the ignored
`.local/zitadel-bootstrap` directory with restrictive permissions; the ignored
plaintext node-scope-management Secret is mode 0600. The script patches runtime
placeholders and writes `ZITADEL_ROOT_ORG_ID` and the generated `ZITADEL_PAT`
only to that ignored Secret and restrictive Terraform state; it never prints or
writes a PAT to tracked files. It refuses to continue if exact-name duplicates
or missing state could create duplicate managed resources.

To inspect an already bootstrapped deployment without applying, patching, or
sealing anything, run:

```bash
./setup-zitadel.sh --check
```

Review the Terraform result and the generated ignored plaintext Secret. Then
explicitly authorize sealing only `node-scope-management`:

```bash
./setup-zitadel.sh --seal
```

The existing tracked `node-scope-management.sealed-secret.yaml` is a stale
one-key SealedSecret, so `--seal` explicitly permits replacing it to add the
missing `ZITADEL_ROOT_ORG_ID`. If a SealedSecret already contains
`ZITADEL_ROOT_ORG_ID`, `--seal` refuses to rotate it; use
`./setup-zitadel.sh --seal --rotate-secret` only after a separately reviewed,
deliberate rotation. `--rotate-secret` requires `--seal`. Neither mode syncs or
opens the `application-secrets` Argo CD gate. The generated PAT is never
printed; it remains only in the ignored plaintext Secret and Terraform state.

### 8. Review, commit, push, and sync application secrets

Review the tracked manifest, Terraform, mirror, and SealedSecret changes. Do
not add the ignored plaintext node-scope-management Secret or any Terraform
state, and verify that no PAT appears in the staged diff. Commit and push the
reviewed changes before opening the application gate:

```bash
git add versions.yaml 1-system 2-applications setup-zitadel.sh terraform README.md AGENT.md .gitignore .local/test-application-config.sh
git commit -m "chore(release): bootstrap HPE ZITADEL"
git push
argocd app sync application-secrets
```

The manual sync applies the application SealedSecrets. After they become
healthy, the existing `applications` ApplicationSet advances from the secrets
gate and progressively syncs the remaining application groups.

### 9. Wait for the application rollout

Watch Argo CD and the workloads:

```bash
kubectl -n unique get applications.argoproj.io -w
kubectl -n unique get pods -w
```

Wait for the automatically enabled prerequisite, core, worker, and frontend
applications to become Synced and Healthy. Specialist applications are
intentionally paused and must be synced manually when required.

### 10. Test Unique

Verify that no required pod is Pending or crash-looping:

```bash
kubectl -n unique get pods
```

Open the configured Unique domain, sign in, create a chat, and confirm that the
assistant returns a response. Also verify the API, identity provider, Harbor,
and object-storage routes used by the deployment.

## Local trial clusters

The cluster lifecycle has the same four commands for Kind and Hetzner:

```bash
# Create the cluster and install Cilium, storage, metrics-server, Istio and Argo CD.
./up.sh kind                 # reports http://argocd.localhost
# or:
export HCLOUD_TOKEN='<token>'
./up.sh hetzner              # reports the public https://argocd.<ip>.sslip.io URL

# Configure every deployment hostname. The leading dot is optional.
./set-hostname.sh .localhost
# For Hetzner, use the suffix reported by up.sh, for example:
./set-hostname.sh .192.0.2.10.sslip.io

# Download this cluster's Sealed Secrets certificate and reseal secrets.
./seal-secrets.sh --all

# Remove the cluster. The provider is auto-detected, or may be explicit.
./down.sh
./down.sh kind
./down.sh hetzner
```

`up.sh` applies the bootstrap Application; the rollout pauses at the manually
synced `secrets` Application. Commit and push hostname and sealed-secret changes
before opening that gate. A fresh cluster has a new sealing key. `.hostname` is
ignored local state used by `set-hostname.sh` to remember which suffix it should
replace; the resulting deployment-file changes are what should be committed.

The Hetzner option provisions one amd64 CCX43 server with k3s, Cilium, gVisor,
Istio, Argo CD and Caddy-managed HTTPS. It uses the metrics-server component
packaged and managed by k3s. Its state and kubeconfig are kept under the ignored
`.local/hetzner/state` directory. The local disk is intended for an
ephemeral trial. Protect and rotate the generated IAM-admin credentials because
the ZITADEL endpoint is public. The placeholder NVIDIA predictor URLs are
intentionally not rewritten; configure reachable model endpoints before testing
inference.

## Use custom models with Unique

Most custom model configurations are stored in environment variables and configured via LiteLLM. However you need to ensure, that the 
default fallback model for each assistant is set to a custom litellm model as well, or it will try to use OpenAI which is not available on premise. Use this GraphQL request to update each assistant:

1. Copy the JWT from the browser console network tab. Use it as a Bearer token in the following GraphQL request.
2. Execute the following GraphQL mutation against the Unique API endpoint `https://{api-domain}/chat/graphql`:

```
mutation UpdateAssistant {
    updateAssistant(
        id: "{assistant-id}"
        input: { languageModel: "litellm:{model-name}" }
    ) {
        id
        name
        languageModel
        subtitle
        title
    }
}
```


## Version Management

The Unique platform uses a centralized approach to manage all application and service versions in a single file: `versions.yaml`. This file contains the source chart digests, runtime images, and HPE Harbor destinations for the release snapshot.

### Updating Versions

To update a component's version:

1. Edit the chart or image entry in `versions.yaml`
2. Run the update script to validate and propagate chart references:

```bash
./update-versions.sh --update
```

### Mirroring Artifacts to Harbor

To mirror OCI Helm charts and docker images, and to package pinned Git charts
with their dependencies into Harbor:

```bash
./update-versions.sh --mirror
```

The mirror cache defaults to `.local/mirror-cache`. Cache entries are reused
while their configured source, version, digest, or Git revision remains
unchanged.

Runtime Argo CD manifests only reference this configuration repository, the
HPE Harbor mirror, and approved public third-party chart repositories.

To validate the local release snapshot without changing files:

```bash
./update-versions.sh --validate
```
