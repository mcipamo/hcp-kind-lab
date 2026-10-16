#!/usr/bin/env bash
# Step 0 (Linux only): prepare a Fedora / CentOS Stream / RHEL / Rocky / Alma host. Run once.
#
#   ./scripts/00-linux-host-prep.sh
#
# What it does (asks for sudo):
#   - installs podman, python3, curl and tar with dnf (skips what is already there)
#   - checks cgroup v2, RAM and CPUs
#   - persists the kernel settings the lab needs in /etc/sysctl.d/99-hcp-kind-lab.conf:
#       fs.inotify.max_user_watches / max_user_instances  (many kubelets on one host
#                                                          -> "too many open files" otherwise)
#       net.netfilter.nf_conntrack_max = 32768 x CPUs      (see 01-mgmt-cluster.sh)
#   - loads nf_conntrack now and on boot (/etc/modules-load.d/hcp-kind-lab.conf)
#   - downloads kind, helm and kubectl into bin/
# It does not disable SELinux or firewalld.
source "$(dirname "$0")/common.sh"

[ "$(uname -s)" = Linux ] || die "This script is for Linux hosts. On macOS, see the README."

. /etc/os-release
case "${ID:-}:${ID_LIKE:-}" in
  fedora:*|centos:*|rhel:*|rocky:*|almalinux:*|*:*rhel*|*:*fedora*) log "Host: $PRETTY_NAME" ;;
  *) warn "Host: ${PRETTY_NAME:-unknown}. Only Fedora / CentOS Stream / RHEL-family hosts are covered by this script." ;;
esac

if [ "$(id -u)" = 0 ]; then SUDO=""; else SUDO=sudo; sudo -v || die "sudo is required"; fi

log "Packages"
missing=()
for pkg in podman python3 curl tar; do rpm -q "$pkg" >/dev/null 2>&1 || missing+=("$pkg"); done
if [ ${#missing[@]} -gt 0 ]; then
  log "Installing: ${missing[*]}"
  $SUDO dnf install -y "${missing[@]}"
else
  log "podman, python3, curl and tar already installed"
fi
podman --version

log "cgroup version"
if [ "$(stat -fc %T /sys/fs/cgroup)" = cgroup2fs ]; then
  log "cgroup v2: OK"
else
  die "cgroup v1 detected. kind needs cgroup v2 (default on Fedora 31+, CentOS Stream / RHEL 9+)."
fi

cpus=$(nproc)
mem_gb=$(( $(awk '/MemTotal/ {print $2}' /proc/meminfo) / 1024 / 1024 ))
log "Resources: $cpus CPU / $mem_gb GB RAM"
[ "$cpus" -ge 4 ] || warn "At least 4 CPUs recommended (6 is comfortable)"
[ "$mem_gb" -ge 9 ] || warn "At least 10-12 GB of RAM recommended"

log "Kernel settings (/etc/sysctl.d/99-hcp-kind-lab.conf)"
echo nf_conntrack | $SUDO tee /etc/modules-load.d/hcp-kind-lab.conf >/dev/null
$SUDO modprobe nf_conntrack
$SUDO tee /etc/sysctl.d/99-hcp-kind-lab.conf >/dev/null <<EOF
# hcp-kind-lab: many kubelets in containers on one host
fs.inotify.max_user_watches = 524288
fs.inotify.max_user_instances = 512
# hcp-kind-lab: kube-proxy in the hosted clusters expects exactly 32768 x CPUs
net.netfilter.nf_conntrack_max = $((32768 * cpus))
EOF
$SUDO sysctl -q -p /etc/sysctl.d/99-hcp-kind-lab.conf
sysctl fs.inotify.max_user_watches fs.inotify.max_user_instances net.netfilter.nf_conntrack_max

if command -v getenforce >/dev/null; then
  log "SELinux: $(getenforce) (the lab works with SELinux enforcing; node containers run --privileged)"
fi

log "kind, helm and kubectl"
ensure_tools
"$LAB_ROOT/bin/kind" version
helm version --short
kubectl version --client | head -1

echo
log "Host ready. Next: ./scripts/01-mgmt-cluster.sh"
log "podman will run through sudo (rootful). To avoid repeated password prompts during"
log "long steps, run 'sudo -v' first, or configure sudo with a longer timestamp_timeout."
