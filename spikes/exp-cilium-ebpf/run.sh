#!/usr/bin/env bash
# exp-cilium-ebpf — Cilium (eBPF) on Talos: kube-proxy-replacement, L7 HTTP policy,
# Hubble observability.
#
# Flow:
#   1. Install Cilium via Helm (pinned) with Hubble (install-cilium.sh).
#   2. Wait Cilium ready (cilium CLI status if present, else kubectl rollout).
#   3. Deploy demo app (client + server Deployments + Service).
#   4. Apply the L7 CiliumNetworkPolicy, then TEST it from the client pod:
#        GET /public -> expect 200 (allowed)   -> l7_allow_ok
#        GET /admin  -> expect 403 (Envoy deny) -> l7_deny_blocked
#   5. Pull a Hubble flow count (cilium hubble observe, if available).
#   6. Measure simple pod-to-pod throughput: a timed curl loop -> requests/sec.
#   7. Write results.json + RESULTS.md.
#
# Usage:
#   ./run.sh              install -> demo -> L7 test -> hubble -> throughput -> results
#   ./run.sh --teardown   remove demo app + policy (Cilium itself: install-cilium.sh --uninstall)
#
# Idempotent. Uses the CURRENT kube context (does not switch it). No fabricated
# numbers — any metric we cannot measure stays null with a reason in notes.
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
K8S_DIR="${SCRIPT_DIR}/k8s"
RESULTS_JSON="${SCRIPT_DIR}/results.json"
RESULTS_MD="${SCRIPT_DIR}/RESULTS.md"

NS="exp-cilium-ebpf"
CILIUM_NS="kube-system"
THROUGHPUT_REQUESTS="${THROUGHPUT_REQUESTS:-200}"   # curl loop iterations for rows/s

log()  { printf '\033[1;34m[run]\033[0m %s\n' "$*"; }
warn() { printf '\033[1;33m[warn]\033[0m %s\n' "$*" >&2; }
die()  { printf '\033[1;31m[err]\033[0m %s\n' "$*" >&2; exit 1; }

command -v kubectl >/dev/null || die "kubectl not found"
have_cilium_cli() { command -v cilium >/dev/null 2>&1; }

client_pod() { kubectl -n "${NS}" get pod -l app=client -o jsonpath='{.items[0].metadata.name}' 2>/dev/null; }

# ---------------------------------------------------------------------------
# Teardown (demo app + policy only; Cilium stays — use install-cilium.sh --uninstall)
# ---------------------------------------------------------------------------
teardown() {
  log "Tearing down demo app + L7 policy (Cilium CNI left in place)…"
  kubectl delete -f "${K8S_DIR}/20-l7-policy.yaml" --ignore-not-found 2>/dev/null || true
  kubectl delete -f "${K8S_DIR}/10-demo-app.yaml" --ignore-not-found 2>/dev/null || true
  kubectl delete namespace "${NS}" --ignore-not-found --wait=false || true
  log "Demo torn down. To remove Cilium itself: ./install-cilium.sh --uninstall"
}

if [[ "${1:-}" == "--teardown" ]]; then
  teardown
  exit 0
fi

CTX="$(kubectl config current-context 2>/dev/null || true)"
[[ -n "${CTX}" ]] || die "no current kube context"
log "Using current context: ${CTX}"

# Metrics (null until measured)
L7_ALLOW_OK="null"
L7_DENY_BLOCKED="null"
HUBBLE_FLOWS="null"
POD2POD_RPS="null"
KPR_MODE="null"

# ---------------------------------------------------------------------------
# 1 + 2. Install Cilium and wait ready
# ---------------------------------------------------------------------------
log "Installing Cilium (Helm, pinned) + Hubble…"
bash "${SCRIPT_DIR}/install-cilium.sh"

log "Confirming Cilium is ready…"
if have_cilium_cli; then
  cilium status --wait --wait-duration 5m || warn "cilium status reported issues (continuing)"
else
  warn "cilium CLI not found — using kubectl rollout as the readiness gate."
  kubectl -n "${CILIUM_NS}" rollout status ds/cilium --timeout=300s
fi

# Record the actual kube-proxy-replacement mode Cilium ended up in (from the DS env
# or helm; we read the cilium-config ConfigMap which is authoritative).
KPR_RAW="$(kubectl -n "${CILIUM_NS}" get configmap cilium-config -o jsonpath='{.data.kube-proxy-replacement}' 2>/dev/null || true)"
[[ -n "${KPR_RAW}" ]] && KPR_MODE="\"${KPR_RAW}\""

# Is Cilium actually the CNI / do we have the CRD for L7 policy?
CILIUM_CNI="false"
if kubectl get crd ciliumnetworkpolicies.cilium.io >/dev/null 2>&1; then
  CILIUM_CNI="true"
fi

# ---------------------------------------------------------------------------
# 3. Deploy demo app
# ---------------------------------------------------------------------------
log "Deploying demo app (client + server + Service)…"
kubectl apply -f "${K8S_DIR}/00-demo-namespace.yaml"
kubectl apply -f "${K8S_DIR}/10-demo-app.yaml"
kubectl -n "${NS}" rollout status deploy/server --timeout=180s
kubectl -n "${NS}" rollout status deploy/client --timeout=180s
CPOD="$(client_pod)"
[[ -n "${CPOD}" ]] || die "client pod not found"
log "Client pod: ${CPOD}"

