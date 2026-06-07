#!/usr/bin/env bash
# exp-hpa-scaling — HorizontalPodAutoscaler scale-up latency under synthetic CPU
# load, measured end-to-end on a real Talos bare-metal cluster.
#
# Thesis: "elasticity" is a promise; the SRE question is HOW FAST. From the
# instant real load arrives, how long until Kubernetes has (a) noticed via
# metrics-server, (b) asked the HPA controller to scale, and (c) brought a NEW
# replica all the way to Ready and serving? And after load stops, how long to
# scale back in? This spike MEASURES those wall-clock latencies on this cluster.
#
# Method
#   1. Install a pinned metrics-server (Talos --kubelet-insecure-tls) — HPA's
#      CPU metric source. (Skipped if already present.)
#   2. Deploy a CPU-burner Deployment (1 replica, 150m CPU request) + Service +
#      an autoscaling/v2 HPA: target 50% CPU, min 1, max 6, snappy scale-up
#      behavior (stabilizationWindow 0).
#   3. Settle until metrics-server serves the target's CPU and HPA shows 1/1.
#   4. T0 = start synthetic load (a generator pod fires 24 concurrent continuous
#      /burn requests). Poll the Deployment's replica count + the HPA's observed
#      CPU% every POLL_S seconds, timestamping every transition.
#   5. Derive, from the timestamp series:
#        scale_up_latency_s        = T(first replica beyond 1 becomes Ready) - T0
#        time_to_stabilize_s       = T(replica count stops changing for STABLE_S) - T0
#        peak_ready_replicas       = max Ready replicas observed
#        peak_cpu_utilization_pct  = max HPA-observed CPU% (how hard we drove it)
#   6. Tn = stop load (delete generator). Keep polling up to SCALEDOWN_CAP_S for
#        scale_down_latency_s      = T(replicas back to minReplicas) - Tn  (or null)
#   7. Write results.json + RESULTS.md. Any metric we cannot measure stays null
#      with a reason in notes — NEVER fabricated.
#
# Uses the CURRENT kube context (does not switch it). Idempotent. Guardrails:
# own namespace only; pods <= 0.5 CPU / 128Mi; HPA caps total at 6 small pods.
#
# Usage:
#   ./run.sh              deploy -> load -> measure -> results
#   ./run.sh --teardown   delete the namespace AND the metrics-server it installed
#                         (only removes metrics-server if THIS spike installed it)
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
K8S_DIR="${SCRIPT_DIR}/k8s"
NS="exp-hpa-scaling"
SPIKE="exp-hpa-scaling"
RESULTS_JSON="${SCRIPT_DIR}/results.json"
RESULTS_MD="${SCRIPT_DIR}/RESULTS.md"
SERIES_LOG="${SCRIPT_DIR}/series.log"
INSTALLED_MARKER="${SCRIPT_DIR}/.installed-metrics-server"

# Timing knobs (seconds)
SETTLE_S="${SETTLE_S:-90}"          # cap to wait for metrics + HPA to read 1/1
POLL_S="${POLL_S:-3}"               # polling interval for the replica/CPU series
LOAD_CAP_S="${LOAD_CAP_S:-240}"     # cap on the load-on measurement window
STABLE_S="${STABLE_S:-30}"          # replica count unchanged this long => stabilized
SCALEDOWN_CAP_S="${SCALEDOWN_CAP_S:-300}"  # cap to observe scale-down after load off

log()  { printf '\033[1;34m[run]\033[0m %s\n'  "$*"; }
warn() { printf '\033[1;33m[warn]\033[0m %s\n' "$*" >&2; }
die()  { printf '\033[1;31m[err]\033[0m %s\n'  "$*" >&2; exit 1; }

# --- teardown ---------------------------------------------------------------
if [[ "${1:-}" == "--teardown" ]]; then
  log "tearing down namespace ${NS}"
  kubectl delete namespace "${NS}" --ignore-not-found --wait=true
  if [[ -f "${INSTALLED_MARKER}" ]]; then
    log "removing metrics-server (installed by THIS spike)"
    kubectl delete -f "${K8S_DIR}/10-metrics-server.yaml" --ignore-not-found --wait=true || true
    rm -f "${INSTALLED_MARKER}"
  else
    log "leaving metrics-server in place (it was already present before this spike)"
  fi
  echo "torn down." >&2
  exit 0
fi

command -v kubectl >/dev/null 2>&1 || die "kubectl not on PATH"
CTX="$(kubectl config current-context 2>/dev/null || echo '<none>')"
log "kube context: ${CTX}"

