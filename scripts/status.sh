#!/usr/bin/env bash
# Quick overview of the lab, laid out the way you would look at HCP.
source "$(dirname "$0")/common.sh"

echo "━━ MANAGEMENT CLUSTER ($MGMT_CLUSTER) ━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
kubectl get nodes -L hypershift.openshift.io/control-plane
echo
echo "━━ HOSTED CONTROL PLANES (≈ HostedCluster / HostedControlPlane) ━━━━━━━━━━━━━"
kubectl get tcp -A
echo
for ns in $(kubectl get tcp -A -o jsonpath='{range .items[*]}{.metadata.namespace}{"\n"}{end}'); do
  echo "── $ns"
  kubectl get pods -n "$ns" -o wide | awk '{printf "   %-32s %-6s %-10s %s\n", $1, $2, $3, $7}'
done
echo
echo "━━ DATA PLANE (≈ NodePools) ━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
for kc in "$LAB_ROOT"/kubeconfig/*.kubeconfig; do
  t=$(basename "$kc" .kubeconfig)
  [[ "$t" == mgmt || "$t" == *-internal ]] && continue
  echo "── $t"
  kubectl --kubeconfig "$kc" get nodes -L hypershift.openshift.io/nodePool 2>/dev/null | sed 's/^/   /' \
    || echo "   (API not reachable)"
done
