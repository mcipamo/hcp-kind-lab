#!/usr/bin/env bash
# Pause the lab: stop every container but keep all state. Resume with ./scripts/start.sh.
# Workers go first, like shutting down a data plane before its control plane.
source "$(dirname "$0")/common.sh"

workers=$(lab_workers); nodes=$(mgmt_nodes)
[ -n "$nodes" ] || die "No management cluster '$MGMT_CLUSTER' found"
[ -n "$workers" ] && { log "Stopping workers: $(echo $workers)"; engine stop $workers >/dev/null 2>&1; }
log "Stopping management cluster: $(echo $nodes)"
engine stop $nodes >/dev/null 2>&1
log "Lab paused. You can now stop the VM (podman machine stop) or reboot the host."
