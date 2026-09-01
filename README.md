# HPE Hosted Trial

This repository deploys Unique to an HPE Private Cloud AI Kubernetes cluster
with Argo CD.

## Prerequisites

You need:

- a Kubernetes cluster with Argo CD installed in the `unique` namespace;
- a kubeconfig context that can read Secrets and Applications in `unique`;
- `kubectl`, `argocd`, `kubeseal`, `helm`, Terraform 1.5 or newer, `git`,
  `yq`, `jq`, `curl`, `rg`, `oras`, and `skopeo`;
- credentials for the source container registries; and
- DNS records for the configured ingress domains.

Argo CD must have ApplicationSet progressive syncs enabled.

## Deploy

### 1. Configure the repository

Fork this repository and create a branch for the deployment:

```bash
git clone https://github.com/<organization>/hpe-hosted-trial.git
cd hpe-hosted-trial
git checkout -b <deployment-branch>
```

Update Argo CD repository and revision references to use that fork and branch:

```bash
rg -n 'https://github.com/Unique-AG/hpe-hosted-trial|feat/upgrade-to-2026' .
```

Review the deployment-specific values:

```bash
rg -n 'storageClass|storageClassName|gl4f-filesystem|localhost|HPE:' \
  1-system 2-applications
```

Set supported RWO and RWX storage classes, replace the local hostnames with the
HPE ingress domains, and confirm that DNS resolves to the ingress endpoint.
Comments beginning with `HPE:` mark values that differ from the local test
environments.

Commit and push the configuration before syncing Argo CD.

### 2. Bootstrap Argo CD

```bash
kubectl apply -f bootstrap.application.yaml
argocd app sync argocd-bootstrap
```

Argo CD deploys the first system components and then pauses at the manual
`secrets` gate.

### 3. Prepare system secrets

Copy each required `*.secret.yaml.example` to the adjacent `*.secret.yaml` and
replace the placeholders. Plaintext `*.secret.yaml` files are ignored by Git.

Do not create
`2-applications/1-node-scope-management/node-scope-management.secret.yaml` yet;
`setup-zitadel.sh` creates it later. Database, RabbitMQ, RustFS, and LiteLLM
connection credentials are derived from system Secrets and should not be copied
into application Secrets.

Seal the Secrets with the cluster's production certificate:

```bash
./seal-secrets.sh --all
```

Review, commit, and push the generated `*.sealed-secret.yaml` files, then open
the system gate:

```bash
argocd app sync secrets
kubectl -n unique get applications.argoproj.io -w
```

Wait until the system Applications are Healthy and the
`application-secrets` Application exists. That Application is the next manual
gate and must remain OutOfSync for now.

### 4. Mirror release artifacts

Populate the HPE Harbor registry with all pinned charts and images:

```bash
./update-versions.sh --mirror
```

The command reads `versions.yaml`, authenticates to Harbor with
`harbor-password-secret`, mirrors the release, and updates runtime references.
Source-registry credentials are required when the delivery cache has not already
been populated.

Do not sync `application-secrets` or commit these changes yet. The next step
also updates tracked manifests.

### 5. Configure ZITADEL

Wait for the ZITADEL Application to be Healthy, then run:

```bash
./setup-zitadel.sh
```

The script:

- reads the first-instance machine PAT from `unique/iam-admin-pat`;
- reconciles the organization, project, roles, OIDC client, and scope-management
  machine with Terraform;
- updates the tracked ZITADEL organization ID; and
- creates the ignored node-scope-management plaintext Secret.

It stores Terraform state under the ignored `.local/zitadel-bootstrap`
directory and never writes a PAT to tracked files. Existing tracked ZITADEL IDs
are replaced with IDs from the current cluster, allowing bootstrap to be rerun
after `down.sh` destroys a previous cluster. It does not open the
`application-secrets` gate.

The default URLs are derived from `versions.yaml`. The main overrides are:

- `ZITADEL_URL` and `UNIQUE_FRONTEND_BASE_URL` for custom ingress URLs;
- `ZITADEL_TARGET_ORG_NAME` for the target organization name;
- `ZITADEL_REDIRECT_URIS` and `ZITADEL_POST_LOGOUT_REDIRECT_URIS` for
  comma-separated URI lists; and
