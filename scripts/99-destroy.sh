#!/usr/bin/env bash
# Tear down the WHOLE lab: workers of every hosted cluster and the management cluster.
# Leaves your podman/docker VM and your ~/.kube/config alone.
source "$(dirname "$0")/common.sh"

for node in $(engine ps -a --filter "label=lab.hcp/nodepool" --format '{{.Names}}'); do
  log "Removing worker $node"
  engine rm -f "$node" >/dev/null 2>&1
  engine volume rm -f "$node-var" >/dev/null 2>&1 || true
done
lab_kind delete cluster --name "$MGMT_CLUSTER" --kubeconfig "$KUBECONFIG"
rm -f "$LAB_ROOT"/kubeconfig/*.kubeconfig
log "Lab destroyed"
