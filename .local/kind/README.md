# Local kind cluster

Prerequisites: Docker, `kind`, `kubectl`, and Helm.

Start the cluster and install the local prerequisites:

```bash
./.local/kind/up.sh
```

The cluster context is `kind-hpe-hosted-trial`. Argo CD and the HPE system
resources use the `unique` namespace. The sealed-secrets controller is
automatically rolled out; its `secrets` Application is the manual gate. Metrics
Server is installed locally for the Istio autoscalers. The setup script also
installs `runsc` into each kind node and registers the `runsc` containerd
runtime handler used by the `gvisor` RuntimeClass.

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

The local Istio gateway is mapped to host ports 80 and 443. System services use
HTTP and `.localhost` domains directly:

```text
http://unique.localhost
http://argocd.localhost
http://api.localhost
http://id.localhost
http://rustfs.localhost/rustfs/console/
http://harbor.localhost
http://rabbitmq.localhost
http://litellm.localhost
http://grafana.localhost
```

The system manifests keep the corresponding HPE hostname in an adjacent
`# HPE:` comment for a later target change.

RustFS serves its console at `/rustfs/console/`. The local route sends that
path to the console port and sends S3 and admin API requests on the same
hostname to the API port, which lets Key Login use the configured RustFS
credentials.

The kind nodes resolve `harbor.localhost` through Docker Desktop and configure
containerd to use the registry over HTTP. Recreate clusters made before this
registry configuration was added.
Argo CD pulls OCI charts directly from the in-cluster Harbor service over HTTP.

The default `standard` StorageClass uses local-path volumes for RWO workloads.
The local `gl4f-filesystem` StorageClass is backed by the userspace NFS-Ganesha
server and external provisioner. This provides development RWX semantics for
workloads that share assistant and sandbox state without running a kernel NFS
daemon inside a kind node. Data is deleted with the cluster.

Remove the entire local cluster with:

```bash
./.local/kind/down.sh
```
