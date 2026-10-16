# hcp-kind-lab

**Run the OpenShift Hosted Control Planes (HyperShift) architecture on your laptop**, so you can
see, break and fix it before you meet it in production.

Built with `kind`, podman/docker and [Kamaji](https://github.com/clastix/kamaji). Two hosted
clusters with their own control planes and workers come up in about 5 minutes and use ~3.3 GB of RAM.

---

## What it does

In HCP (the model behind ROSA HCP), a cluster's control plane does not run on its own nodes.
It runs **as pods inside a separate management cluster**, and the customer's workers only reach it
through a published endpoint. This lab builds that same topology from upstream pieces:

- A **management cluster** (`hcp-mgmt`), whose nodes carry the same
  `hypershift.openshift.io/control-plane` label HCP uses.
- **Hosted clusters** (`tenant-a`, `tenant-b`, …). Each one gets a `clusters-<name>` namespace
  on the management cluster containing:
  - its kube-apiserver, controller-manager, scheduler and konnectivity-server as a pod
  - a dedicated etcd
  - a LoadBalancer Service that publishes the API
- **NodePools**: worker nodes that live *outside* the management cluster. They join their hosted
  cluster's API over the network and open a konnectivity tunnel back to it.

```
┌─────────────────────────── MANAGEMENT CLUSTER (kind: hcp-mgmt) ────────────────────────────┐
│  control-plane            worker / worker2  (label hypershift.openshift.io/control-plane)   │
│                                                                                             │
│  ns kamaji-system      ns clusters-tenant-a            ns clusters-tenant-b                 │
│  ┌────────────┐        ┌───────────────────────┐       ┌───────────────────────┐            │
│  │  Kamaji    │───────▶│ kube-apiserver        │       │ kube-apiserver        │            │
│  │ (≈ Hyper-  │        │ controller-manager    │       │ controller-manager    │            │
│  │  Shift op.)│        │ scheduler             │       │ scheduler             │            │
│  └────────────┘        │ konnectivity-server   │       │ konnectivity-server   │            │
│                        │ etcd (dedicated)      │       │ etcd (dedicated)      │            │
│  MetalLB ── LB ───────▶│ Svc LB 10.89.0.200    │       │ Svc LB 10.89.0.201    │            │
│                        └───────────▲───────────┘       └───────────▲───────────┘            │
└────────────────────────────────────┼───────────────────────────────┼────────────────────────┘
               kubelet → :6443       │  konnectivity tunnel :8132    │
┌────────────────────────────────────┴──┐               ┌────────────┴──────────────────────┐
│ DATA PLANE tenant-a (NodePool)        │               │ DATA PLANE tenant-b (NodePool)     │
│ tenant-a-worker-1                     │               │ tenant-b-worker-1                  │
│  kubelet, kube-proxy, kindnet,        │               │                                    │
│  CoreDNS, konnectivity-agent, apps    │               │                                    │
└───────────────────────────────────────┘               └────────────────────────────────────┘
```

For a visual version, open [`docs/architecture.html`](docs/architecture.html) in a browser.

### How it maps to OpenShift HCP

| OpenShift HCP / HyperShift | In this lab |
|---|---|
| Management cluster | kind cluster `hcp-mgmt` |
| Control-plane nodes of the management cluster (label `hypershift.openshift.io/control-plane`) | `hcp-mgmt-worker`, `hcp-mgmt-worker2` (same label) |
| HyperShift operator | Kamaji (`kamaji-system`) |
| `HostedCluster` + `HostedControlPlane` | `TenantControlPlane` (`kubectl get tcp -A`) |
| Namespace `clusters-<name>` | Namespace `clusters-<name>` |
| One etcd per hosted cluster | Dedicated etcd per tenant (`<name>-etcd`) |
| API publishing (NLB / Route) | `LoadBalancer` Service via MetalLB |
| Konnectivity | konnectivity-server in the control plane pod, agent as a DaemonSet in the tenant |
| `NodePool` | `scripts/04-nodepool.sh` (`kindest/node` containers) |
| Ignition / node bootstrap | `kubeadm join` with a 15-minute token |
| Control plane upgrade (`HostedCluster.spec.release`) | `spec.kubernetes.version` on the TCP |
| NodePool upgrade (`upgradeType: Replace`) | `04-nodepool.sh <c> <n> <version>`: rolling replacement |
| OVN-Kubernetes | kindnet |

---

## Why use it

- **See what a managed service hides.** In ROSA HCP you never get to see the management cluster.
  Here you own both sides, so you can follow a request from a worker to its control plane.
- **Break things safely.** Kill an API server, lose a management node, delete the konnectivity
  agent. Nothing here is anyone's production.
- **Cheap and fast.** It runs on a laptop with no cloud account and no pull secret. It is up in
  ~5 minutes and gone in seconds.
- **Small enough to read.** Each step is a short, commented bash script. The scripts *are* the
  documentation of how a hosted control plane gets wired.
- **Uses the tools you already have.** Both `kubectl` and `oc` work against every cluster in the lab, including
  `oc adm top`, `oc debug node` and `oc rsh` (see the [`oc` guide](docs/oc-guide.md)).
- **Safe for your real environment.** The lab uses its own kubeconfigs and its own kubectl. It never
  touches `~/.kube/config`.

---

## Installation

### 1. Prerequisites

| Tool | Version | macOS (Homebrew) | Linux |
|---|---|---|---|
| podman (tested) **or** docker | podman 5.x / docker 24+ | `brew install podman` | distro package |
| kind | ≥ 0.33 | `brew install kind` | [kind releases](https://kind.sigs.k8s.io/docs/user/quick-start/#installation) |
| helm | 3.x | `brew install helm` | [helm install](https://helm.sh/docs/intro/install/) |
| python3, curl | any | preinstalled | distro package |

`kubectl` is downloaded automatically into `bin/` on first run.

### 2. Give the container VM enough resources

You need **6 CPUs and 10–12 GB of RAM** for the VM. With podman on macOS:

```bash
podman machine init --cpus 6 --memory 12288 --rootful   # new machine
# or, for an existing one:
podman machine stop && podman machine set --cpus 6 --memory 12288 && podman machine start
```

On Docker Desktop, raise the limits under *Settings → Resources*.

### 3. Get the code

```bash
git clone https://github.com/mcipamo/hcp-kind-lab.git
cd hcp-kind-lab
```

Tested on macOS (Apple Silicon) with podman 5.4 and kind 0.33. Docker and Linux should work but are untested.

---

## Usage

### Bring the lab up

```bash
./scripts/01-mgmt-cluster.sh               # management cluster (1 control-plane + 2 nodes for hosted control planes)
./scripts/02-addons.sh                     # cert-manager, MetalLB, Kamaji
./scripts/03-hosted-cluster.sh tenant-a 1  # hosted cluster in slot 1 → API on 127.0.0.1:31441
./scripts/04-nodepool.sh tenant-a 1        # one worker in its data plane
./scripts/03-hosted-cluster.sh tenant-b 2  # optional second hosted cluster (slot 2 → 31442)
./scripts/04-nodepool.sh tenant-b 1
./scripts/status.sh                        # overview of everything
```

You can run up to 3 hosted clusters, in slots 1–3, which map to ports 31441–31443 on your machine.

### Connect

Run this once per terminal. It sets your PATH, KUBECONFIG and the `hkubectl` helper:

```bash
source env.sh
```

**Management cluster** (the SRE view, with hosted control planes running as pods):

```bash
export KUBECONFIG=$LAB_ROOT/kubeconfig/mgmt.kubeconfig
kubectl get tcp -A                                            # ≈ oc get hostedcluster -A
kubectl get pods -n clusters-tenant-a                         # control plane pod + etcd
```

**Hosted cluster** (the customer view, which sees only its own cluster):

```bash
export KUBECONFIG=$LAB_ROOT/kubeconfig/tenant-a.kubeconfig
kubectl get nodes
# or, without changing KUBECONFIG:
hkubectl tenant-a get nodes
```

**`oc` works too**, on both sides. You can look at nodes, pods and logs, and use `exec`, `rsh`,
`debug node`, `adm top`, `adm drain`, `port-forward` and more. OpenShift-only APIs such as Routes,
`new-project`, builds, `oc get co` and `oc login` do not exist on vanilla Kubernetes.
**See the [`oc` guide](docs/oc-guide.md)** for a tested command reference for the control plane
side and the data plane side, and for what to use when an OpenShift-only command doesn't apply.

Tip: keep two terminals open, one on the management cluster and one on a hosted cluster.
Break something on one side and watch the other.

Run `unset KUBECONFIG` or open a new terminal before going back to real clusters.

### Manage hosted clusters and NodePools

| Task | Command |
|---|---|
| Create a hosted cluster | `./scripts/03-hosted-cluster.sh <name> <slot 1-3> [version]` |
| Scale a NodePool | `./scripts/04-nodepool.sh <name> <replicas>` |
| Upgrade the control plane | `kubectl -n clusters-<name> patch tcp <name> --type merge -p '{"spec":{"kubernetes":{"version":"v1.36.4"}}}'` |
| Upgrade a NodePool | `./scripts/04-nodepool.sh <name> <replicas> v1.36.4` |
| Delete a hosted cluster | `./scripts/05-delete-hosted-cluster.sh <name>` |
| Delete the whole lab | `./scripts/99-destroy.sh` |
| Show everything | `./scripts/status.sh` |
| Query a tenant's etcd | `./scripts/etcdctl.sh <name> get / --prefix --keys-only --limit 20` |

The available Kubernetes versions are v1.34.11, v1.35.8 and v1.36.4 (see `node_image_for` in `env.sh`).

---

## What you can see

From the **management cluster**:

- **The control planes as plain pods.** `kubectl get pods -n clusters-tenant-a` shows one
  Deployment pod with four containers (`kube-apiserver`, `kube-controller-manager`,
  `kube-scheduler`, `konnectivity-server`) and an `etcd-0` StatefulSet pod.
- **Where each control plane is scheduled.** `kubectl get pods -A -o wide` shows hosted control
  planes landing only on nodes labeled `hypershift.openshift.io/control-plane`.
- **How the API is published.** `kubectl get svc -n clusters-tenant-a` shows the LoadBalancer IP
  the workers use and the NodePort you use.
- **The secrets that make up a cluster's identity.** `kubectl get secrets -n clusters-tenant-a`
  lists the CA, the API server certs, the etcd certs and the admin kubeconfig.
- **The operator reconciling.** `kubectl logs -n kamaji-system deploy/kamaji -f`.

From inside a **hosted cluster**:

- **A cluster with no control plane in it.** `hkubectl tenant-a get pods -A` shows CoreDNS,
  kube-proxy, kindnet and the konnectivity agent, and no apiserver or etcd.
- **Nodes that belong to a NodePool.** `hkubectl tenant-a get nodes -L hypershift.openshift.io/nodePool`.
- **Version skew in action.** After a control plane upgrade, `hkubectl tenant-a version` reports
  the new server version while `get nodes` still shows the old kubelets.

From the **container engine**:

- **Workers as separate machines.** `podman ps` shows `tenant-a-worker-1` next to, but not part of,
  the `hcp-mgmt-*` nodes.
- **Node-level debugging.** `podman exec -it tenant-a-worker-1 bash`, then `crictl ps` and `journalctl -u kubelet`.

---

## What you can do: exercises

1. **Anatomy of a hosted control plane.** Map every pod, Service and Secret in
   `clusters-tenant-a` to its role. Find the admin kubeconfig and decode it.
2. **The tenant cannot see its control plane.** Compare `kubectl get pods -A` on the management
   cluster with `hkubectl tenant-a get pods -A`.
3. **Konnectivity, the reverse tunnel.** Delete the agent and try `logs`/`exec`:
   `hkubectl tenant-a -n kube-system delete ds konnectivity-agent` gives `No agent available`.
   Watch Kamaji recreate it.
4. **The control plane goes down, the workloads keep running.**
   `kubectl -n clusters-tenant-a scale deploy tenant-a --replicas=0`. The API is gone, yet
   `podman exec tenant-a-worker-1 crictl ps` shows your apps still running.
5. **Control plane HA.** Set the TCP's `spec.controlPlane.deployment.replicas` to 2 and watch the
   replicas spread across both management nodes.
6. **Two-phase upgrade.** Upgrade the control plane, check the skew, then upgrade the NodePool.
   Try putting workers ahead of the control plane: the script refuses.
7. **Scale the NodePool** up to 3 and back to 1, and watch the drain happen.
8. **Lose a management cluster node.** Run `podman stop hcp-mgmt-worker2`. Which control planes go down?
   Do they reschedule? What happens to an etcd on a local PVC? Bring it back with `podman start`.
9. **Isolation between tenants.** Compare the CAs and etcds of `tenant-a` and `tenant-b`.
   `./scripts/etcdctl.sh tenant-a user list` shows etcd RBAC with one user per tenant. What
   would they share with a common DataStore?
10. **Debug without the API.** With konnectivity broken, find out why a pod fails using only
    `podman exec <worker> crictl ...` and `journalctl`.

---

## What you can learn

- **The control plane / data plane split.** Which components live where in HCP, which network
  paths cross the boundary (kubelet → API on 6443, konnectivity on 8132), and why.
- **Why konnectivity exists.** The control plane cannot reach the workers directly, so the
  worker opens the tunnel. `logs`, `exec` and `port-forward` stop working when it breaks, and
  that is a common HCP support case.
- **Blast radius.** What a customer loses when their control plane goes down (the API) and
  what they keep (running workloads). Also what a management cluster node failure does to many
  tenants at once.
- **Upgrades in HCP.** Control plane and NodePools upgrade independently, the version skew
  rules apply, and a `Replace` upgrade drains and recreates nodes.
- **Node bootstrap.** A node becomes part of a cluster through the cluster's CA,
  bootstrap tokens and the published API endpoint.
- **Multi-tenancy on one management cluster.** Per-tenant namespaces, certificates and etcd, plus
  the scheduling rules that keep control planes on dedicated nodes.
- **Debugging from both sides.** The SRE habit of keeping one view on the management cluster and
  one inside the hosted cluster.

### Differences from real HCP

Keep these in mind so you don't learn the wrong thing:

- There are no OpenShift components: no openshift-apiserver, oauth, CVO, cluster operators or Routes.
- HCP runs each component as its own Deployment. Kamaji packs four into one pod.
- Workers share the container engine's `kind` network with the management cluster. They don't
  live in another account or VPC.
- There is no `NodePool` CRD. A script plays the controller.

---

## License

MIT. See [LICENSE](LICENSE).

---

## Known issues (and why)

| Symptom | Cause | How the lab handles it |
|---|---|---|
| kube-proxy: `open /proc/sys/net/netfilter/nf_conntrack_max: permission denied` | kube-proxy rewrites the value whenever it differs from `32768 × CPUs`, and it is not allowed to inside a container | `01-mgmt-cluster.sh` sets exactly that value on the container host. The setting does not survive a VM restart: re-run `01-mgmt-cluster.sh` (it is idempotent) after restarting podman/docker or changing CPUs |
| Pods stuck in `ContainerCreating`, `failed to find plugin "bridge"` | flannel delegates to the `bridge` CNI plugin, which kindest/node images do not ship | The lab uses kindnet (`manifests/kindnet.yaml`, taken from the kindest/node image) |
| `logs`/`exec`: `No agent available` | konnectivity-agent is not running, usually because pod networking is broken | Debug from the node: `podman exec <worker> crictl ps -a` / `crictl logs <id>` |
| podman: `loading registries configuration ... toml` | Malformed `~/.config/containers/registries.conf` (podman parses it on every `run`) | Fix the TOML: every entry needs its own `[[registry]]` header |

---

## Repository layout

```
env.sh                       lab variables, node_image_for(), hkubectl()
config/kind-mgmt.yaml        management cluster topology
manifests/kindnet.yaml       CNI for the hosted clusters
scripts/01-mgmt-cluster.sh   management cluster + kubectl download + host conntrack fix
scripts/02-addons.sh         cert-manager, MetalLB, Kamaji, metrics-server
scripts/03-hosted-cluster.sh hosted cluster (etcd + TenantControlPlane + Services + kubeconfigs + CNI)
scripts/04-nodepool.sh       NodePool scale / upgrade
scripts/etcdctl.sh           etcdctl as root against a tenant's etcd
scripts/05-delete-hosted-cluster.sh, 99-destroy.sh, status.sh
docs/architecture.html       visual architecture page
docs/oc-guide.md             tested oc command reference for both planes
manifests/oc-compat.yaml     PriorityClass so `oc debug node` works on vanilla Kubernetes
kubeconfig/                  (generated, git-ignored) mgmt + one per hosted cluster
bin/kubectl                  (downloaded, git-ignored)
```
