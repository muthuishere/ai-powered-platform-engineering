#!/usr/bin/env bash
# install-cilium.sh — install Cilium (eBPF dataplane) on a Talos cluster via Helm,
# with Hubble enabled. Pinned version. Uses the Helm values that Talos' own docs
# recommend (KubePrism endpoint, dropped SYS_MODULE capability, manual cgroup root).
#
# Usage:
#   ./install-cilium.sh                 # install/upgrade Cilium + Hubble
#   ./install-cilium.sh --uninstall     # helm uninstall cilium (CNI removal; see note)
#
# kube-proxy-replacement nuance (READ THIS — it is the honest part of the spike):
# ---------------------------------------------------------------------------------
# True kubeProxyReplacement on Talos needs the CLUSTER to have been created WITHOUT
# kube-proxy and WITHOUT a default CNI, i.e. the Talos machine config carries:
#     cluster:
#       network: { cni: { name: none } }
#       proxy:   { disabled: true }
# Then KubePrism (localhost:7445) is the API endpoint Cilium points at. That is a
# machine-config + reboot operation done at cluster-creation time — NOT something a
# workload script should flip on a live cluster (it would tear out the running
# dataplane). So this script DETECTS the cluster's state and picks a safe mode:
#
#   * KPR mode (CILIUM_KPR=true, the Talos-blessed path): cluster already has no
#     kube-proxy DaemonSet -> install with kubeProxyReplacement=true + KubePrism.
#   * Additive mode (default when kube-proxy is still present): install Cilium with
#     kubeProxyReplacement=false so it coexists with the existing kube-proxy and the
#     L7/Hubble demo still works. We DO NOT delete kube-proxy or rewrite Flannel
#     from a script — that is a machine-config decision, documented in README.md.
#
# Override detection with CILIUM_KPR=true|false.
set -euo pipefail

CILIUM_VERSION="${CILIUM_VERSION:-1.18.0}"   # pinned; Talos docs reference 1.18.x
CILIUM_NS="kube-system"
HELM_REPO="https://helm.cilium.io/"
KUBEPRISM_HOST="localhost"
KUBEPRISM_PORT="7445"                         # Talos KubePrism endpoint

log()  { printf '\033[1;34m[cilium]\033[0m %s\n' "$*"; }
warn() { printf '\033[1;33m[warn]\033[0m %s\n' "$*" >&2; }
die()  { printf '\033[1;31m[err]\033[0m %s\n' "$*" >&2; exit 1; }

command -v helm >/dev/null    || die "helm not found"
command -v kubectl >/dev/null || die "kubectl not found"

if [[ "${1:-}" == "--uninstall" ]]; then
  log "helm uninstall cilium (namespace ${CILIUM_NS})…"
  helm uninstall cilium -n "${CILIUM_NS}" 2>/dev/null || warn "cilium release not present"
  warn "If this cluster was created WITH Flannel+kube-proxy, removing Cilium can leave"
  warn "the cluster without a working CNI until Flannel reconciles. On an additive-mode"
  warn "install (kube-proxy still present) Flannel is still the primary CNI, so this is safe."
  exit 0
fi

CTX="$(kubectl config current-context 2>/dev/null || true)"
[[ -n "${CTX}" ]] || die "no current kube context"
log "Context: ${CTX}"

# --- decide kube-proxy-replacement mode -----------------------------------------
if [[ -n "${CILIUM_KPR:-}" ]]; then
  KPR="${CILIUM_KPR}"
  log "kubeProxyReplacement forced via CILIUM_KPR=${KPR}"
elif kubectl -n kube-system get ds kube-proxy >/dev/null 2>&1; then
  KPR="false"
  warn "kube-proxy DaemonSet is present -> ADDITIVE mode (kubeProxyReplacement=false)."
  warn "For the real Talos KPR path, recreate the cluster with cni:none + proxy.disabled,"
  warn "then run with CILIUM_KPR=true. See README.md."
else
  KPR="true"
  log "No kube-proxy DaemonSet -> KPR mode (kubeProxyReplacement=true, KubePrism ${KUBEPRISM_HOST}:${KUBEPRISM_PORT})."
fi

log "Adding/refreshing Helm repo ${HELM_REPO}…"
helm repo add cilium "${HELM_REPO}" >/dev/null 2>&1 || true
helm repo update cilium >/dev/null

# --- Helm values (Talos-recommended) --------------------------------------------
# Common to both modes: Talos-specific cgroup + capability settings, IPAM kubernetes,
# Hubble (relay + UI) on. SYS_MODULE is intentionally absent from ciliumAgent caps
# because Talos forbids workloads loading kernel modules.
HELM_ARGS=(
  upgrade --install cilium cilium/cilium
  --version "${CILIUM_VERSION}"
  --namespace "${CILIUM_NS}"
  --set ipam.mode=kubernetes
  --set cgroup.autoMount.enabled=false
  --set cgroup.hostRoot=/sys/fs/cgroup
  --set securityContext.capabilities.ciliumAgent="{CHOWN,KILL,NET_ADMIN,NET_RAW,IPC_LOCK,SYS_ADMIN,SYS_RESOURCE,DAC_OVERRIDE,FOWNER,SETGID,SETUID}"
  --set securityContext.capabilities.cleanCiliumState="{NET_ADMIN,SYS_ADMIN,SYS_RESOURCE}"
  # Hubble: flow observability + relay + UI.
  --set hubble.enabled=true
  --set hubble.relay.enabled=true
  --set hubble.ui.enabled=true
  --set hubble.metrics.enableOpenMetrics=true
  --set hubble.metrics.enabled="{dns,drop,tcp,flow,http}"
  # L7 visibility/policy needs the Envoy proxy (default true on 1.18, set explicitly).
  --set l7Proxy=true
  --wait
  --timeout 5m
)

if [[ "${KPR}" == "true" ]]; then
  HELM_ARGS+=(
    --set kubeProxyReplacement=true
    --set k8sServiceHost="${KUBEPRISM_HOST}"
    --set k8sServicePort="${KUBEPRISM_PORT}"
  )
else
  # Additive: leave kube-proxy doing service routing; Cilium handles CNI + L7 + Hubble.
  HELM_ARGS+=( --set kubeProxyReplacement=false )
fi

log "helm ${HELM_ARGS[*]}"
helm "${HELM_ARGS[@]}"

log "Waiting for Cilium DaemonSet to roll out…"
kubectl -n "${CILIUM_NS}" rollout status ds/cilium --timeout=300s
log "Waiting for hubble-relay…"
kubectl -n "${CILIUM_NS}" rollout status deploy/hubble-relay --timeout=300s || warn "hubble-relay not ready (continuing)"

log "Cilium ${CILIUM_VERSION} installed (kubeProxyReplacement=${KPR})."
kubectl -n "${CILIUM_NS}" get pods -l k8s-app=cilium -o wide
