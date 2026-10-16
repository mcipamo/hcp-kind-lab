#!/usr/bin/env bash
# Run etcdctl against a hosted cluster's dedicated etcd, as the etcd "root" user.
#
#   ./scripts/etcdctl.sh <hosted-cluster> <etcdctl args...>
#   ./scripts/etcdctl.sh tenant-a endpoint status -w table
#   ./scripts/etcdctl.sh tenant-a get / --prefix --keys-only --limit 20
#
# Kamaji turns on etcd RBAC: each tenant API server authenticates with its own client
# certificate and only sees its own key prefix. The etcd pod has no shell and does not mount
# the root client certificate, so this starts a short-lived pod that mounts it.
source "$(dirname "$0")/common.sh"

name="${1:-}"; shift || true
[ -n "$name" ] && [ $# -gt 0 ] || die "Usage: $0 <hosted-cluster> <etcdctl args...>"
ns="clusters-$name"
image=$(kubectl get sts "$name-etcd" -n "$ns" -o jsonpath='{.spec.template.spec.containers[0].image}')
# Same endpoints the API server uses (the server cert's SANs cover these names)
endpoints=$(kubectl get datastore "$name-etcd" -o jsonpath='{range .spec.endpoints[*]}https://{@},{end}')
endpoints="${endpoints%,}"

args_json=$(python3 -c 'import json,sys; print(json.dumps(sys.argv[1:]))' "$@")
pod="etcdctl-$RANDOM"
trap 'kubectl delete pod "$pod" -n "$ns" --now --ignore-not-found >/dev/null 2>&1' EXIT
# Not `kubectl run -i`: it can miss the output of commands that finish instantly.
kubectl run "$pod" -n "$ns" --restart=Never --image="$image" \
  --overrides "$(cat <<EOF
{
  "spec": {
    "nodeSelector": { "hypershift.openshift.io/control-plane": "true" },
    "containers": [{
      "name": "etcdctl",
      "image": "$image",
      "command": ["etcdctl"],
      "args": $args_json,
      "env": [
        { "name": "ETCDCTL_ENDPOINTS", "value": "$endpoints" },
        { "name": "ETCDCTL_DIAL_TIMEOUT", "value": "5s" },
        { "name": "ETCDCTL_COMMAND_TIMEOUT", "value": "15s" },
        { "name": "ETCDCTL_CACERT", "value": "/certs/ca/ca.crt" },
        { "name": "ETCDCTL_CERT", "value": "/certs/client/tls.crt" },
        { "name": "ETCDCTL_KEY", "value": "/certs/client/tls.key" }
      ],
      "volumeMounts": [
        { "name": "ca", "mountPath": "/certs/ca" },
        { "name": "client", "mountPath": "/certs/client" }
      ]
    }],
    "volumes": [
      { "name": "ca", "secret": { "secretName": "$name-etcd-certs", "items": [{ "key": "ca.crt", "path": "ca.crt" }] } },
      { "name": "client", "secret": { "secretName": "$name-etcd-root-client-certs" } }
    ]
  }
}
EOF
)" >/dev/null
for i in $(seq 1 60); do
  phase=$(kubectl get pod "$pod" -n "$ns" -o jsonpath='{.status.phase}')
  [[ "$phase" == Succeeded || "$phase" == Failed ]] && break
  sleep 1
done
kubectl logs "$pod" -n "$ns"
[ "$phase" = Succeeded ]
