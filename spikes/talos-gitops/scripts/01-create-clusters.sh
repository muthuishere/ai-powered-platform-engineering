#!/usr/bin/env bash
# Create all four Talos clusters with the Docker provisioner.
#   ops + dev + staging + prod
# Each: 1 control-plane + $WORKERS_PER_CLUSTER workers on its own /24 bridge.
#
# Idempotent: skips a cluster whose control-plane container is already running.
source "$(dirname "$0")/lib.sh"

require talosctl
require docker
docker info >/dev/null 2>&1 || die "Docker engine not reachable (start OrbStack)."

create_one() {
  local entry="$1"
  local name subnet
  name="$(c_name "$entry")"; subnet="$(c_subnet "$entry")"

  if docker ps --format '{{.Names}}' | grep -qx "$(cp_container "$name")"; then
    log "cluster '$name' already running — skipping"
    return 0
  fi

  log "creating cluster '$name'  subnet=$subnet  workers=$WORKERS_PER_CLUSTER"
  # The provisioner picks a free high host port for the API and records it in
  # kubeconfig as context admin@$name — nothing for us to wire up.
  # --config-patch pins nameservers so etcd's image pull resolves (see
  # scripts/patches/dns.yaml — without it every cluster wedges on etcd).
  talosctl cluster create docker \
    --name "$name" \
    --workers "$WORKERS_PER_CLUSTER" \
    --subnet "$subnet" \
    --memory-controlplanes "$CP_MEM" \
    --memory-workers "$WK_MEM" \
    --kubernetes-version "$K8S_VERSION" \
    --config-patch "@$(dirname "${BASH_SOURCE[0]}")/patches/dns.yaml"
}

for entry in "${CLUSTERS[@]}"; do
  create_one "$entry"
done

log "all clusters created. Contexts:"
kubectl config get-contexts -o name | grep -E 'admin@(ops|workload-)'
