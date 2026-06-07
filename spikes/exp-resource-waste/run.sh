#!/usr/bin/env bash
# run.sh — Kubernetes resource-waste / right-sizing experiment.
#
# Thesis (Hari's sizing point; ties to the book's worthiness.py): a Kubernetes
# cluster mostly runs at a fraction of what its workloads RESERVE. CAST AI's
# industry telemetry puts the typical cluster at ~8% CPU / ~20% memory utilization
# (used vs requested). This spike MEASURES that ratio on THIS cluster:
#
#   1. install a pinned metrics-server (Talos-correct --kubelet-insecure-tls),
#   2. deploy two over-requesting workloads (1 CPU / 1Gi each, idle) + one
#      right-sized control,
#   3. let usage settle, then collect for each workload:
#        requested CPU/mem (from the live pod spec) vs actual CPU/mem (kubectl top),
#   4. compute cluster-wide (this namespace) utilization % = used / requested
#      and the overprovisioning gap %, and write results.json + RESULTS.md.
#
# Numbers are MEASURED. If metrics-server can't serve metrics, the usage-derived
# fields stay the literal null with a reason in notes — never fabricated.
#
# Targets the CURRENT kube context (the spike's own cluster). It prints the context
# before applying anything and never switches contexts.
#
# Usage:
#   ./run.sh              apply metrics-server + workloads, settle, collect, write results
#   ./run.sh --teardown   delete the exp namespace AND the metrics-server it installed
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
K8S_DIR="${SCRIPT_DIR}/k8s"
NS="exp-resource-waste"
SPIKE="exp-resource-waste"
RESULTS_JSON="${SCRIPT_DIR}/results.json"
RESULTS_MD="${SCRIPT_DIR}/RESULTS.md"
SETTLE_SECONDS="${SETTLE_SECONDS:-60}"

log() { printf '\n=== %s ===\n' "$*" >&2; }

# --- teardown ---------------------------------------------------------------
if [[ "${1:-}" == "--teardown" ]]; then
  log "tearing down namespace ${NS}"
  kubectl delete namespace "${NS}" --ignore-not-found --wait=true
  log "removing metrics-server (installed by this spike)"
  kubectl delete -f "${K8S_DIR}/10-metrics-server.yaml" --ignore-not-found --wait=true
  echo "torn down." >&2
  exit 0
fi

command -v kubectl >/dev/null 2>&1 || { echo "error: kubectl not on PATH" >&2; exit 1; }

CTX="$(kubectl config current-context 2>/dev/null || echo '<none>')"
log "kube context: ${CTX}   (applying metrics-server into kube-system, workloads into ${NS})"

# --- apply metrics-server ---------------------------------------------------
log "applying metrics-server (v0.8.0, --kubelet-insecure-tls for Talos)"
kubectl apply -f "${K8S_DIR}/10-metrics-server.yaml"
log "waiting for metrics-server rollout"
kubectl -n kube-system rollout status deployment/metrics-server --timeout=180s || \
  echo "warning: metrics-server rollout did not report Ready in time." >&2

# --- apply workloads --------------------------------------------------------
log "applying demo workloads"
kubectl apply -f "${K8S_DIR}/00-namespace.yaml"
kubectl apply -f "${K8S_DIR}/20-workloads.yaml"
log "waiting for workloads to be Available"
for d in over-requester-a over-requester-b right-sized; do
  kubectl -n "${NS}" rollout status "deployment/${d}" --timeout=180s || \
    echo "warning: deployment/${d} not Available in time." >&2
done

# --- let usage settle and metrics-server populate ---------------------------
# metrics-server needs a couple of scrape intervals (15s each) before `top` works,
# and the idle workloads need a moment to drop to their resting CPU. Wait for the
# metrics API to actually answer for our pods, up to a cap, then settle.
log "waiting for the metrics API to serve pod metrics (up to ${SETTLE_SECONDS}s)"
METRICS_OK="no"
deadline=$(( $(date +%s) + SETTLE_SECONDS ))
while [[ $(date +%s) -lt ${deadline} ]]; do
  if kubectl -n "${NS}" top pods --no-headers >/dev/null 2>&1; then
    METRICS_OK="yes"; break
  fi
  sleep 5
done
if [[ "${METRICS_OK}" == "yes" ]]; then
  log "metrics available; letting idle workloads settle (${SETTLE_SECONDS}s)"
  end=$(( $(date +%s) + SETTLE_SECONDS ))
  while [[ $(date +%s) -lt ${end} ]]; do sleep 5; done
else
  echo "warning: metrics API never served pod metrics within the window." >&2
fi

