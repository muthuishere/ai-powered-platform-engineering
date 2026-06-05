#!/usr/bin/env bash
# Register the workload clusters with ArgoCD (running in ops) so the cluster
# generator in each ApplicationSet can target them.
#
# ArgoCD knows a cluster as a Secret (type=cluster) in the argocd namespace.
# We point it at the workload control-plane's IP ON THE OPS BRIDGE (added by
# 02-connect-networks.sh) — that's the only address ArgoCD's pods can route to.
# The API server cert doesn't list that IP, so we register with insecure TLS.
# The client cert/key come straight from the workload's generated kubeconfig
# (already base64 in the file — exactly the form ArgoCD's tlsClientConfig wants).
#
# Labelling each secret environment=workload makes the ApplicationSet cluster
# generators select it → the four platform apps deploy automatically.
source "$(dirname "$0")/lib.sh"

require kubectl
require docker
require jq
OPS_CTX="$(kube_ctx "$OPS_CLUSTER")"

kubectl --context "$OPS_CTX" get ns "$ARGOCD_NS" >/dev/null 2>&1 \
  || die "ArgoCD namespace not found — run 03 first"

register_one() {
  local name="$1"
  local cp ip ctx kube cert key

  cp="$(cp_container "$name")"
  docker ps --format '{{.Names}}' | grep -qx "$cp" || die "$cp not running — run 01"

  ip="$(docker inspect "$cp" -f '{{(index .NetworkSettings.Networks "ops").IPAddress}}' 2>/dev/null)"
  [ -n "$ip" ] || die "$cp not on the ops bridge — run 02-connect-networks.sh first"

  ctx="$(kube_ctx "$name")"
  # Pull this workload's client credentials out of its kubeconfig entry.
  kube="$(kubectl config view --raw --minify --context "$ctx" -o json)" \
    || die "no kubeconfig context $ctx — run 01"
  cert="$(echo "$kube" | jq -r '.users[0].user["client-certificate-data"]')"
  key="$( echo "$kube" | jq -r '.users[0].user["client-key-data"]')"
  [ -n "$cert" ] && [ "$cert" != "null" ] || die "no client cert for $name"

  log "registering $name → https://$ip:6443 (insecure TLS, label environment=$TARGET_LABEL_VAL)"
  kubectl --context "$OPS_CTX" apply -f - <<YAML
apiVersion: v1
kind: Secret
metadata:
  name: cluster-${name}
  namespace: ${ARGOCD_NS}
  labels:
    argocd.argoproj.io/secret-type: cluster
    ${TARGET_LABEL_KEY}: ${TARGET_LABEL_VAL}
type: Opaque
stringData:
  name: ${name}
  server: https://${ip}:6443
  config: |
    {
      "tlsClientConfig": {
        "insecure": true,
        "certData": "${cert}",
        "keyData": "${key}"
      }
    }
YAML
}

for name in "${WORKLOAD_CLUSTERS[@]}"; do
  register_one "$name"
done

log "registered clusters in ArgoCD:"
kubectl --context "$OPS_CTX" -n "$ARGOCD_NS" get secret \
  -l "argocd.argoproj.io/secret-type=cluster" \
  -L "$TARGET_LABEL_KEY"

log "done. ArgoCD's ApplicationSets will now fan the platform apps onto each workload."
log "Watch:  kubectl --context $OPS_CTX -n $ARGOCD_NS get applications -w"
