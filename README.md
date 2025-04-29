# hpe-hosted-trial
Deploy Unique on an HPE hosted trial

This repository contains the ArgoCD configuration for the Unique application.

* Step 1: Install ArgoCD
* Step 2: Apply the bootstrap manifest
* Step 3: Monitor Argo during deployment

The integer prefixes in the system and applications folders show the sync wave for each service.

## Sealed Secrets

To encrypt secrets, run:

```
echo -n bar | kubectl create secret generic mysecret --dry-run=client --from-file=foo=/dev/stdin -o yaml >mysecret.yaml
kubeseal --cert ./public.sealed-secrets.cert.pem -f mysecret.yaml -o yaml -w mysealedsecret.yaml -n namespace
```

There is a convenience script that will find all the secrets in the repo and encrypt them:

```
./seal-secrets.sh
```

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

The Unique platform uses a centralized approach to manage all application and service versions in a single file: `versions.yaml`. This file contains a skopeo sync configuration section for syncing images to Harbor

### Updating Versions

To update a component's version:

1. Edit the version in `versions.yaml`
2. Run the update script to propagate the change to all app.yaml files:

```bash
./update-versions.sh
```

### Syncing Images to Harbor

To sync images to Harbor:

```bash
skopeo sync --src yaml --dest docker --all versions.yaml harbor.ingress.pcai0201.fr2.hpecolo.net/library/
```
