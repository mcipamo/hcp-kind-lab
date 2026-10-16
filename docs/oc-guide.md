# Working with `oc` in the lab

Every cluster in the lab is vanilla Kubernetes, and `oc` is a superset of `kubectl`, so you can
drive both sides of the architecture with the tool you already use on OpenShift. Every command
on this page was tested against the lab with `oc` 4.22.

Load the lab environment first (once per terminal):

```bash
source env.sh
```

Then point `oc` at the side you want:

```bash
export KUBECONFIG=$LAB_ROOT/kubeconfig/mgmt.kubeconfig       # control plane side (management cluster)
export KUBECONFIG=$LAB_ROOT/kubeconfig/tenant-a.kubeconfig   # data plane side (hosted cluster tenant-a)
```

You are already authenticated through the kubeconfig's client certificate, so `oc login` is
not needed (and does not apply).

Tip: keep one terminal on each side. Break something on one, watch the other.

On Linux, `podman` commands in this guide need `sudo` (the lab runs rootful podman).

---

## Control plane side: the management cluster

This is the SRE view. Hosted control planes are ordinary pods here.

### Hosted clusters

| What | Command |
|---|---|
| List hosted clusters (≈ `oc get hostedcluster -A`) | `oc get tcp -A` |
| Status, conditions and endpoint of one | `oc describe tcp tenant-a -n clusters-tenant-a` |
| Its full spec | `oc get tcp tenant-a -n clusters-tenant-a -o yaml` |
| Switch into its namespace | `oc project clusters-tenant-a` |

### Control plane pods

| What | Command |
|---|---|
| Control plane pod + etcd, and the node each runs on | `oc get pods -n clusters-tenant-a -o wide` |
| Container names inside the control plane pod | `oc get pod -n clusters-tenant-a -l kamaji.clastix.io/name=tenant-a -o jsonpath='{.items[0].spec.containers[*].name}'` |
| kube-apiserver logs | `oc logs -n clusters-tenant-a deploy/tenant-a -c kube-apiserver --tail=50` |
| controller-manager logs | `oc logs -n clusters-tenant-a deploy/tenant-a -c kube-controller-manager --tail=50` |
| scheduler logs | `oc logs -n clusters-tenant-a deploy/tenant-a -c kube-scheduler --tail=50` |
| konnectivity-server logs | `oc logs -n clusters-tenant-a deploy/tenant-a -c konnectivity-server --tail=50` |
| etcd logs | `oc logs -n clusters-tenant-a tenant-a-etcd-0 --tail=50` |
| Follow the operator (≈ hypershift-operator) | `oc logs -n kamaji-system deploy/kamaji -f` |
| Events in a control plane namespace | `oc get events -n clusters-tenant-a --sort-by=.lastTimestamp` |
| Services: LB for workers, NodePort for you | `oc get svc -n clusters-tenant-a` |
| Certificates and kubeconfigs | `oc get secrets -n clusters-tenant-a` |

### Talking to a tenant's etcd

Kamaji turns on **etcd RBAC**. Each tenant's API server authenticates with its own client
certificate and only sees its own key prefix, so the etcd pod's server certificate cannot read data.
In addition, the etcd image has no shell, so `oc rsh` fails. `scripts/etcdctl.sh` starts a
short-lived pod with the `root` client certificate:

```bash
./scripts/etcdctl.sh tenant-a endpoint status -w table
./scripts/etcdctl.sh tenant-a user list                          # root + one user per tenant
./scripts/etcdctl.sh tenant-a get / --prefix --keys-only --limit 20
```

Every Kubernetes object of the tenant is stored under `/<tenant-uuid>/...`. Plain `oc exec` works
for commands that need no permissions, such as `oc exec -n clusters-tenant-a tenant-a-etcd-0 -- etcdctl version`.

### Management nodes

| What | Command |
|---|---|
| Nodes, and which ones host control planes | `oc get nodes -L hypershift.openshift.io/control-plane` |
| CPU / memory per node | `oc adm top nodes` |
| CPU / memory of every hosted control plane | `oc adm top pods -A \| grep clusters-` |
| Shell on a management node | `oc debug node/hcp-mgmt-worker2 --image=docker.io/library/busybox:1.37` then `chroot /host` |
| See a hosted kube-apiserver as a container on that node | `oc debug node/hcp-mgmt-worker2 --image=docker.io/library/busybox:1.37 -- chroot /host crictl ps --name kube-apiserver` |

### Changing things

