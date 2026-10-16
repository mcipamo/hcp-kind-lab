#!/usr/bin/env bash
# Step 2: management cluster components.
#   cert-manager -> webhook certificates
#   MetalLB      -> LoadBalancer Services to publish hosted API servers (on ROSA: an NLB)
#   Kamaji       -> the lab's "HyperShift operator"
source "$(dirname "$0")/common.sh"

helm repo add jetstack https://charts.jetstack.io >/dev/null 2>&1 || true
helm repo add metallb https://metallb.github.io/metallb >/dev/null 2>&1 || true
helm repo add clastix https://clastix.github.io/charts >/dev/null 2>&1 || true
helm repo update >/dev/null

log "cert-manager"
helm upgrade --install cert-manager jetstack/cert-manager -n cert-manager --create-namespace \
  --version v1.21.2 --set crds.enabled=true --wait >/dev/null

log "MetalLB"
helm upgrade --install metallb metallb/metallb -n metallb-system --create-namespace \
  --version 0.16.1 --wait >/dev/null

# IP pool: a 51-address block near the end of the "kind" network's IPv4 range.
subnet=$(kind_ipv4_subnet)
pool=$(python3 -c "import ipaddress; n=ipaddress.ip_network('$subnet'); b=n.network_address+(n.num_addresses-56); print(f'{b}-{b+50}')")
log "LoadBalancer pool on the kind network ($subnet): $pool"
kubectl apply -f - <<EOF
apiVersion: metallb.io/v1beta1
kind: IPAddressPool
metadata: { name: kind-pool, namespace: metallb-system }
spec: { addresses: ["$pool"] }
---
apiVersion: metallb.io/v1beta1
kind: L2Advertisement
metadata: { name: kind-l2, namespace: metallb-system }
EOF

log "Kamaji (no shared etcd: each hosted cluster gets its own, like HCP)"
helm upgrade --install kamaji clastix/kamaji -n kamaji-system --create-namespace \
  --version 0.0.0+latest \
  --set resources=null \
  --set kamaji-etcd.deploy=false \
  --set telemetry.disabled=true \
  --wait --timeout 10m >/dev/null

log "metrics-server and oc compatibility (oc adm top, oc debug node)"
install_cluster_extras "$KUBECONFIG"

kubectl get pods -n kamaji-system
