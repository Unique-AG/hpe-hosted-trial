# Local kind cluster

Prerequisites: Docker, `kind`, `kubectl`, and Helm.

Start the cluster and install the local prerequisites:

```bash
./.local/kind/up.sh
```

The cluster context is `kind-hpe-hosted-trial`. Argo CD and the HPE system
resources use the `unique` namespace. Sealed Secrets is left for manual setup.

Access Argo CD:

```bash
kubectl -n unique port-forward svc/argocd-server 8080:443
```

Open <https://localhost:8080>. The username is `admin`; retrieve the initial
password with:

```bash
kubectl -n unique get secret argocd-initial-admin-secret \
  -o jsonpath='{.data.password}' | base64 --decode; echo
```

Sync `hpe-hosted-trial-system` in Argo CD to create the `1-system`
Applications. The generated Applications remain manual; configure Sealed
Secrets before syncing that Application.

The local Istio gateway is mapped to host ports 80 and 443; the current local
configuration routes HTTP on port 80 and does not configure TLS. Add the HPE
hostnames to `/etc/hosts` if you want to access services through the same
routes:

```text
127.0.0.1 unique.ingress.pcai0201.fr2.hpecolo.net api.ingress.pcai0201.fr2.hpecolo.net id.ingress.pcai0201.fr2.hpecolo.net minio.ingress.pcai0201.fr2.hpecolo.net harbor.ingress.pcai0201.fr2.hpecolo.net rabbitmq.ingress.pcai0201.fr2.hpecolo.net litellm.ingress.pcai0201.fr2.hpecolo.net grafana.ingress.pcai0201.fr2.hpecolo.net
```

Remove the entire local cluster with:

```bash
./.local/kind/down.sh
```