| What | Command |
|---|---|
| Control plane HA (2 replicas) | `oc -n clusters-tenant-a patch tcp tenant-a --type merge -p '{"spec":{"controlPlane":{"deployment":{"replicas":2}}}}'` |
| Upgrade the control plane | `oc -n clusters-tenant-a patch tcp tenant-a --type merge -p '{"spec":{"kubernetes":{"version":"v1.36.4"}}}'` |
| Watch the rollout | `oc -n clusters-tenant-a rollout status deploy/tenant-a` |
| Take the API down (workloads keep running) | `oc -n clusters-tenant-a scale deploy tenant-a --replicas=0` |

---

## Data plane side: the hosted cluster

This is the customer view. Point `KUBECONFIG` at `tenant-a.kubeconfig`, or prefix any `kubectl`
command with `hkubectl tenant-a` instead.

### Nodes

| What | Command |
|---|---|
| Nodes, IPs, kubelet versions | `oc get nodes -o wide` |
| Which NodePool each node belongs to | `oc get nodes -L hypershift.openshift.io/nodePool` |
| Node details (capacity, conditions, pods) | `oc describe node tenant-a-worker-1` |
| CPU / memory | `oc adm top nodes` |
| Cordon / uncordon | `oc adm cordon tenant-a-worker-1` / `oc adm uncordon tenant-a-worker-1` |
| Drain | `oc adm drain tenant-a-worker-1 --ignore-daemonsets --delete-emptydir-data` |
| Shell on the node | `oc debug node/tenant-a-worker-1 --image=docker.io/library/busybox:1.37` then `chroot /host` |
| kubelet logs | `oc debug node/tenant-a-worker-1 --image=docker.io/library/busybox:1.37 -- chroot /host journalctl -u kubelet -n 50 --no-pager` |
| Containers on the node | `oc debug node/tenant-a-worker-1 --image=docker.io/library/busybox:1.37 -- chroot /host crictl ps` |
| kubelet health through the API | `oc get --raw /api/v1/nodes/tenant-a-worker-1/proxy/healthz` |

Pass `--image` to `oc debug node`. The default OpenShift support-tools image is not available
outside OpenShift.

### Pods and workloads

| What | Command |
|---|---|
| Everything running | `oc get pods -A -o wide` |
| System pods (no apiserver or etcd here) | `oc get pods -n kube-system` |
| Deploy a test app | `oc create deployment hello --image=docker.io/library/nginx:alpine --replicas=2` |
| Logs | `oc logs deploy/hello --tail=20` (add `-f` to follow) |
| Run a command in a pod | `oc exec deploy/hello -- nginx -v` |
| Shell in a pod | `oc rsh deploy/hello` |
| Port-forward | `oc port-forward deploy/hello 8080:80` then `curl localhost:8080` |
| Scale | `oc scale deploy/hello --replicas=3` |
| Rollout status / restart | `oc rollout status deploy/hello` / `oc rollout restart deploy/hello` |
| CPU / memory per pod | `oc adm top pods -A` |
| Events | `oc get events -A --sort-by=.lastTimestamp` |

`logs`, `exec`, `rsh`, `port-forward` and `debug` all travel from the hosted API server to the node
through the **konnectivity** tunnel. If they fail with `No agent available`, check
`oc get pods -n kube-system -l k8s-app=konnectivity-agent`.

### Cluster-level checks

| What | Command |
|---|---|
| API endpoint and version | `oc cluster-info` / `oc version` |
| Health | `oc get --raw /readyz?verbose` |
| Available APIs | `oc api-resources` |

---

## What does not work, and what to use instead

| Command | Why | Use instead |
|---|---|---|
| `oc login`, `oc whoami -t` | No OpenShift OAuth server | The kubeconfig already authenticates you |
| `oc get routes`, `oc expose` | No Route API | `oc port-forward`, or a NodePort Service |
| `oc new-project` | No Project API | `oc create namespace <name>` (`oc project <name>` still works) |
| `oc new-app`, `oc start-build`, ImageStreams | No build/image APIs | `oc create deployment` |
| `oc get co`, `oc get clusterversion`, `oc adm upgrade` | No OpenShift operators or CVO | `oc get tcp` and `oc patch tcp` on the management cluster |
| `oc adm node-logs` | Needs the kubelet's `NodeLogQuery` feature, not enabled | `oc debug node/<n> --image=... -- chroot /host journalctl -u kubelet` |
| `oc rsh` into etcd or kube-apiserver | Distroless images, no shell | `./scripts/etcdctl.sh`, `oc exec`, or `oc logs` |
| `oc adm must-gather` | Needs OpenShift images and APIs | `oc get events`, `oc logs`, `oc describe` |

The lab installs two small pieces so the commands above work:
- **metrics-server** on every cluster, for `oc adm top`.
- The `openshift-user-critical` PriorityClass (`manifests/oc-compat.yaml`), which `oc debug node` sets on its pods.
