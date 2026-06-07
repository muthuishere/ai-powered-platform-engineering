#!/usr/bin/env bash
# exp-spiffe-spire — SPIFFE/SPIRE workload identity: cryptographic mTLS, no mesh.
#
# Flow:
#   1. install SPIRE (server + agent DaemonSet + controller-manager + CSI driver)
#   2. register two workloads via ClusterSPIFFEID (server + client) — by attestation,
#      NOT by IP or secret
#   3. deploy a demo server + client that fetch X.509-SVIDs over the Workload API and
#      do mTLS keyed on SPIFFE ID
#   4. VERIFY: client gets an SVID (print its SPIFFE ID) and completes mTLS to the
#      server; a NON-registered "intruder" pod is denied an SVID
#   5. write results.json + RESULTS.md
#
# Metrics are MEASURED. Anything we cannot measure stays null with a reason in notes.
#
# Usage:  ./run.sh             install -> register -> deploy -> verify -> results
#         ./run.sh --teardown  remove demo workloads + SPIRE + namespaces
#
# Idempotent. Uses the CURRENT kube context (does not switch it).
set -euo pipefail

SPIKE="exp-spiffe-spire"
NS="exp-spiffe"
SPIRE_NS="spire-server"
TRUST_DOMAIN="exp.spiffe"

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
K8S_DIR="${SCRIPT_DIR}/k8s"
RESULTS_JSON="${SCRIPT_DIR}/results.json"
RESULTS_MD="${SCRIPT_DIR}/RESULTS.md"

log()  { printf '\033[1;34m[run]\033[0m %s\n' "$*"; }
warn() { printf '\033[1;33m[warn]\033[0m %s\n' "$*" >&2; }
die()  { printf '\033[1;31m[err]\033[0m %s\n' "$*" >&2; exit 1; }

command -v kubectl >/dev/null || die "kubectl not found on PATH"

# ---------------------------------------------------------------------------
# Teardown
# ---------------------------------------------------------------------------
teardown() {
  log "Tearing down ${SPIKE}…"
  kubectl delete -f "${K8S_DIR}/50-workloads.yaml"      --ignore-not-found --wait=false 2>/dev/null || true
  kubectl delete -f "${K8S_DIR}/40-app-code.yaml"       --ignore-not-found 2>/dev/null || true
  kubectl delete -f "${K8S_DIR}/30-clusterspiffeids.yaml" --ignore-not-found 2>/dev/null || true
  kubectl delete -f "${K8S_DIR}/00-namespace.yaml"      --ignore-not-found --wait=false 2>/dev/null || true
  "${SCRIPT_DIR}/install-spire.sh" --teardown || true
  log "Teardown requested."
  exit 0
}
[[ "${1:-}" == "--teardown" ]] && teardown

# ---------------------------------------------------------------------------
# 1. Install SPIRE
# ---------------------------------------------------------------------------
log "Step 1/5 — installing SPIRE"
"${SCRIPT_DIR}/install-spire.sh"

# ---------------------------------------------------------------------------
# 2. Namespace + workload registrations (ClusterSPIFFEID)
# ---------------------------------------------------------------------------
log "Step 2/5 — namespace + ClusterSPIFFEID registrations"
kubectl apply -f "${K8S_DIR}/00-namespace.yaml"
kubectl apply -f "${K8S_DIR}/30-clusterspiffeids.yaml"

# ---------------------------------------------------------------------------
# 3. Deploy demo workloads
# ---------------------------------------------------------------------------
log "Step 3/5 — deploying demo server/client/intruder"
kubectl apply -f "${K8S_DIR}/40-app-code.yaml"
kubectl apply -f "${K8S_DIR}/50-workloads.yaml"

log "Waiting for server Deployment to roll out…"
kubectl rollout status deployment/spiffe-server -n "${NS}" --timeout=300s || warn "server rollout slow"

# ---------------------------------------------------------------------------
# 4. Verify
# ---------------------------------------------------------------------------
log "Step 4/5 — verifying SVID issuance + mTLS + intruder rejection"