# --- metrics-server (install only if absent) --------------------------------
if kubectl -n kube-system get deployment metrics-server >/dev/null 2>&1; then
  log "metrics-server already present — reusing it (not installing)"
else
  log "installing metrics-server v0.8.0 (Talos --kubelet-insecure-tls)"
  kubectl apply -f "${K8S_DIR}/10-metrics-server.yaml"
  touch "${INSTALLED_MARKER}"
fi
log "waiting for metrics-server rollout"
kubectl -n kube-system rollout status deployment/metrics-server --timeout=180s \
  || warn "metrics-server rollout not Ready in time"

# --- deploy target + HPA ----------------------------------------------------
log "applying namespace, app, deployment + service + HPA"
kubectl apply -f "${K8S_DIR}/00-namespace.yaml"
kubectl apply -f "${K8S_DIR}/20-app-configmap.yaml"
kubectl apply -f "${K8S_DIR}/30-deployment.yaml"
log "waiting for cpu-burner to be Available (1/1)"
kubectl -n "${NS}" rollout status deployment/cpu-burner --timeout=180s \
  || die "cpu-burner did not become Available"

# --- settle: wait for HPA to read real CPU (not <unknown>) and sit at 1 -------
log "waiting (up to ${SETTLE_S}s) for the HPA to read CPU metrics and rest at 1 replica"
settle_deadline=$(( $(date +%s) + SETTLE_S ))
HPA_READY="no"
while [[ $(date +%s) -lt ${settle_deadline} ]]; do
  # TARGETS column like "cpu: 1%/50%"; <unknown> means metrics not flowing yet
  tgt="$(kubectl -n "${NS}" get hpa cpu-burner --no-headers 2>/dev/null | awk '{print $4}')"
  if [[ -n "${tgt}" && "${tgt}" != *"unknown"* ]]; then
    HPA_READY="yes"; log "HPA reading CPU: ${tgt}"; break
  fi
  sleep "${POLL_S}"
done
[[ "${HPA_READY}" == "yes" ]] || warn "HPA never reported a numeric CPU target within ${SETTLE_S}s"

# --- helpers to read live state ---------------------------------------------
ready_replicas() {
  kubectl -n "${NS}" get deployment cpu-burner \
    -o jsonpath='{.status.readyReplicas}' 2>/dev/null || echo ""
}
hpa_cpu_pct() {
  # parse "cpu: 73%/50%" -> 73 ; "<unknown>/50%" -> empty
  kubectl -n "${NS}" get hpa cpu-burner --no-headers 2>/dev/null \
    | awk '{print $4}' | sed -E 's#%?/.*##' | grep -Eo '^[0-9]+' || echo ""
}

: > "${SERIES_LOG}"
record() {  # epoch  ready  cpu%   -> append + echo
  local t r c
  t="$1"; r="$2"; c="$3"
  printf '%s ready=%s cpu=%s\n' "${t}" "${r}" "${c}" >> "${SERIES_LOG}"
}

# --- T0: start synthetic load ----------------------------------------------
log "starting synthetic load (generator pod, 24 concurrent /burn loops)"
kubectl delete pod load-generator -n "${NS}" --ignore-not-found --wait=true >/dev/null 2>&1 || true
kubectl apply -f "${K8S_DIR}/40-load-generator.yaml"
T0="$(date +%s)"
log "T0 (load start, epoch) = ${T0}"

# --- poll the scale-up window -----------------------------------------------
# Track:
#   first_scaleup_ready_ts : first time readyReplicas > 1
#   peak_ready             : max readyReplicas
#   peak_cpu               : max HPA cpu%
#   stabilize_ts           : when replica count has been unchanged for STABLE_S
log "polling scale-up for up to ${LOAD_CAP_S}s (interval ${POLL_S}s)"
FIRST_SCALEUP_TS=""
PEAK_READY=1
PEAK_CPU=0
STABILIZE_TS=""
last_count=""
last_change_ts="${T0}"
load_deadline=$(( T0 + LOAD_CAP_S ))
while [[ $(date +%s) -lt ${load_deadline} ]]; do
  now="$(date +%s)"
  r="$(ready_replicas)"; r="${r:-0}"
  c="$(hpa_cpu_pct)";    c="${c:-0}"
  record "${now}" "${r}" "${c}"

  [[ "${r}" =~ ^[0-9]+$ ]] || r=0
  [[ "${c}" =~ ^[0-9]+$ ]] || c=0
  (( r > PEAK_READY )) && PEAK_READY="${r}"
  (( c > PEAK_CPU ))   && PEAK_CPU="${c}"

  if [[ -z "${FIRST_SCALEUP_TS}" && "${r}" -gt 1 ]]; then
    FIRST_SCALEUP_TS="${now}"
    log "first new replica Ready at epoch ${now} (readyReplicas=${r})"
  fi

  # stabilization: replica count unchanged AND already scaled out (>1) for STABLE_S
  if [[ "${r}" != "${last_count}" ]]; then
    last_count="${r}"; last_change_ts="${now}"
  fi
  if [[ -z "${STABILIZE_TS}" && "${r}" -gt 1 && $(( now - last_change_ts )) -ge ${STABLE_S} ]]; then
    STABILIZE_TS="${now}"
    log "replica count stable at ${r} for ${STABLE_S}s -> stabilized at epoch ${now}"
    break
  fi
  sleep "${POLL_S}"
