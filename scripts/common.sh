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