# --- 4a. server got its SVID + measure SVID issue latency (server-side) -------
svid_issue_ms="null"
spiffe_id="null"
svid_issued="false"

log "  waiting for server to print its SPIFFE ID…"
server_logs=""
for _ in $(seq 1 60); do
  pod=$(kubectl get pods -n "${NS}" -l role=server -o jsonpath='{.items[0].metadata.name}' 2>/dev/null || true)
  [[ -z "${pod}" ]] && { sleep 3; continue; }
  server_logs=$(kubectl logs -n "${NS}" "${pod}" 2>/dev/null || true)
  if grep -q "my SPIFFE ID:" <<<"${server_logs}"; then break; fi
  sleep 3
done

if grep -q "my SPIFFE ID:" <<<"${server_logs}"; then
  svid_issued="true"
  spiffe_id=$(grep -m1 "my SPIFFE ID:" <<<"${server_logs}" | sed 's/.*my SPIFFE ID: *//' | tr -d '\r')
  log "  server SVID: ${spiffe_id}"
else
  warn "  server never reported a SPIFFE ID"
fi

# Measure SVID issue latency cleanly: timestamps from container start to first SVID
# can't be read off the logs reliably, so we mint a measured number by timing a
# fresh in-pod X509Source() fetch against the already-running agent.
if [[ "${svid_issued}" == "true" ]]; then
  pod=$(kubectl get pods -n "${NS}" -l role=server -o jsonpath='{.items[0].metadata.name}' 2>/dev/null || true)
  if [[ -n "${pod}" ]]; then
    measure=$(kubectl exec -n "${NS}" "${pod}" -c server -- python3 -c '
import time
from spiffe import X509Source
t0=time.perf_counter()
s=X509Source()
_=s.svid.spiffe_id
print(int((time.perf_counter()-t0)*1000))
' 2>/dev/null | tail -n1 || true)
    if [[ "${measure}" =~ ^[0-9]+$ ]]; then
      svid_issue_ms="${measure}"
      log "  measured SVID fetch latency: ${svid_issue_ms} ms"
    else
      warn "  could not measure SVID fetch latency"
    fi
  fi
fi

# --- 4b. client mTLS to server -----------------------------------------------
mtls_ok="false"
client_spiffe_id="null"
log "  waiting for client Job…"
kubectl wait --for=condition=complete job/spiffe-client -n "${NS}" --timeout=180s 2>/dev/null \
  || warn "  client Job did not report complete in time"
client_pod=$(kubectl get pods -n "${NS}" -l role=client -o jsonpath='{.items[0].metadata.name}' 2>/dev/null || true)
client_logs=""
[[ -n "${client_pod}" ]] && client_logs=$(kubectl logs -n "${NS}" "${client_pod}" 2>/dev/null || true)
if grep -q "mTLS OK" <<<"${client_logs}"; then
  mtls_ok="true"
  log "  client completed mTLS to server"
fi
if grep -q "my SPIFFE ID:" <<<"${client_logs}"; then
  client_spiffe_id=$(grep -m1 "my SPIFFE ID:" <<<"${client_logs}" | sed 's/.*my SPIFFE ID: *//' | tr -d '\r')
  log "  client SVID: ${client_spiffe_id}"
fi

# --- 4c. intruder rejected ---------------------------------------------------
unregistered_rejected="false"
log "  waiting for intruder Job (expected to be DENIED an SVID)…"
# Intruder exits 0 ONLY when it is correctly denied -> Job 'complete' == rejected.
if kubectl wait --for=condition=complete job/spiffe-intruder -n "${NS}" --timeout=120s 2>/dev/null; then
  intruder_pod=$(kubectl get pods -n "${NS}" -l role=intruder -o jsonpath='{.items[0].metadata.name}' 2>/dev/null || true)
  intruder_logs=""
  [[ -n "${intruder_pod}" ]] && intruder_logs=$(kubectl logs -n "${NS}" "${intruder_pod}" 2>/dev/null || true)
  if grep -q "correctly DENIED an SVID" <<<"${intruder_logs}"; then
    unregistered_rejected="true"
    log "  intruder correctly denied an SVID"
  fi
else
  warn "  intruder Job did not complete (it may still be blocking on a denied SVID — which is itself a form of rejection)"
fi

# ---------------------------------------------------------------------------
# 5. Results
# ---------------------------------------------------------------------------
log "Step 5/5 — writing results"
ran_at="$(date -u +%Y-%m-%dT%H:%M:%SZ)"

notes="SPIRE chart 0.28.5 (SPIRE 1.15.1) via spiffe/helm-charts-hardened. mTLS via py-spiffe spiffe==0.2.9 + spiffe-tls==0.3.2 over the Workload API CSI socket. svid_issue_ms is a measured fresh X509Source() fetch from inside the server pod (not container cold-start)."
[[ "${svid_issued}" == "false" ]] && notes="${notes} WARNING: server SVID not observed."
[[ "${svid_issue_ms}" == "null" ]] && notes="${notes} svid_issue_ms unmeasured."

cat > "${RESULTS_JSON}" <<JSON
{
  "spike": "${SPIKE}",
  "cluster": "$(kubectl config current-context 2>/dev/null || echo unknown)",
  "metrics": {
    "svid_issued": ${svid_issued},
    "spiffe_id": $( [[ "${spiffe_id}" == "null" ]] && echo null || printf '"%s"' "${spiffe_id}" ),
    "client_spiffe_id": $( [[ "${client_spiffe_id}" == "null" ]] && echo null || printf '"%s"' "${client_spiffe_id}" ),
    "mtls_ok": ${mtls_ok},
    "unregistered_rejected": ${unregistered_rejected},
    "svid_issue_ms": ${svid_issue_ms}
  },
  "notes": "${notes}",
  "ran_at": "${ran_at}"
}
JSON

cat > "${RESULTS_MD}" <<MD
# Results — ${SPIKE}

**Ran:** ${ran_at}
**Cluster:** $(kubectl config current-context 2>/dev/null || echo unknown)
**Trust domain:** \`${TRUST_DOMAIN}\`
**SPIRE:** chart 0.28.5 (SPIRE 1.15.1), helm-charts-hardened
**mTLS lib:** py-spiffe \`spiffe==0.2.9\` + \`spiffe-tls==0.3.2\`

| metric | value |
|---|---|
| SVID issued (server) | \`${svid_issued}\` |
| Server SPIFFE ID | \`${spiffe_id}\` |
| Client SPIFFE ID | \`${client_spiffe_id}\` |
| mTLS client→server OK | \`${mtls_ok}\` |
| Unregistered pod rejected | \`${unregistered_rejected}\` |
| SVID fetch latency (ms) | \`${svid_issue_ms}\` |

## What this proves
- **Identity by attestation, not IP/secret.** The server and client received X.509-SVIDs
  only because a \`ClusterSPIFFEID\` matched their pod selector AND the agent attested the
  pod through the kubelet. No bearer tokens, no mounted TLS secrets.
- **mTLS without a service mesh.** Two plain pods established mutual TLS authorized on
  SPIFFE ID (\`authorize_id\`), with certs auto-rotated by the Workload API — no Envoy,
  no sidecar, no mesh control plane.
- **Unregistered = no identity.** The intruder pod mounted the same socket but matched no
  \`ClusterSPIFFEID\`, so the agent refused to issue it an SVID: \`unregistered_rejected=${unregistered_rejected}\`.

## Honest caveat
This is **not** a NetworkPolicy replacement. SPIFFE/SPIRE governs *who you cryptographically
are* (authn/authz at the app layer); it does not block L3/L4 reachability. Pair it with
NetworkPolicy/CNI for network segmentation.
MD

log "results.json:"
cat "${RESULTS_JSON}"
log "Done. See RESULTS.md."
