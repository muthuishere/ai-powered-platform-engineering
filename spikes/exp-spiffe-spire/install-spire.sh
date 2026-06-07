#!/usr/bin/env bash
# install-spire.sh — install the SPIRE stack via the official helm-charts-hardened.
#
# Deploys (into namespace `spire-server`):
#   spire-server (StatefulSet) + spire-agent (DaemonSet) + spire-controller-manager
#   + spiffe-csi-driver. Then waits until server + agents are Ready.
#
# Pinned, reproducible. Uses the CURRENT kube context (does not switch it).
#
# Usage:   ./install-spire.sh            install + wait healthy
#          ./install-spire.sh --teardown uninstall SPIRE + its namespace
set -euo pipefail

# --- Pinned versions (verified current on artifacthub/PyPI, 2026-06) ----------
HELM_REPO_NAME="spiffe"
HELM_REPO_URL="https://spiffe.github.io/helm-charts-hardened/"
CHART_VERSION="0.28.5"          # spiffe/spire chart (AppVersion SPIRE 1.15.1)
SPIRE_NS="spire-server"

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
VALUES="${SCRIPT_DIR}/k8s/10-spire-values.yaml"

log()  { printf '\033[1;34m[spire]\033[0m %s\n' "$*"; }
die()  { printf '\033[1;31m[err]\033[0m %s\n' "$*" >&2; exit 1; }

command -v helm >/dev/null    || die "helm not found on PATH"
command -v kubectl >/dev/null || die "kubectl not found on PATH"

teardown() {
  log "Uninstalling SPIRE…"
  helm uninstall spire -n "${SPIRE_NS}" 2>/dev/null || true
  helm uninstall spire-crds -n "${SPIRE_NS}" 2>/dev/null || true
  kubectl delete ns "${SPIRE_NS}" --ignore-not-found --wait=false || true
  log "SPIRE teardown requested."
  exit 0
}
[[ "${1:-}" == "--teardown" ]] && teardown

# --- Repo --------------------------------------------------------------------
log "Adding helm repo ${HELM_REPO_NAME} -> ${HELM_REPO_URL}"
helm repo add "${HELM_REPO_NAME}" "${HELM_REPO_URL}" >/dev/null 2>&1 || true
helm repo update "${HELM_REPO_NAME}" >/dev/null

# --- CRDs first (ClusterSPIFFEID etc.) ---------------------------------------
log "Installing spire-crds (chart ${CHART_VERSION})"
helm upgrade --install spire-crds "${HELM_REPO_NAME}/spire-crds" \
  --version "${CHART_VERSION}" \
  -n "${SPIRE_NS}" --create-namespace

# --- The SPIRE stack ---------------------------------------------------------
log "Installing spire (server + agent + controller-manager + csi-driver)"
helm upgrade --install spire "${HELM_REPO_NAME}/spire" \
  --version "${CHART_VERSION}" \
  -n "${SPIRE_NS}" \
  -f "${VALUES}"

# --- Wait for readiness ------------------------------------------------------
log "Waiting for spire-server to be Ready…"
kubectl rollout status statefulset/spire-server -n "${SPIRE_NS}" --timeout=300s

log "Waiting for spire-agent DaemonSet to be Ready…"
kubectl rollout status daemonset/spire-agent -n "${SPIRE_NS}" --timeout=300s

log "SPIRE is up. Pods:"
kubectl get pods -n "${SPIRE_NS}"