# --- collect REQUESTED cpu/mem from the live pod specs ----------------------
# Sum requests across all running pods in the namespace. Output two integers:
#   <cpu_millicores> <mem_bytes>
log "collecting requested CPU/mem from pod specs"
REQ_RAW="$(kubectl -n "${NS}" get pods -o json 2>/dev/null || echo '{"items":[]}')"
read -r CPU_REQ_MILLI MEM_REQ_BYTES <<EOF
$(printf '%s' "${REQ_RAW}" | python3 -c '
import json, sys
def cpu_to_milli(s):
    s = str(s)
    if s.endswith("m"): return int(float(s[:-1]))
    return int(float(s) * 1000)
def mem_to_bytes(s):
    s = str(s); units = {"Ki":1024,"Mi":1024**2,"Gi":1024**3,"Ti":1024**4,
                         "K":1000,"M":1000**2,"G":1000**3,"T":1000**4}
    for u,m in units.items():
        if s.endswith(u): return int(float(s[:-len(u)]) * m)
    return int(float(s))
d = json.load(sys.stdin)
cpu = mem = 0
for p in d.get("items", []):
    if p.get("status",{}).get("phase") != "Running": continue
    for c in p.get("spec",{}).get("containers",[]):
        r = c.get("resources",{}).get("requests",{})
        if "cpu" in r: cpu += cpu_to_milli(r["cpu"])
        if "memory" in r: mem += mem_to_bytes(r["memory"])
print(cpu, mem)
')
EOF
CPU_REQ_MILLI="${CPU_REQ_MILLI:-0}"
MEM_REQ_BYTES="${MEM_REQ_BYTES:-0}"

# --- collect USED cpu/mem from metrics-server -------------------------------
# `kubectl top pods` columns: NAME  CPU(cores e.g. 3m)  MEMORY(e.g. 4Mi)
CPU_USED_MILLI="null"
MEM_USED_BYTES="null"
TOP_RAW=""
if [[ "${METRICS_OK}" == "yes" ]]; then
  log "collecting actual CPU/mem from metrics-server (kubectl top pods)"
  TOP_RAW="$(kubectl -n "${NS}" top pods --no-headers 2>/dev/null || true)"
  printf '%s\n' "${TOP_RAW}" > "${SCRIPT_DIR}/.last-top.txt"
  if [[ -n "${TOP_RAW}" ]]; then
    read -r CPU_USED_MILLI MEM_USED_BYTES <<EOF
$(printf '%s' "${TOP_RAW}" | python3 -c '
import sys
def cpu_to_milli(s):
    s = s.strip()
    if s.endswith("m"): return int(float(s[:-1]))
    if s.endswith("n"): return int(float(s[:-1]) / 1e6)   # nanocores -> milli
    if s.endswith("u"): return int(float(s[:-1]) / 1e3)   # microcores -> milli
    return int(float(s) * 1000)
def mem_to_bytes(s):
    s = s.strip(); units = {"Ki":1024,"Mi":1024**2,"Gi":1024**3,"Ti":1024**4}
    for u,m in units.items():
        if s.endswith(u): return int(float(s[:-len(u)]) * m)
    return int(float(s))
cpu = mem = 0; rows = 0
for line in sys.stdin:
    parts = line.split()
    if len(parts) < 3: continue
    cpu += cpu_to_milli(parts[1]); mem += mem_to_bytes(parts[2]); rows += 1
print(cpu if rows else "null", mem if rows else "null")
')
EOF
    CPU_USED_MILLI="${CPU_USED_MILLI:-null}"
    MEM_USED_BYTES="${MEM_USED_BYTES:-null}"
  fi
fi

# --- derive contract metrics (float math in python) -------------------------
# cpu_requested_cores  = CPU_REQ_MILLI / 1000
# cpu_used_cores       = CPU_USED_MILLI / 1000   (or null)
# cpu_utilization_pct  = 100 * used / requested  (or null)
# overprovision_gap_pct= 100 - cpu_utilization_pct (or null)   [reported on CPU]
log "computing utilization + overprovisioning gap"
read -r CPU_REQ_CORES CPU_USED_CORES CPU_UTIL_PCT \
        MEM_REQ_OUT MEM_USED_OUT MEM_UTIL_PCT \
        OVERPROV_GAP_PCT <<EOF
$(python3 -c '
import sys
cpu_req_milli = float("'"${CPU_REQ_MILLI}"'")
mem_req_bytes = float("'"${MEM_REQ_BYTES}"'")
cpu_used_raw  = "'"${CPU_USED_MILLI}"'"
mem_used_raw  = "'"${MEM_USED_BYTES}"'"

cpu_req_cores = round(cpu_req_milli/1000.0, 4)
mem_req_out   = int(mem_req_bytes)

def num(x):
    try: return float(x)
    except: return None

cpu_used_milli = num(cpu_used_raw)
mem_used_bytes = num(mem_used_raw)

if cpu_used_milli is None:
    cpu_used_cores = cpu_util = "null"
else:
    cpu_used_cores = round(cpu_used_milli/1000.0, 4)
    cpu_util = round(100.0*cpu_used_milli/cpu_req_milli, 2) if cpu_req_milli>0 else "null"

if mem_used_bytes is None:
    mem_used_out = mem_util = "null"
else:
    mem_used_out = int(mem_used_bytes)
    mem_util = round(100.0*mem_used_bytes/mem_req_bytes, 2) if mem_req_bytes>0 else "null"

# overprovision gap reported on CPU (the dimension the thesis leads with);
# memory gap is implied by mem_utilization_pct.
if cpu_util == "null":
    gap = "null"
else:
    gap = round(100.0 - cpu_util, 2)

print(cpu_req_cores, cpu_used_cores, cpu_util, mem_req_out, mem_used_out, mem_util, gap)
')
EOF

# --- notes: explain any nulls ----------------------------------------------
RAN_AT="$(date -u +%Y-%m-%dT%H:%M:%SZ)"
NOTES="Measured on cluster \`${CTX}\` in namespace ${NS}: 2 over-requesting idle workloads (1 CPU / 1Gi each) + 1 right-sized control, via metrics-server v0.8.0 (Talos --kubelet-insecure-tls). utilization = used/requested across the namespace's running pods."
if [[ "${CPU_UTIL_PCT}" == "null" || "${MEM_UTIL_PCT}" == "null" ]]; then
  NOTES="${NOTES} USAGE-DERIVED FIELDS LEFT null: metrics-server did not serve pod metrics for this namespace within ${SETTLE_SECONDS}s (APIService v1beta1.metrics.k8s.io unavailable, kubelet TLS, or scrape not warmed). Requests are still reported from pod specs. See .last-top.txt."
fi

# --- write results.json -----------------------------------------------------
log "writing ${RESULTS_JSON}"
cat > "${RESULTS_JSON}" <<EOF
{
  "spike": "${SPIKE}",
  "cluster": "${CTX}",
  "metrics": {
    "cpu_requested_cores": ${CPU_REQ_CORES},
    "cpu_used_cores": ${CPU_USED_CORES},
    "cpu_utilization_pct": ${CPU_UTIL_PCT},
    "mem_requested_bytes": ${MEM_REQ_OUT},
    "mem_used_bytes": ${MEM_USED_OUT},
    "mem_utilization_pct": ${MEM_UTIL_PCT},
    "overprovision_gap_pct": ${OVERPROV_GAP_PCT}
  },
  "notes": "${NOTES}",
  "ran_at": "${RAN_AT}"
}
EOF

# --- write RESULTS.md -------------------------------------------------------
log "writing ${RESULTS_MD}"
{
  echo "# Results — ${SPIKE}"
  echo
  echo "Kubernetes resource waste / right-sizing — requested vs actually used."
  echo
  echo "- **Cluster (kube context):** \`${CTX}\`"
  echo "- **Namespace:** ${NS}"
  echo "- **metrics-server:** v0.8.0 (Talos \`--kubelet-insecure-tls\`)"
  echo "- **Workloads:** over-requester-a, over-requester-b (1 CPU / 1Gi each, idle), right-sized (50m / 64Mi)"
  echo "- **Ran at (UTC):** ${RAN_AT}"
  echo
  echo "## Metrics (contract)"
  echo
  echo "| metric | value |"
  echo "|---|---|"
  echo "| cpu_requested_cores | ${CPU_REQ_CORES} |"
  echo "| cpu_used_cores | ${CPU_USED_CORES} |"
  echo "| cpu_utilization_pct | ${CPU_UTIL_PCT} |"
  echo "| mem_requested_bytes | ${MEM_REQ_OUT} |"
  echo "| mem_used_bytes | ${MEM_USED_OUT} |"
  echo "| mem_utilization_pct | ${MEM_UTIL_PCT} |"
  echo "| overprovision_gap_pct (CPU) | ${OVERPROV_GAP_PCT} |"
  echo
  echo "## Per-pod actuals (kubectl top)"
  echo
  echo '```'
  printf '%s\n' "${TOP_RAW:-<metrics-server served no rows>}"
  echo '```'
  echo
  echo "## Industry comparison"
  echo
  echo "CAST AI's Kubernetes cost-benchmark reports typical clusters run at ~8% CPU"
  echo "and ~20% memory utilization (provisioned vs requested). This run measured"
  echo "**cpu_utilization_pct = ${CPU_UTIL_PCT}** and **mem_utilization_pct = ${MEM_UTIL_PCT}**"
  echo "for the experiment namespace — the overprovisioning gap is capacity you reserve"
  echo "and pay for but never use. See README.md for how this ties to the"
  echo "k8s-worthiness heuristic (~15-20 services)."
  echo
  echo "## Notes"
  echo
  echo "${NOTES}"
} > "${RESULTS_MD}"

log "done"
echo "results.json:" >&2
cat "${RESULTS_JSON}" >&2
