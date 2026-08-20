# hpe-hosted-trial
Deploy Unique on an HPE hosted trial

This repository contains the ArgoCD configuration for the Unique application.

* Step 1: Install ArgoCD
* Step 2: Apply the bootstrap manifest
* Step 3: Wait for the automatically synced sealed-secrets operator
* Step 4: Copy each `*.secret.yaml.example` to `*.secret.yaml`, fill the ignored copy, then encrypt it with `./seal-secrets.sh --all`; for local Kind, fetching the certificate is optional
* Step 5: Commit the generated `*.sealed-secret.yaml` files next to their applications
* Step 6: Mirror Helm charts and docker images to Harbor (see README below)
* Step 7: Manually sync `application-secrets`; the remaining applications then roll out automatically

The `rolloutStep` values in `1-system/**/app.yaml` control the ApplicationSet progressive rollout.
Application directories under `2-applications` are prefixed by rollout order:
`0-*` prerequisites and Kong bootstrap stages, `1-*` core, `2-*` workers,
`3-*` frontends, and `4-*` specialists. Each directory contains one
self-contained `app.yaml` and any service-specific secret templates.

The `2-applications` ApplicationSet is created only after every `1-system`
rollout step is healthy. Its rollout starts with the manually gated
`application-secrets` Application, which recursively applies all adjacent
`*.sealed-secret.yaml` files before Argo CD continues with prerequisites and
services.

## Sealed Secrets

For production, use the public certificate from the repository:

```
./seal-secrets.sh --all
```

For local Kind, fetching the certificate from the cluster is optional. If the
local controller uses a different key, fetch its certificate and seal in one
step:

```
./.local/kind/seal-secrets.sh --all
```

The local helper uses the current Kind controller certificate; a fresh Kind
cluster normally generates a different key from the certificate in the
repository.

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
