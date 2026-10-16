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
    $ENGINE network inspect kind --format '{{range .Subnets}}{{.Subnet}} {{end}}'
  else
    $ENGINE network inspect kind --format '{{range .IPAM.Config}}{{.Subnet}} {{end}}'
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
