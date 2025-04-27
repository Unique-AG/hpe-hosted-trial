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

## Zitadel Superuser

The Zitadel superuser is used to bootstrap the Zitadel instance. Create a private key like this:

```
# Generate the private key
openssl genrsa -out superuser.pem 2048

# Extract the public key from the private key
openssl rsa -in superuser.pem -pubout -out superuser.pub

# Encode the public key in base64
cat superuser.pub | base64
cat superuser.pem | base64
```

Paste the values into the secrets.

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