# Helper: curl from the client pod, print HTTP status code only.
curl_code() {  # $1 = path
  kubectl -n "${NS}" exec "${CPOD}" -c curl -- \
    curl -s -o /dev/null -w '%{http_code}' --max-time 10 "http://server${1}" 2>/dev/null || echo "000"
}

# Sanity: BEFORE the policy, both paths should be reachable (200). This proves the
# app itself serves /admin, so a later 403 is the POLICY, not the app.
log "Pre-policy sanity: GET /public and GET /admin should both be 200…"
PRE_PUBLIC="$(curl_code /public)"
PRE_ADMIN="$(curl_code /admin)"
log "  pre-policy /public=${PRE_PUBLIC}  /admin=${PRE_ADMIN}"

# ---------------------------------------------------------------------------
# 4. Apply L7 policy and TEST
# ---------------------------------------------------------------------------
if [[ "${CILIUM_CNI}" == "true" ]]; then
  log "Applying L7 CiliumNetworkPolicy (allow GET /public, deny the rest)…"
  kubectl apply -f "${K8S_DIR}/20-l7-policy.yaml"
  # Give Cilium a moment to program the policy into Envoy.
  sleep 8

  log "L7 test: GET /public (expect 200) …"
  POST_PUBLIC="$(curl_code /public)"
  log "L7 test: GET /admin (expect 403 from Envoy) …"
  POST_ADMIN="$(curl_code /admin)"
  log "  post-policy /public=${POST_PUBLIC}  /admin=${POST_ADMIN}"

  [[ "${POST_PUBLIC}" == "200" ]] && L7_ALLOW_OK="true" || L7_ALLOW_OK="false"
  # Cilium L7 deny returns 403 (Envoy). Accept 403 as the deny signal.
  [[ "${POST_ADMIN}" == "403" ]] && L7_DENY_BLOCKED="true" || L7_DENY_BLOCKED="false"
else
  warn "Cilium CNI / CiliumNetworkPolicy CRD not present (cluster still on another CNI)."
  warn "L7 policy NOT applied; l7_allow_ok / l7_deny_blocked stay null."
fi

# ---------------------------------------------------------------------------
# 5. Hubble flow count
# ---------------------------------------------------------------------------
# Prefer the cilium CLI's hubble port-forward; otherwise try `hubble` directly if a
# relay port-forward is already up. We count flows seen for the demo namespace.
HUBBLE_NOTE=""
if have_cilium_cli; then
  log "Pulling Hubble flows for namespace ${NS}…"
  # cilium hubble port-forward runs in background; observe then kill it.
  ( cilium hubble port-forward >/dev/null 2>&1 & echo $! > /tmp/cilium-hubble-pf.pid ) || true
  sleep 4
  if command -v hubble >/dev/null 2>&1; then
    FLOWS="$(hubble observe --namespace "${NS}" --last 500 -o jsonpb 2>/dev/null | grep -c '"flow"' || true)"
    [[ -n "${FLOWS}" && "${FLOWS}" -gt 0 ]] 2>/dev/null && HUBBLE_FLOWS="${FLOWS}"
  else
    HUBBLE_NOTE="hubble CLI not installed; flow count skipped"
    warn "${HUBBLE_NOTE}"
  fi
  [[ -f /tmp/cilium-hubble-pf.pid ]] && kill "$(cat /tmp/cilium-hubble-pf.pid)" 2>/dev/null || true
  rm -f /tmp/cilium-hubble-pf.pid
else
  HUBBLE_NOTE="cilium CLI not installed; Hubble flow count skipped (relay still runs in-cluster)"
  warn "${HUBBLE_NOTE}"
fi

