#!/usr/bin/env bash
# Step 3: create a hosted cluster (the lab's equivalent of a HyperShift HostedCluster).
#
#   ./scripts/03-hosted-cluster.sh <name> <slot 1..3> [version]
#
# What it creates on the management cluster, in namespace clusters-<name> (same as HCP):
#   - a dedicated etcd (StatefulSet) and its Kamaji DataStore
#   - a TenantControlPlane: kube-apiserver, controller-manager, scheduler and
#     konnectivity-server as a pod, plus addons (CoreDNS, kube-proxy) applied INSIDE the tenant
#   - a LoadBalancer Service (MetalLB) -> how data plane workers reach the API
#   - a NodePort Service 3144<slot>    -> how you reach it from your machine (127.0.0.1:3144<slot>)
source "$(dirname "$0")/common.sh"

name="${1:-}"; slot="${2:-}"; version="${3:-$TENANT_K8S_VERSION}"
[[ -n "$name" && "$slot" =~ ^[1-3]$ ]] || die "Usage: $0 <name> <slot 1..3> [version]"
ns="clusters-$name"
local_port="3144$slot"

log "Namespace $ns"
kubectl create namespace "$ns" --dry-run=client -o yaml | kubectl apply -f - >/dev/null

log "Dedicated etcd for $name"
helm upgrade --install "$name-etcd" clastix/kamaji-etcd -n "$ns" \
  --set fullnameOverride="$name-etcd" \
  --set replicas=1 \
  --set datastore.enabled=true \
  --set datastore.name="$name-etcd" \
  --set persistentVolumeClaim.size=1Gi \
  --set-string "nodeSelector.hypershift\\.openshift\\.io/control-plane=true" \
  --wait --timeout 5m >/dev/null

log "TenantControlPlane $name ($version)"
kubectl apply -f - <<EOF
apiVersion: kamaji.clastix.io/v1alpha1
kind: TenantControlPlane
metadata:
  name: $name
  namespace: $ns
  labels:
    tenant.clastix.io: $name
spec:
  dataStore: $name-etcd
  controlPlane:
    deployment:
      replicas: 1
      # Hosted control planes only run on the management cluster's control-plane nodes
      nodeSelector:
        hypershift.openshift.io/control-plane: "true"
    service:
      serviceType: LoadBalancer
  kubernetes:
    version: "$version"
    kubelet:
      cgroupfs: systemd
      # Settings so kubelet works inside a kind node container
      configurationJSONPatches:
        - { op: add, path: /failSwapOn, value: false }
        - { op: add, path: /imageGCHighThresholdPercent, value: 100 }
        - op: add
          path: /evictionHard
          value: { "nodefs.available": "0%", "nodefs.inodesFree": "0%", "imagefs.available": "0%" }
  networkProfile:
    port: 6443
    certSANs: ["127.0.0.1", "localhost"]
  addons:
    coreDNS: {}
    kubeProxy: {}
    konnectivity:
      server:
        port: 8132
      agent:
        mode: DaemonSet
EOF

log "Waiting for the control plane to be Ready (usually under a minute)..."
status=""
for i in $(seq 1 60); do
  status=$(kubectl get tcp "$name" -n "$ns" -o jsonpath='{.status.kubernetesResources.version.status}' 2>/dev/null || true)
  [ "$status" = "Ready" ] && break
  sleep 5
done
kubectl get tcp "$name" -n "$ns"
[ "$status" = "Ready" ] || die "TenantControlPlane is not Ready. Check: kubectl -n $ns get pods; kubectl -n $ns describe tcp $name"

log "NodePort Service $local_port for access from your machine"
selector=$(kubectl get svc "$name" -n "$ns" -o jsonpath='{.spec.selector}')
kubectl apply -f - >/dev/null <<EOF
apiVersion: v1
kind: Service
metadata:
  name: $name-local
  namespace: $ns
  labels: { lab.hcp/purpose: local-access }
spec:
  type: NodePort
  selector: $selector
  ports:
    - { name: kube-apiserver, port: 6443, targetPort: 6443, nodePort: $local_port }
EOF

log "Kubeconfigs"
secret=$(kubectl get tcp "$name" -n "$ns" -o jsonpath='{.status.kubeconfig.admin.secretName}')
kubectl get secret "$secret" -n "$ns" -o jsonpath='{.data.admin\.conf}' | base64 -d \
  > "$LAB_ROOT/kubeconfig/$name-internal.kubeconfig"      # points at the LB IP (kind network)
sed -E "s#server: https://[^ ]+#server: https://127.0.0.1:$local_port#" \
  "$LAB_ROOT/kubeconfig/$name-internal.kubeconfig" > "$LAB_ROOT/kubeconfig/$name.kubeconfig"

# kindnet is the CNI that ships with kindest/node images. flannel does not work here: it
# delegates to the "bridge" CNI plugin, which these images do not include.
log "CNI (kindnet) inside the hosted cluster"
kubectl --kubeconfig "$LAB_ROOT/kubeconfig/$name.kubeconfig" apply \
  -f "$LAB_ROOT/manifests/kindnet.yaml" >/dev/null

log "metrics-server and oc compatibility (oc adm top, oc debug node)"
install_cluster_extras "$LAB_ROOT/kubeconfig/$name.kubeconfig"

echo
kubectl -n "$ns" get pods,svc
echo
log "Done. Try:  source env.sh && hkubectl $name get --raw /version"
log "It has no nodes yet. Add workers with: ./scripts/04-nodepool.sh $name 1"