done

# --- Tn: stop load, observe scale-down --------------------------------------
log "stopping synthetic load (deleting generator)"
kubectl delete pod load-generator -n "${NS}" --ignore-not-found --wait=true >/dev/null 2>&1 || true
TN="$(date +%s)"
log "Tn (load stop, epoch) = ${TN}"

log "observing scale-down for up to ${SCALEDOWN_CAP_S}s (back to minReplicas=1)"
SCALEDOWN_TS=""
sd_deadline=$(( TN + SCALEDOWN_CAP_S ))
while [[ $(date +%s) -lt ${sd_deadline} ]]; do
  now="$(date +%s)"
  r="$(ready_replicas)"; r="${r:-0}"
  c="$(hpa_cpu_pct)";    c="${c:-0}"
  record "${now}" "${r}" "${c}"
  if [[ "${r}" == "1" ]]; then
    SCALEDOWN_TS="${now}"
    log "scaled back to 1 replica at epoch ${now}"
    break
  fi
  sleep "${POLL_S}"
done

# --- derive metrics ---------------------------------------------------------
calc() { # python float diff or null
  python3 -c '
import sys
a,b = sys.argv[1], sys.argv[2]
try:
    print(round(float(a)-float(b), 2))
except Exception:
    print("null")
' "$1" "$2"
}

SCALE_UP_LATENCY="null"
[[ -n "${FIRST_SCALEUP_TS}" ]] && SCALE_UP_LATENCY="$(calc "${FIRST_SCALEUP_TS}" "${T0}")"
TIME_TO_STABILIZE="null"
[[ -n "${STABILIZE_TS}" ]] && TIME_TO_STABILIZE="$(calc "${STABILIZE_TS}" "${T0}")"
SCALE_DOWN_LATENCY="null"
[[ -n "${SCALEDOWN_TS}" ]] && SCALE_DOWN_LATENCY="$(calc "${SCALEDOWN_TS}" "${TN}")"

log "scale_up_latency_s     = ${SCALE_UP_LATENCY}"
log "time_to_stabilize_s    = ${TIME_TO_STABILIZE}"
log "peak_ready_replicas    = ${PEAK_READY}"
log "peak_cpu_utilization   = ${PEAK_CPU}"
log "scale_down_latency_s   = ${SCALE_DOWN_LATENCY}"

# --- notes ------------------------------------------------------------------
RAN_AT="$(date -u +%Y-%m-%dT%H:%M:%SZ)"
NOTES="Measured on cluster \`${CTX}\`, namespace ${NS}. CPU-burner Deployment (150m CPU request, no CPU limit, /burn busy-loop that yields the GIL) behind a Service, autoscaling/v2 HPA target 50% CPU min=1 max=6 with scaleUp stabilizationWindow=0. T0=load start (8 concurrent /burn?ms=100 loops from a generator pod). scale_up_latency_s = (first time readyReplicas>1) - T0. time_to_stabilize_s = (replica count unchanged for ${STABLE_S}s, while >1) - T0. peak_cpu_utilization_pct is the max HPA-observed CPU% (HPA sees average across replicas, so it can read near 50% once spread). scale_down_latency_s = (back to 1 replica) - load-stop; HPA scaleDown stabilizationWindow=60s, capped at ${SCALEDOWN_CAP_S}s observation."
if [[ "${SCALE_UP_LATENCY}" == "null" ]]; then
  NOTES="${NOTES} SCALE-UP LEFT null: the deployment never went beyond 1 Ready replica within ${LOAD_CAP_S}s (metrics not flowing, or load too light to cross the 50% target). See series.log."
