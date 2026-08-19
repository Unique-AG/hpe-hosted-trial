# hpe-hosted-trial
Deploy Unique on an HPE hosted trial

This repository contains the ArgoCD configuration for the Unique application.

* Step 1: Install ArgoCD
* Step 2: Apply the bootstrap manifest
* Step 3: Wait for the automatically synced sealed-secrets operator
* Step 4: In production, fetch `public.sealed-secrets.cert.pem` from the repository and encrypt the secrets with `./seal-secrets.sh --all`; for local Kind, fetching the certificate is optional
* Step 5: Manually sync only the `secrets` Application; the remaining system applications then roll out automatically
* Step 6: Mirror Helm charts and docker images to Harbor (see README below)
* Step 7: Sync the applications

The `rolloutStep` values in `1-system/**/app.yaml` control the ApplicationSet progressive rollout.

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

!WARNING: Sealed secrets in the `2-applications` folder are synced too late by ArgoCD, so the secrets are not available when the application is deployed.
To fix that you need to manually add the annotations to the sealed secrets in the `2-applications` folder.

```
annotations:
    argocd.argoproj.io/hook: PreSync
```

Re-running `seal-secrets.sh` will override the secrets and remove the annotations. Ensure they are added back after running the script.

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
