#!/usr/bin/env bash
# Resume a lab paused with ./scripts/stop.sh (or after restarting the podman VM / Linux host).
# Brings back the management cluster first, then the NodePool workers, and waits for all of it.
source "$(dirname "$0")/common.sh"

nodes=$(mgmt_nodes)
[ -n "$nodes" ] || die "No management cluster '$MGMT_CLUSTER' found. Create one with ./scripts/01-mgmt-cluster.sh"
[ -n "$LAB_SUDO" ] && { sudo -v || die "sudo is required"; }

set_host_conntrack

log "Starting management cluster"
engine start $nodes >/dev/null
for i in $(seq 1 60); do kubectl get --raw /readyz >/dev/null 2>&1 && break; sleep 3; done
kubectl wait --for=condition=Ready nodes --all --timeout=3m >/dev/null
log "Waiting for hosted control planes"
kubectl wait --for=condition=Available deploy -A -l kamaji.clastix.io/name --timeout=5m >/dev/null 2>&1 || true

workers=$(lab_workers)
if [ -n "$workers" ]; then
  log "Starting workers: $(echo $workers)"
  engine start $workers >/dev/null
fi

for kc in "$LAB_ROOT"/kubeconfig/*.kubeconfig; do
  t=$(basename "$kc" .kubeconfig)
  [[ "$t" == mgmt || "$t" == *-internal ]] && continue
  log "Waiting for $t (nodes, then kube-system pods; konnectivity and CoreDNS take a minute)"
  for i in $(seq 1 60); do kubectl --kubeconfig "$kc" get --raw /readyz >/dev/null 2>&1 && break; sleep 3; done
  kubectl --kubeconfig "$kc" wait --for=condition=Ready nodes --all --timeout=3m >/dev/null 2>&1 || warn "$t: nodes not Ready yet"
  kubectl --kubeconfig "$kc" wait --for=condition=Ready pods --all -n kube-system --timeout=5m >/dev/null 2>&1 || warn "$t: kube-system pods not Ready yet"
done

"$LAB_ROOT/scripts/status.sh"
