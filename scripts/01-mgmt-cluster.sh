#!/usr/bin/env bash
# Step 1: create the management cluster with kind. Safe to re-run.
source "$(dirname "$0")/common.sh"

command -v "$ENGINE" >/dev/null || die "Missing $ENGINE. Linux: run ./scripts/00-linux-host-prep.sh first"
command -v python3 >/dev/null || die "Missing python3"
command -v curl >/dev/null || die "Missing curl"

# kind, helm and kubectl: use the ones in bin/, downloading them when missing (or kind too old)
ensure_tools

if [ -n "$LAB_SUDO" ]; then
  log "Linux + podman: podman and kind run through sudo (rootful podman is required by kind)"
  sudo -v || die "sudo is required"
fi

if [ "$ENGINE" = podman ]; then
  cpus=$(engine info --format '{{.Host.CPUs}}'); mem=$(engine info --format '{{.Host.MemTotal}}')
else
  cpus=$(engine info --format '{{.NCPU}}'); mem=$(engine info --format '{{.MemTotal}}')
fi
mem_gb=$(( mem / 1024 / 1024 / 1024 ))
log "Container engine: $ENGINE${LAB_SUDO:+ (via sudo)}, ${cpus} CPU / ${mem_gb} GB"
if [ "$mem_gb" -lt 9 ]; then
  case "$(uname -s)" in
    Darwin) warn "10-12 GB recommended: podman machine stop && podman machine set --cpus 6 --memory 12288 && podman machine start" ;;
    *)      warn "10-12 GB of free RAM recommended on this host" ;;
  esac
fi

# kube-proxy fix on the container host (see set_host_conntrack in common.sh)
set_host_conntrack

if lab_kind get clusters 2>/dev/null | grep -qx "$MGMT_CLUSTER"; then
  log "Cluster $MGMT_CLUSTER already exists"
else
  log "Creating management cluster $MGMT_CLUSTER"
  lab_kind create cluster --name "$MGMT_CLUSTER" --image "$(node_image_for "$MGMT_K8S_VERSION")" \
    --config "$LAB_ROOT/config/kind-mgmt.yaml" --kubeconfig "$KUBECONFIG" --wait 3m
fi
# kind ran as root under sudo: give the kubeconfig back to you
[ -n "$LAB_SUDO" ] && sudo chown "$(id -u):$(id -g)" "$KUBECONFIG"

kubectl get nodes -L hypershift.openshift.io/control-plane
