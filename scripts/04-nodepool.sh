#!/usr/bin/env bash
# Step 4: the "NodePool" of a hosted cluster. Scales or upgrades the data plane workers.
#
#   ./scripts/04-nodepool.sh <hosted-cluster> <replicas> [version]
#
#   replicas  -> scale up / scale down (drain + delete of the extra nodes)
#   version   -> NodePool upgrade: rolling replacement, one node at a time
#                (like upgradeType: Replace). Defaults to the pool's current version,
#                or $TENANT_K8S_VERSION when the pool is empty.
#
# Each worker is a kindest/node container (think: an EC2 instance in ROSA HCP) that joins
# the hosted cluster's API with kubeadm through the LoadBalancer IP. It is NOT part of the
# management cluster and never shows up in its `kubectl get nodes`.
source "$(dirname "$0")/common.sh"

name="${1:-}"; replicas="${2:-}"; version="${3:-}"
[[ -n "$name" && "$replicas" =~ ^[0-9]+$ ]] || die "Usage: $0 <hosted-cluster> <replicas> [version]"
internal_kc="$LAB_ROOT/kubeconfig/$name-internal.kubeconfig"
[ -f "$internal_kc" ] || die "$internal_kc not found. Did you create the cluster with 03-hosted-cluster.sh?"
pool="$name-workers"
hk() { kubectl --kubeconfig "$LAB_ROOT/kubeconfig/$name.kubeconfig" "$@"; }

workers() { $ENGINE ps -a --filter "label=lab.hcp/nodepool=$pool" --format '{{.Names}}' | sort -t- -k3 -n; }
worker_version() { $ENGINE inspect "$1" --format '{{index .Config.Labels "lab.hcp/version"}}'; }

if [ -z "$version" ]; then
  first=$(workers | head -1)
  [ -n "$first" ] && version=$(worker_version "$first")
  version="${version:-$TENANT_K8S_VERSION}"
fi
image=$(node_image_for "$version") || die "No kindest/node image for $version (see node_image_for in env.sh)"

cp_version=$(kubectl get tcp "$name" -n "clusters-$name" -o jsonpath='{.spec.kubernetes.version}')
if [ "$(printf '%s\n%s\n' "$version" "$cp_version" | sort -V | tail -1)" != "$cp_version" ]; then
  die "Invalid version skew: workers $version > control plane $cp_version. Upgrade the control plane first."
fi

create_worker() {
  local node="$1"
  log "Creating $node ($version)"
  local engine_args=(--volume "$node-var:/var")
  [ "$ENGINE" = podman ] && engine_args=(--volume "$node-var:/var:suid,exec,dev" --volume /dev/mapper:/dev/mapper)
  $ENGINE run --name "$node" --hostname "$node" \
    --label "lab.hcp/nodepool=$pool" --label "lab.hcp/hosted-cluster=$name" \
    --label "lab.hcp/version=$version" \
    --privileged --security-opt seccomp=unconfined --security-opt apparmor=unconfined \
    --tmpfs /tmp --tmpfs /run "${engine_args[@]}" --volume /lib/modules:/lib/modules:ro \
    -e "container=$ENGINE" --cgroupns=private --detach --tty --net kind \
    "$image" >/dev/null

  # Wait for systemd (and containerd) to come up inside the container
  for i in $(seq 1 30); do
    $ENGINE exec "$node" systemctl is-active -q containerd 2>/dev/null && break
    sleep 2
  done

  # Bootstrap: what ignition does for a NodePool, done here with kubeadm join and a short-lived token
  $ENGINE cp "$internal_kc" "$node:/root/admin.conf"
  local join
  join=$($ENGINE exec "$node" kubeadm token create --print-join-command --ttl 15m --kubeconfig /root/admin.conf)
  $ENGINE exec "$node" rm -f /root/admin.conf
  log "kubeadm join against $(echo "$join" | awk '{print $3}')"
  $ENGINE exec "$node" $join --ignore-preflight-errors=all >/dev/null 2>&1

  for i in $(seq 1 30); do hk get node "$node" >/dev/null 2>&1 && break; sleep 2; done
  hk label node "$node" --overwrite \
    "hypershift.openshift.io/nodePool=$pool" node-role.kubernetes.io/worker= >/dev/null
  hk wait --for=condition=Ready "node/$node" --timeout 3m >/dev/null
}

delete_worker() {
  local node="$1"
  log "Removing $node (drain + delete)"
  hk drain "$node" --ignore-daemonsets --delete-emptydir-data --timeout 90s >/dev/null 2>&1 || true
  hk delete node "$node" --ignore-not-found >/dev/null
  $ENGINE rm -f "$node" >/dev/null
  $ENGINE volume rm -f "$node-var" >/dev/null 2>&1 || true
}

current=$(workers)
log "NodePool $pool: $(printf '%s\n' "$current" | grep -c . || true) -> $replicas nodes, version $version (control plane: $cp_version)"

# 1) Upgrade: rolling replacement of nodes on a different version (maxUnavailable=1)
for node in $current; do
  idx="${node##*-}"
  if [ "$idx" -le "$replicas" ] && [ "$(worker_version "$node")" != "$version" ]; then
    log "Upgrading $node: $(worker_version "$node") -> $version"
    delete_worker "$node"
    create_worker "$node"
  fi
done

# 2) Scale up
for ((i=1; i<=replicas; i++)); do
  node="$name-worker-$i"
  $ENGINE container inspect "$node" >/dev/null 2>&1 || create_worker "$node"
done

# 3) Scale down
for node in $current; do
  idx="${node##*-}"
  if [ "$idx" -gt "$replicas" ]; then delete_worker "$node"; fi
done

hk get nodes -o wide