fi
if [[ "${SCALE_DOWN_LATENCY}" == "null" ]]; then
  NOTES="${NOTES} scale_down_latency_s left null: did not return to 1 replica within the ${SCALEDOWN_CAP_S}s scale-down observation cap."
fi

# --- write results.json -----------------------------------------------------
log "writing ${RESULTS_JSON}"
cat > "${RESULTS_JSON}" <<EOF
{
  "spike": "${SPIKE}",
  "cluster": "${CTX}",
  "metrics": {
    "scale_up_latency_s": ${SCALE_UP_LATENCY},
    "time_to_stabilize_s": ${TIME_TO_STABILIZE},
    "peak_ready_replicas": ${PEAK_READY},
    "peak_cpu_utilization_pct": ${PEAK_CPU},
    "scale_down_latency_s": ${SCALE_DOWN_LATENCY}
  },
  "config": {
    "image": "python:3.12-slim",
    "cpu_request_milli": 150,
    "hpa_target_cpu_pct": 50,
    "hpa_min_replicas": 1,
    "hpa_max_replicas": 6,
    "scaleup_stabilization_s": 0,
    "scaledown_stabilization_s": 60,
    "load_concurrency": 8,
    "burn_ms_per_request": 100,
    "poll_interval_s": ${POLL_S}
  },
  "notes": "${NOTES}",
  "ran_at": "${RAN_AT}"
}
EOF

# --- write RESULTS.md -------------------------------------------------------
log "writing ${RESULTS_MD}"
{
  echo "# Results — ${SPIKE} (HPA scale-up latency, measured)"
  echo
  echo "How fast does Kubernetes' HorizontalPodAutoscaler actually react to real"
  echo "CPU load — from load arriving to a NEW replica serving, and back again?"
  echo
  echo "- **Cluster (kube context):** \`${CTX}\`"
  echo "- **Namespace:** ${NS}"
  echo "- **Target:** cpu-burner Deployment (150m CPU request, \`/burn\` busy-loop), Service in front"
  echo "- **HPA:** autoscaling/v2, 50% CPU target, min 1 / max 6, scaleUp stabilization 0s"
  echo "- **Load:** generator pod, 8 concurrent continuous \`/burn?ms=100\` loops"
  echo "- **metrics-server:** v0.8.0 (Talos \`--kubelet-insecure-tls\`)"
  echo "- **Ran at (UTC):** ${RAN_AT}"
  echo
  echo "## Metrics (contract)"
  echo
  echo "| metric | value |"
  echo "|---|---|"
  echo "| scale_up_latency_s | ${SCALE_UP_LATENCY} |"
  echo "| time_to_stabilize_s | ${TIME_TO_STABILIZE} |"
  echo "| peak_ready_replicas | ${PEAK_READY} |"
  echo "| peak_cpu_utilization_pct | ${PEAK_CPU} |"
  echo "| scale_down_latency_s | ${SCALE_DOWN_LATENCY} |"
  echo
  echo "## The learning"
  echo
  echo "Autoscaling latency is the sum of several pipeline stages: metrics-server"
  echo "scrape interval (15s here), the HPA controller sync period (~15s default),"
  echo "the scheduler placing the new pod, the image already being cached, and the"
  echo "readiness probe passing. \`scale_up_latency_s\` is the end-to-end wall clock"
  echo "of all of that. \`time_to_stabilize_s\` shows how long until the replica"
  echo "count settles at the level that holds CPU near the 50% target."
  echo "Scale-down is deliberately slower (60s stabilization window) to avoid"
  echo "flapping — a real production default is 300s."
  echo
  echo "## Honest caveats"
  echo
  echo "- Small bare-metal cluster (1 worker, 4 vCPU); the image is pre-cached after"
  echo "  the first pull, so cold-image pull time is largely excluded from scale-up."
  echo "- HPA reads AVERAGE CPU across replicas, so observed CPU% can sit near the"
  echo "  target once load spreads; \`peak_cpu_utilization_pct\` is the max seen."
  echo "- Any \`null\` means that metric could not be measured this run (see series.log)."
  echo
  echo "Raw poll series: \`series.log\` (epoch, readyReplicas, HPA cpu%)."
} > "${RESULTS_MD}"

log "wrote ${RESULTS_JSON} and ${RESULTS_MD}"
log "done. tear down with: ./run.sh --teardown"
echo "results.json:" >&2
cat "${RESULTS_JSON}" >&2