- `ZITADEL_USE_PORT_FORWARD=true` if an ingress proxy cannot preserve ZITADEL
  provider streams.

Use `./setup-zitadel.sh --check` for a read-only check. After reviewing the
result, explicitly seal the generated Secret:

```bash
./setup-zitadel.sh --seal
```

If an existing SealedSecret already contains `ZITADEL_ROOT_ORG_ID`, rotation
must be deliberate:

```bash
./setup-zitadel.sh --seal --rotate-secret
```

### 6. Open the application gate

Review all changes and confirm that no plaintext Secret, Terraform state, or PAT
is staged:

```bash
git status --short
git diff --cached
```

Commit and push the reviewed manifests before syncing:

```bash
git add versions.yaml 1-system 2-applications
git commit -m "chore(release): configure HPE deployment"
git push
argocd app sync application-secrets
```

Argo CD then rolls out the prerequisite, core, worker, and frontend application
groups. Specialist Applications remain paused until they are explicitly synced.

### 7. Prepare the demo

Register the GLM chat model and the E5 embedding model for the company, then
configure the demo itself:

```bash
./setup-models.sh
./setup-demo.sh
```

`setup-models.sh` requires no manually supplied user token. By default it reads
the existing ZITADEL admin PAT from `unique/iam-admin-pat`, creates or reuses
the `hpe-trial-setup` machine user, and calls the application APIs with a
short-lived JWT. Its temporary machine key is revoked on exit. A protected
`UNIQUE_ACCESS_TOKEN_FILE` remains available as an explicit override.

`setup-demo.sh` reconciles the HPE theme, creates the demo user, and replaces
the two spaces node-chat creates on company bootstrap with a single space bound
to the LiteLLM-served GLM model. It resolves the ZITADEL admin token exactly as
`setup-zitadel.sh` does, and calls the application APIs with a short-lived JWT
minted for a machine user it creates on first run; that key is revoked before
the script exits.

`DEMO_USER_PASSWORD` (or `DEMO_USER_PASSWORD_FILE`, owner-only) is required the
first time, when the user is created:

```bash
DEMO_USER_PASSWORD='<password>' ./setup-demo.sh
```

Use `./setup-demo.sh --check` for a read-only report. Re-running is safe: every
step reconciles rather than recreates. `--keep-default-spaces` leaves the
bootstrap spaces in place; `--skip-theme`, `--skip-user`, and `--skip-spaces`
narrow the run. Theme assets and the HPE palette live in
[`assets/hpe/`](assets/hpe/README.md).

The space model is selected with `DEMO_SPACE_MODEL`, which defaults to the
`litellm:unique-chat-glm-5.3` alias from `1-system/7-litellm`. Note that
node-chat only offers a model in the admin *Space* form when it appears in its
`UNIQUEAI_SUPPORTED_MODELS` allowlist or in `UNIQUEAI_ALLOWED_MODELS`; to make
this deployment's alias selectable in that form, set it on node-chat:

```yaml
UNIQUEAI_ALLOWED_MODELS: "*:litellm:unique-chat-glm-5.3"
```

### 8. Verify the deployment

```bash
kubectl -n unique get applications.argoproj.io
kubectl -n unique get pods
```

Wait for the required Applications to be Synced and Healthy and confirm that no
required pod is Pending or crash-looping. Sign in through the configured Unique
domain, create a chat, and verify that the assistant responds. Also check the
API, identity provider, Harbor, and object-storage routes.

The initial ZITADEL human password is a bootstrap credential. Change it
immediately after the first login.

## Version management

`versions.yaml` is the source of truth for chart versions, image versions,
digests, and HPE Harbor destinations.

After editing it, propagate and validate references:

```bash
./update-versions.sh --update
./update-versions.sh --validate
```

Mirror OCI charts, pinned Git charts, and container images with:

```bash
./update-versions.sh --mirror
```

Runtime Argo CD manifests reference only this configuration repository, the HPE
Harbor mirror, and approved public chart repositories.

## Local testing

Kind and Hetzner test-cluster instructions are internal and documented in
[`.local/README.md`](.local/README.md).
