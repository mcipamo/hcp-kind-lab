# Shared helpers for the lab scripts. Not meant to be run directly.
set -euo pipefail
source "$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)/env.sh"
mkdir -p "$LAB_ROOT/kubeconfig"

log()  { printf '\033[1;36m==>\033[0m %s\n' "$*"; }
warn() { printf '\033[1;33m!!\033[0m %s\n' "$*" >&2; }
die()  { printf '\033[1;31mxx\033[0m %s\n' "$*" >&2; exit 1; }

# IPv4 subnet of the "kind" container network (podman and docker format it differently).
kind_ipv4_subnet() {
  if [ "$ENGINE" = podman ]; then
    engine network inspect kind --format '{{range .Subnets}}{{.Subnet}} {{end}}'
  else
    engine network inspect kind --format '{{range .IPAM.Config}}{{.Subnet}} {{end}}'
  fi | tr ' ' '\n' | grep -m1 '\.'
}

# Extras so day-to-day oc/kubectl commands work on any lab cluster:
#   - metrics-server       -> `oc adm top nodes|pods`
#   - oc-compat.yaml       -> `oc debug node/<name>` (needs an OpenShift PriorityClass)
install_cluster_extras() {
  local kc="$1"
  kubectl --kubeconfig "$kc" apply -f "$LAB_ROOT/manifests/oc-compat.yaml" >/dev/null
  kubectl --kubeconfig "$kc" apply \
    -f https://github.com/kubernetes-sigs/metrics-server/releases/download/v0.8.0/components.yaml >/dev/null
  # kind kubelets use self-signed serving certs
  if ! kubectl --kubeconfig "$kc" -n kube-system get deploy metrics-server -o jsonpath='{.spec.template.spec.containers[0].args}' | grep -q kubelet-insecure-tls; then
    kubectl --kubeconfig "$kc" -n kube-system patch deploy metrics-server --type json \
      -p '[{"op":"add","path":"/spec/template/spec/containers/0/args/-","value":"--kubelet-insecure-tls"}]' >/dev/null
  fi
}

# Pinned tool versions. Downloaded into bin/ when missing, so no package manager is needed.
KIND_VERSION=v0.33.0
HELM_VERSION=v3.16.1

_os()   { uname -s | tr '[:upper:]' '[:lower:]'; }
_arch() { case "$(uname -m)" in x86_64|amd64) echo amd64 ;; aarch64|arm64) echo arm64 ;; *) uname -m ;; esac; }

ensure_tools() {
  local os arch; os=$(_os); arch=$(_arch)
  mkdir -p "$LAB_ROOT/bin"

  # kind >= 0.33 is needed for the Kubernetes 1.34-1.36 node images
  local kv
  kv=$(kind version 2>/dev/null | awk '{print $2}' || true)
  if [ -z "$kv" ] || [ "$(printf '%s\n%s\n' "$kv" "$KIND_VERSION" | sort -V | head -1)" != "$KIND_VERSION" ]; then
    log "Downloading kind $KIND_VERSION ($os/$arch) into bin/"
    curl -fsSLo "$LAB_ROOT/bin/kind" "https://kind.sigs.k8s.io/dl/$KIND_VERSION/kind-$os-$arch"
    chmod +x "$LAB_ROOT/bin/kind"
  fi

  if ! command -v helm >/dev/null; then
    log "Downloading helm $HELM_VERSION ($os/$arch) into bin/"
    curl -fsSL "https://get.helm.sh/helm-$HELM_VERSION-$os-$arch.tar.gz" \
      | tar -xz -C "$LAB_ROOT/bin" --strip-components=1 "$os-$arch/helm"
  fi

  if [ ! -x "$LAB_ROOT/bin/kubectl" ]; then
    log "Downloading kubectl $MGMT_K8S_VERSION ($os/$arch) into bin/"
    curl -fsSLo "$LAB_ROOT/bin/kubectl" "https://dl.k8s.io/release/$MGMT_K8S_VERSION/bin/$os/$arch/kubectl"
    chmod +x "$LAB_ROOT/bin/kubectl"
  fi
}

# kube-proxy in the hosted clusters sets nf_conntrack_max = 32768 x CPUs and fails with
# "permission denied" inside a container. If the value already matches, it leaves it alone.
# (kind avoids this with conntrack.maxPerCore=0, but Kamaji's kube-proxy addon doesn't expose it.)
# Runs in a privileged container so it works the same on a podman/docker VM and on a Linux host.
# After a reboot the nf_conntrack module may not be loaded yet, so load it first.
set_host_conntrack() {
  log "Setting nf_conntrack_max on the container host"
  engine run --rm --privileged --net=host -v /lib/modules:/lib/modules:ro \
    --entrypoint sh "$(node_image_for "$TENANT_K8S_VERSION")" \
    -c 'modprobe nf_conntrack && sysctl -w net.netfilter.nf_conntrack_max=$((32768 * $(nproc)))'
}

# Containers of the lab
mgmt_nodes()   { engine ps -a --filter "label=io.x-k8s.kind.cluster=$MGMT_CLUSTER" --format '{{.Names}}'; }
lab_workers()  { engine ps -a --filter "label=lab.hcp/nodepool" --format '{{.Names}}'; }
