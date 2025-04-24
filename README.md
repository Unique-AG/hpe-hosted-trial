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
