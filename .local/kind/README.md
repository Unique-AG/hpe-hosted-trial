# Local kind cluster

Prerequisites: Docker, `kind`, `kubectl`, and Helm.

Start the cluster and install the local prerequisites:

```bash
./.local/kind/up.sh
```

The cluster context is `kind-hpe-hosted-trial`. Argo CD and the HPE system
resources use the `unique` namespace. The sealed-secrets controller is
automatically rolled out; its `secrets` Application is the manual gate. Metrics
Server is installed locally for the Istio autoscalers.

Access Argo CD:

Open <http://argocd.localhost>. The username is `admin`; retrieve the initial
password with:

```bash
kubectl -n unique get secret argocd-initial-admin-secret \
  -o jsonpath='{.data.password}' | base64 --decode; echo
```

The bootstrap Application is configured for automated sync. The ApplicationSet
automatically syncs the sealed-secrets controller, pauses at the `secrets`
Application, and resumes the remaining health-gated rollout after that
Application is manually synced and Healthy.

The local Istio gateway is mapped to host ports 80 and 443; the current local
configuration routes HTTP on port 80 and does not configure TLS. Add the HPE
hostnames to `/etc/hosts` if you want to access services through the same
production routes. The local setup also applies routing-only `.localhost`
aliases:

```text
http://unique.localhost
http://argocd.localhost
http://api.localhost
http://id.localhost
http://rustfs.localhost
http://harbor.localhost
http://rabbitmq.localhost
http://litellm.localhost
http://grafana.localhost
```

The aliases rewrite the upstream authority to the corresponding production
hostname so existing Istio and Kong routes continue to match. Application
configuration remains unchanged, so redirects, OIDC URLs, and generated links
can still use the production `https` hostnames.

```text
127.0.0.1 unique.ingress.pcai0201.fr2.hpecolo.net api.ingress.pcai0201.fr2.hpecolo.net id.ingress.pcai0201.fr2.hpecolo.net rustfs.ingress.pcai0201.fr2.hpecolo.net harbor.ingress.pcai0201.fr2.hpecolo.net rabbitmq.ingress.pcai0201.fr2.hpecolo.net litellm.ingress.pcai0201.fr2.hpecolo.net grafana.ingress.pcai0201.fr2.hpecolo.net
```

Remove the entire local cluster with:

```bash
./.local/kind/down.sh
```
