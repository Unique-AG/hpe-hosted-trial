# HPE Hosted Trial

Deploy Unique to an HPE Private Cloud AI Kubernetes cluster with Argo CD.

## Prerequisites

Before starting, provide:

- A Kubernetes cluster with Argo CD installed in the `unique` namespace
- A Harbor registry reachable from the cluster and the deployment workstation
- `kubectl`, `argocd`, `kubeseal`, `helm`, `git`, `yq`, `rg`, `oras`, and
  `skopeo`
- Credentials for every source registry and the destination Harbor registry
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
kubectl create namespace unique --dry-run=client -o yaml | kubectl apply -f -
kubectl apply -f bootstrap.application.yaml
```

Argo CD automatically deploys the `1-system` applications until it reaches the
manual `secrets` gate.

### 4. Seal and sync the system secrets

Copy every required `*.secret.yaml.example` file to the adjacent
`*.secret.yaml`, then fill in the real values. Plaintext `*.secret.yaml` files
are ignored by Git.

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

Do not continue until the system applications are Healthy and the
`application-secrets` Application exists. Its existence confirms that the
system rollout reached the final `secret-gate` step.

### 6. Mirror artifacts and sync application secrets

Authenticate the tools against the destination Harbor registry:

```bash
oras login <harbor-domain>
skopeo login <harbor-domain>
helm registry login <harbor-domain>
```

Mirror all pinned OCI charts, Git-hosted charts, and container images:

```bash
./update-versions.sh --mirror
```

The command records mirrored chart digests and updates runtime references.
Commit and push those changes before opening the application gate:

```bash
git add versions.yaml 1-system 2-applications
git commit -m "chore(release): record mirrored artifacts"
git push
argocd app sync application-secrets
```

The manual sync applies application SealedSecrets at sync wave 0. After they
become healthy, it creates the `applications` ApplicationSet at sync wave 1.
No downstream Application exists before this point, preventing Argo CD from
querying Harbor before mirroring is complete.

### 7. Wait for the application rollout

Watch Argo CD and the workloads:

```bash
kubectl -n unique get applications.argoproj.io -w
kubectl -n unique get pods -w
```

Wait for the automatically enabled prerequisite, core, worker, and frontend
applications to become Synced and Healthy. Specialist applications are
intentionally paused and must be synced manually when required.

### 8. Test Unique

Verify that no required pod is Pending or crash-looping:

```bash
kubectl -n unique get pods
```

Open the configured Unique domain, sign in, create a chat, and confirm that the
assistant returns a response. Also verify the API, identity provider, Harbor,
and object-storage routes used by the deployment.

## Local Kind

For local Kind, fetch the current controller certificate and seal in one step:

```bash
./.local/kind/seal-secrets.sh --all
```

A fresh Kind cluster normally generates a different key from the production
certificate stored in the repository.

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

Runtime Argo CD manifests only reference this configuration repository, the
HPE Harbor mirror, and approved public third-party chart repositories.

To validate the local release snapshot without changing files:

```bash
./update-versions.sh --validate
```
