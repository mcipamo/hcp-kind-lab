#!/usr/bin/env bash
# Step 1: create the management cluster with kind. Safe to re-run.
source "$(dirname "$0")/common.sh"

for tool in kind helm python3 "$ENGINE"; do
  command -v "$tool" >/dev/null || die "Missing $tool"
done

# Project-local kubectl, matching the management cluster version
if [ ! -x "$LAB_ROOT/bin/kubectl" ]; then
  os=$(uname -s | tr '[:upper:]' '[:lower:]')
  arch=$(uname -m); case "$arch" in x86_64) arch=amd64 ;; aarch64) arch=arm64 ;; esac
  log "Downloading kubectl $MGMT_K8S_VERSION ($os/$arch) into bin/"
  mkdir -p "$LAB_ROOT/bin"
  curl -fsSLo "$LAB_ROOT/bin/kubectl" "https://dl.k8s.io/release/$MGMT_K8S_VERSION/bin/$os/$arch/kubectl"
  chmod +x "$LAB_ROOT/bin/kubectl"
fi

if [ "$ENGINE" = podman ]; then
  cpus=$(podman info --format '{{.Host.CPUs}}'); mem=$(podman info --format '{{.Host.MemTotal}}')
else
  cpus=$(docker info --format '{{.NCPU}}'); mem=$(docker info --format '{{.MemTotal}}')
fi
mem_gb=$(( mem / 1024 / 1024 / 1024 ))
log "Container engine: $ENGINE, ${cpus} CPU / ${mem_gb} GB"
[ "$mem_gb" -ge 9 ] || warn "10-12 GB recommended. podman: podman machine stop && podman machine set --cpus 6 --memory 12288 && podman machine start"

# kube-proxy in the hosted clusters sets nf_conntrack_max = 32768 x CPUs and fails with
# "permission denied" inside a container. If the value already matches, it leaves it alone.
# (kind avoids this with conntrack.maxPerCore=0, but Kamaji's kube-proxy addon doesn't expose it.)
# Not persistent: re-run this script after restarting the podman/docker VM.
node_image=$(node_image_for "$TENANT_K8S_VERSION")
log "Setting nf_conntrack_max on the container host"
$ENGINE run --rm --privileged --net=host --entrypoint sh "$node_image" \
  -c 'sysctl -w net.netfilter.nf_conntrack_max=$((32768 * $(nproc)))'

if kind get clusters 2>/dev/null | grep -qx "$MGMT_CLUSTER"; then
  log "Cluster $MGMT_CLUSTER already exists"
else
  log "Creating management cluster $MGMT_CLUSTER"
  kind create cluster --name "$MGMT_CLUSTER" --image "$(node_image_for "$MGMT_K8S_VERSION")" \
    --config "$LAB_ROOT/config/kind-mgmt.yaml" --kubeconfig "$KUBECONFIG" --wait 3m
fi
kubectl get nodes -L hypershift.openshift.io/control-plane