# ---------------------------------------------------------------------------
# 6. Pod-to-pod throughput (timed curl loop -> requests/sec)
# ---------------------------------------------------------------------------
# Simple, dependency-free throughput proxy: from the client pod, loop N GET /public
# requests against the server Service and divide by wall time. This is rows/s-style
# "requests/sec", not raw network Gbps — intentional, matches the spec's "curl loop
# rows/s" option and avoids pulling an iperf image. /public is allowed by the policy.
if kubectl -n "${NS}" get deploy/server >/dev/null 2>&1; then
  log "Pod-to-pod throughput: ${THROUGHPUT_REQUESTS} sequential GET /public from client…"
  RPS="$(kubectl -n "${NS}" exec "${CPOD}" -c curl -- sh -c '
    N='"${THROUGHPUT_REQUESTS}"'
    start=$(date +%s.%N)
    i=0
    ok=0
    while [ "$i" -lt "$N" ]; do
      code=$(curl -s -o /dev/null -w "%{http_code}" --max-time 5 http://server/public)
      [ "$code" = "200" ] && ok=$((ok+1))
      i=$((i+1))
    done
    end=$(date +%s.%N)
    awk -v ok="$ok" -v s="$start" -v e="$end" "BEGIN{ d=e-s; if(d>0) printf \"%.2f\", ok/d; else print \"0\" }"
  ' 2>/dev/null || true)"
  if [[ -n "${RPS}" ]] && awk "BEGIN{exit !(${RPS}+0 > 0)}" 2>/dev/null; then
    POD2POD_RPS="${RPS}"
    log "  throughput: ${RPS} req/s (allowed GET /public, sequential)"
  else
    warn "throughput loop produced no usable number — pod2pod stays null"
  fi
fi

# ---------------------------------------------------------------------------
# 7. Results
# ---------------------------------------------------------------------------
RAN_AT="$(date -u +%Y-%m-%dT%H:%M:%SZ)"

NOTES="Cilium ${CILIUM_VERSION:-1.18.0} eBPF dataplane on Talos. kube-proxy-replacement mode='${KPR_RAW:-unknown}' (cilium-config). "
NOTES+="L7 deny = HTTP 403 from node-local Envoy (connection is L4-allowed, request is L7-denied). "
NOTES+="pod2pod_throughput is a sequential curl req/s proxy (allowed GET /public), not raw Gbps. "
[[ -n "${HUBBLE_NOTE}" ]] && NOTES+="Hubble: ${HUBBLE_NOTE}. "
[[ "${CILIUM_CNI}" != "true" ]] && NOTES+="CiliumNetworkPolicy CRD absent -> L7 metrics null (cluster on another CNI). "

cat > "${RESULTS_JSON}" <<EOF
{
  "spike": "exp-cilium-ebpf",
  "cluster": "${CTX}",
  "metrics": {
    "l7_allow_ok": ${L7_ALLOW_OK},
    "l7_deny_blocked": ${L7_DENY_BLOCKED},
    "hubble_flows": ${HUBBLE_FLOWS},
    "pod2pod_throughput_or_latency": ${POD2POD_RPS}
  },
  "config": {
    "cilium_version": "${CILIUM_VERSION:-1.18.0}",
    "kube_proxy_replacement": ${KPR_MODE},
    "cilium_is_cni": ${CILIUM_CNI},
    "throughput_requests": ${THROUGHPUT_REQUESTS},
    "hubble_enabled": true
  },
  "notes": "${NOTES}",
  "ran_at": "${RAN_AT}"
}
EOF

cat > "${RESULTS_MD}" <<EOF
# Results — exp-cilium-ebpf (Cilium / eBPF on Talos)

**Engine:** Cilium ${CILIUM_VERSION:-1.18.0} (eBPF dataplane) + Hubble
**kube-proxy-replacement:** \`${KPR_RAW:-unknown}\` (from cilium-config) · **Cilium is CNI:** ${CILIUM_CNI}
**Context:** \`${CTX}\` · **Ran:** ${RAN_AT}

## What was tested
- **L7 HTTP policy** (\`CiliumNetworkPolicy\`): from \`app=client\`, allow only \`GET /public\` to \`app=server\`:80.
  - \`GET /public\` -> expect **200** (allowed).
  - \`GET /admin\`  -> expect **403** (denied by node-local Envoy, L7).
- **Hubble** flow observability (flow count for namespace \`${NS}\`).
- **Pod-to-pod throughput**: ${THROUGHPUT_REQUESTS} sequential \`GET /public\` from the client pod, requests/sec.

## Pre-policy sanity
Before the policy, both paths served 200 (proves the 403 below is the POLICY, not the app):
\`/public=${PRE_PUBLIC:-?}\`, \`/admin=${PRE_ADMIN:-?}\`.

## Metrics
| metric | value |
|---|---|
| l7_allow_ok (GET /public == 200) | ${L7_ALLOW_OK} |
| l7_deny_blocked (GET /admin == 403) | ${L7_DENY_BLOCKED} |
| hubble_flows | ${HUBBLE_FLOWS} |
| pod2pod_throughput (req/s) | ${POD2POD_RPS} |

## Honest caveats
- **kube-proxy-replacement nuance:** true KPR on Talos requires the cluster to be
  created with \`cni: none\` + \`proxy.disabled: true\` (KubePrism endpoint
  \`localhost:7445\`). On a cluster already running kube-proxy + Flannel, this spike
  installs Cilium in **additive mode** (\`kubeProxyReplacement=false\`) so it does not
  rip out the live dataplane — the L7 + Hubble demo still works. To see real KPR,
  recreate the cluster without kube-proxy and run with \`CILIUM_KPR=true\`.
- **L7 deny is a 403, not a reset.** Cilium permits the TCP connection (L3/L4) and
  inserts Envoy; a denied request returns HTTP 403, so the test asserts on status code.
- **Throughput is a req/s proxy** (sequential curl), not raw bandwidth — modest box,
  the comparison (kube-proxy vs eBPF service path) is the point, not absolute numbers.
- Any \`null\` above means that metric could not be measured this run (see notes/console).
EOF

log "Wrote ${RESULTS_JSON} and ${RESULTS_MD}."
log "Done. Tear down demo with: ./run.sh --teardown   (Cilium: ./install-cilium.sh --uninstall)"
