#!/usr/bin/env bash
# Delete a hosted cluster: its NodePool (workers) first, then the control plane and its etcd.
#   ./scripts/05-delete-hosted-cluster.sh <name>
source "$(dirname "$0")/common.sh"

name="${1:-}"; [ -n "$name" ] || die "Usage: $0 <name>"
ns="clusters-$name"

for node in $($ENGINE ps -a --filter "label=lab.hcp/hosted-cluster=$name" --format '{{.Names}}'); do
  log "Removing worker $node"
  $ENGINE rm -f "$node" >/dev/null
  $ENGINE volume rm -f "$node-var" >/dev/null 2>&1 || true
done

log "Deleting TenantControlPlane and etcd for $name"
kubectl delete tcp "$name" -n "$ns" --ignore-not-found --wait
helm uninstall "$name-etcd" -n "$ns" --wait 2>/dev/null || true
kubectl delete namespace "$ns" --ignore-not-found --wait
rm -f "$LAB_ROOT/kubeconfig/$name.kubeconfig" "$LAB_ROOT/kubeconfig/$name-internal.kubeconfig"
log "Hosted cluster $name deleted"
