#!/usr/bin/env bash
# Cross-cluster networking for the hub-spoke GitOps model.
#
# Each Talos cluster lives on its own Docker bridge (ops=10.5.0.0/24,
# dev=10.5.1.0/24, ...). By default those bridges can't talk to each
# other, so ArgoCD running inside the OPS cluster cannot reach a workload
# cluster's API server.
#
# Fix: attach each workload's control-plane container to the OPS bridge as well.
# It then has a second IP on 10.5.0.0/24 that the ops nodes (and thus ArgoCD
# pods) can route to. kube-apiserver listens on 0.0.0.0:6443, so it answers on
# that interface too. The API server cert won't list this IP in its SANs, so
# ArgoCD registers the cluster with insecure TLS (see 04-register-clusters.sh).
source "$(dirname "$0")/lib.sh"

require docker

for name in "${WORKLOAD_CLUSTERS[@]}"; do
  cp="$(cp_container "$name")"
  docker ps --format '{{.Names}}' | grep -qx "$cp" || die "container $cp not running — run 01 first"

  if docker inspect "$cp" -f '{{index .NetworkSettings.Networks "ops"}}' 2>/dev/null | grep -q IPAddress; then
    log "$cp already attached to ops bridge"
  else
    log "attaching $cp to ops bridge"
    docker network connect "$OPS_CLUSTER" "$cp"
  fi

  ip="$(docker inspect "$cp" -f '{{(index .NetworkSettings.Networks "ops").IPAddress}}')"
  log "  $name API reachable from ops at https://$ip:6443"
done

log "done. Workload control-planes are now routable from the ops cluster."
