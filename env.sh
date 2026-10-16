# Lab environment for hcp-kind-lab.
# Usage:  source env.sh   (bash or zsh)
#
# Everything stays inside this directory: its own kubeconfigs and its own kubectl,
# so your ~/.kube/config and the kubectl/oc you use for real clusters are never touched.

if [ -n "${ZSH_VERSION:-}" ]; then
  eval '_lab_src="${(%):-%N}"'
else
  _lab_src="${BASH_SOURCE[0]}"
fi
export LAB_ROOT="$(cd "$(dirname "$_lab_src")" && pwd)"
unset _lab_src

# Container engine: podman or docker (auto-detected, podman preferred). Override with ENGINE=docker.
if [ -z "${ENGINE:-}" ]; then
  if command -v podman >/dev/null 2>&1; then ENGINE=podman; else ENGINE=docker; fi
fi
export ENGINE
[ "$ENGINE" = podman ] && export KIND_EXPERIMENTAL_PROVIDER=podman

export PATH="$LAB_ROOT/bin:$PATH"

# The management cluster (where the HyperShift operator would run).
export MGMT_CLUSTER="${MGMT_CLUSTER:-hcp-mgmt}"
export MGMT_K8S_VERSION=v1.36.4
export KUBECONFIG="$LAB_ROOT/kubeconfig/mgmt.kubeconfig"

# Initial version for hosted clusters. One minor behind the management cluster,
# so you can practice upgrades.
export TENANT_K8S_VERSION="${TENANT_K8S_VERSION:-v1.35.8}"

# kind node image for each Kubernetes version (from the kind v0.33 release notes).
# This plays the role of the "release image" that decides what version a NodePool runs.
node_image_for() {
  case "$1" in
    v1.34.11) echo "docker.io/kindest/node:v1.34.11@sha256:44e222ee2132dab25ff87301682f89eb82c7880ea3a1bf543bfe9708fd08d67d" ;;
    v1.35.8)  echo "docker.io/kindest/node:v1.35.8@sha256:07b2536e30b803ed61d1677a79df6115f798ce64c80f9e22f6ed45afd09323c0" ;;
    v1.36.4)  echo "docker.io/kindest/node:v1.36.4@sha256:099e049362a1526b2db71494e1947aae99bd16290d7c895f2b7ea312e3cbfaed" ;;
    *) return 1 ;;
  esac
}

# Shortcut: kubectl against a hosted cluster.  e.g. hkubectl tenant-a get nodes
hkubectl() {
  local t="$1"; shift
  kubectl --kubeconfig "$LAB_ROOT/kubeconfig/$t.kubeconfig" "$@"
}
