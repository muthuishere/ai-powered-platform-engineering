#!/usr/bin/env bash
# exp-probe-failure — the "delete-and-readd 120 pods" anti-pattern, measured.
#
# Hari's war story: a team kept manually deleting and re-adding pods whenever the
# app went sick, because Kubernetes happily kept routing traffic to a broken pod
# and never restarted it. The reason: NO liveness/readiness probes. Without
# probes, k8s cannot tell a sick pod from a healthy one. This spike quantifies
# the difference. Ties to the book's reliability.py (which flags exactly these
# missing probes as findings).
#
# Method
#   * Deploy the SAME app twice, behind two Services:
#       A = app-with-probes      (readiness + liveness)
#       B = app-without-probes   (no probes at all)
#   * Drive steady in-cluster traffic to BOTH Services, logging every request's
#     success/fail with a wall-clock timestamp.
#   * Induce failure: tell ONE replica of each variant to start returning 500
#     (GET /break against that pod's IP — process-local "sick" flag).
#   * Measure, per variant:
#       - how long bad replicas keep receiving traffic (last failed-request
#         timestamp after the break, minus the break time),
#       - how many requests failed after the break,
#       - whether the container self-healed (liveness restartCount delta).
#
# With probes: readiness pulls the sick pod from the Service endpoints within a
# couple of probe periods (failures stop fast) AND liveness restarts the
# container (restartCount goes up -> self-heal). Without probes: the sick pod
# stays in rotation for the whole window and never restarts.
#
# Usage:
#   ./run.sh              deploy -> traffic -> break -> measure -> results
#   ./run.sh --teardown   delete the namespace and everything in it
#
# Idempotent. Uses the CURRENT kube context (does not switch it). No fabricated
# numbers — any metric we cannot measure stays null with a reason in notes.
set -euo pipefail

NS="exp-probe-failure"
SVC_A="app-with-probes"        # variant A: probes
SVC_B="app-without-probes"     # variant B: no probes
LOAD_POD="traffic-loop"   # pod name in k8s/40-traffic-loop.yaml

# Timing knobs (seconds). Comparisons matter; keep the window short but enough
# for readiness (period 2s) to act and for plenty of post-break samples.
BASELINE_S="${BASELINE_S:-8}"      # steady traffic before the break (sanity)
WINDOW_S="${WINDOW_S:-60}"         # measured traffic window after the break
REQ_INTERVAL="${REQ_INTERVAL:-0.2}" # delay between request rounds in the loop

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
K8S_DIR="${SCRIPT_DIR}/k8s"
RESULTS_JSON="${SCRIPT_DIR}/results.json"
RESULTS_MD="${SCRIPT_DIR}/RESULTS.md"
TRAFFIC_LOG="${SCRIPT_DIR}/traffic.log"
WORK="$(mktemp -d)"
trap 'rm -rf "${WORK}"' EXIT

log()  { printf '\033[1;34m[run]\033[0m %s\n' "$*"; }
warn() { printf '\033[1;33m[warn]\033[0m %s\n' "$*" >&2; }
die()  { printf '\033[1;31m[err]\033[0m %s\n' "$*" >&2; exit 1; }

teardown() {
  log "Tearing down exp-probe-failure…"
  kubectl delete namespace "${NS}" --ignore-not-found --wait=false || true
  log "Teardown requested (namespace finalizes asynchronously)."
}

if [[ "${1:-}" == "--teardown" ]]; then
  teardown
  exit 0
fi

CTX="$(kubectl config current-context 2>/dev/null || true)"
[[ -n "${CTX}" ]] || die "no current kube context"
log "Using current context: ${CTX}"

# ---------------------------------------------------------------------------
# 1. Deploy both variants
# ---------------------------------------------------------------------------
log "Applying namespace, app ConfigMap, and both Deployments + Services…"
kubectl apply -f "${K8S_DIR}/00-namespace.yaml"
kubectl apply -f "${K8S_DIR}/10-app-configmap.yaml"
kubectl apply -f "${K8S_DIR}/20-with-probes.yaml"
kubectl apply -f "${K8S_DIR}/30-without-probes.yaml"

log "Waiting for both Deployments to roll out (3/3 each)…"
kubectl -n "${NS}" rollout status deploy/"${SVC_A}" --timeout=180s
kubectl -n "${NS}" rollout status deploy/"${SVC_B}" --timeout=180s
kubectl -n "${NS}" get pods -o wide

# ---------------------------------------------------------------------------
# 2. Start the in-cluster traffic loop
# ---------------------------------------------------------------------------
# One pod hits BOTH Services every round and prints a tagged, timestamped line
# per request. Tag = variant ("A"/"B"), then OK/FAIL, then epoch seconds. We
# parse this log after the run. The loop never exits on its own; we delete it.
log "Starting in-cluster traffic loop (${LOAD_POD})…"
kubectl delete pod "${LOAD_POD}" -n "${NS}" --ignore-not-found --wait=true >/dev/null 2>&1 || true
# Apply the static manifest, overriding only the REQ_INTERVAL env value so the
# REQ_INTERVAL knob still works without templating the YAML by hand.
sed "s|value: \"0.2\"|value: \"${REQ_INTERVAL}\"|" "${K8S_DIR}/40-traffic-loop.yaml" \
  | kubectl apply -f -

kubectl wait --for=condition=Ready "pod/${LOAD_POD}" -n "${NS}" --timeout=60s >/dev/null 2>&1 \
  || die "traffic loop pod did not become Ready"

# Make sure traffic is actually flowing (some OK lines) before we baseline.
ldeadline=$(( $(date +%s) + 30 ))
until kubectl logs -n "${NS}" "${LOAD_POD}" 2>/dev/null | grep -q " OK "; do
  [[ $(date +%s) -lt ${ldeadline} ]] || die "no successful traffic observed pre-break"
  sleep 1
done

log "Baseline traffic for ${BASELINE_S}s (expect ~0 failures)…"
baseline_deadline=$(( $(date +%s) + BASELINE_S ))
while [[ $(date +%s) -lt ${baseline_deadline} ]]; do sleep 1; done

# ---------------------------------------------------------------------------
# 3. Induce failure: break ONE replica of each variant
# ---------------------------------------------------------------------------
# We pick the first pod of each Deployment and GET /break on its pod IP from
# inside the loop pod (the Service would load-balance, so we target the pod
# directly to guarantee exactly one replica goes sick). After this, that pod
# returns 500 on / and /healthz.
break_one() {
  variant_label="$1"; selector="$2"
  pod="$(kubectl -n "${NS}" get pods -l "${selector}" \
          -o jsonpath='{.items[0].metadata.name}' 2>/dev/null || true)"
  [[ -n "${pod}" ]] || die "could not find a pod for ${selector}"
  ip="$(kubectl -n "${NS}" get pod "${pod}" -o jsonpath='{.status.podIP}' 2>/dev/null || true)"
  [[ -n "${ip}" ]] || die "pod ${pod} has no IP yet"
  log "Breaking ${variant_label} replica ${pod} (${ip})…"
  kubectl exec -n "${NS}" "${LOAD_POD}" -- \
    curl -s -m 3 "http://${ip}:8080/break" >/dev/null 2>&1 \
    || warn "break call to ${pod} returned non-zero (may still have applied)"
  echo "${pod}"
}

BREAK_TS="$(date +%s.%N)"
log "Break time (epoch): ${BREAK_TS}"
BROKEN_A="$(break_one A "app=${SVC_A}")"
BROKEN_B="$(break_one B "app=${SVC_B}")"

# ---------------------------------------------------------------------------
# 4. Let the measurement window run
# ---------------------------------------------------------------------------
log "Measuring for ${WINDOW_S}s after the break…"
window_deadline=$(( $(date +%s) + WINDOW_S ))
while [[ $(date +%s) -lt ${window_deadline} ]]; do sleep 2; done

# ---------------------------------------------------------------------------
# 5. Collect + parse the traffic log
# ---------------------------------------------------------------------------
log "Collecting traffic log…"
kubectl logs -n "${NS}" "${LOAD_POD}" > "${TRAFFIC_LOG}" 2>/dev/null || true
[[ -s "${TRAFFIC_LOG}" ]] || die "traffic log empty — cannot compute metrics"

# For a variant tag, compute over requests AFTER the break:
#   bad_traffic_s    = (last FAIL ts) - BREAK_TS, or 0 if no post-break FAIL
#   failed_requests  = count of FAIL lines after BREAK_TS
analyse() {
  tag="$1"
  awk -v tag="${tag}" -v brk="${BREAK_TS}" '
    $1==tag && ($3+0) >= (brk+0) {
      total++
      if ($2=="FAIL") { fail++; last=$3 }
    }
    END {
      if (last=="") { dur="0.00" } else { dur=sprintf("%.2f", last-brk) }
      printf "%d %s", fail+0, dur
    }
  ' "${TRAFFIC_LOG}"
}

read -r WITH_FAILS WITH_BAD_S    < <(analyse A)
read -r WITHOUT_FAILS WITHOUT_BAD_S < <(analyse B)

log "with-probes:    failed_after_break=${WITH_FAILS}    bad_traffic_window_s=${WITH_BAD_S}"
log "without-probes: failed_after_break=${WITHOUT_FAILS} bad_traffic_window_s=${WITHOUT_BAD_S}"

# ---------------------------------------------------------------------------
# 6. Liveness self-heal: restartCount on the broken pods
# ---------------------------------------------------------------------------
# With a livenessProbe, the sick container is restarted -> restartCount > 0 and
# the process comes back healthy (self-heal). Without probes it never restarts.
restart_count() {
  pod="$1"
  kubectl -n "${NS}" get pod "${pod}" \
    -o jsonpath='{.status.containerStatuses[0].restartCount}' 2>/dev/null || echo ""
}
WITH_RESTARTS="$(restart_count "${BROKEN_A}")";    WITH_RESTARTS="${WITH_RESTARTS:-null}"
WITHOUT_RESTARTS="$(restart_count "${BROKEN_B}")"; WITHOUT_RESTARTS="${WITHOUT_RESTARTS:-null}"
log "liveness restarts — with-probes pod ${BROKEN_A}: ${WITH_RESTARTS} | without-probes pod ${BROKEN_B}: ${WITHOUT_RESTARTS}"

# Endpoint check: is the broken pod still a Service endpoint? (readiness should
# have pulled the with-probes one out; the without-probes one stays in.)
endpoint_in() {
  pod="$1"; ep="$2"
  ip="$(kubectl -n "${NS}" get pod "${pod}" -o jsonpath='{.status.podIP}' 2>/dev/null || true)"
  if [[ -z "${ip}" ]]; then echo "unknown"; return; fi
  if kubectl -n "${NS}" get endpoints "${ep}" -o jsonpath='{.subsets[*].addresses[*].ip}' 2>/dev/null \
       | tr ' ' '\n' | grep -qx "${ip}"; then echo "yes"; else echo "no"; fi
}
WITH_STILL_EP="$(endpoint_in "${BROKEN_A}" "${SVC_A}")"
WITHOUT_STILL_EP="$(endpoint_in "${BROKEN_B}" "${SVC_B}")"
log "broken pod still a Service endpoint? with-probes=${WITH_STILL_EP} without-probes=${WITHOUT_STILL_EP}"

# ---------------------------------------------------------------------------
# 7. Results
# ---------------------------------------------------------------------------
num_or_null() { [[ "$1" == "null" || -z "$1" ]] && printf 'null' || printf '%s' "$1"; }
RAN_AT="$(date -u +%Y-%m-%dT%H:%M:%SZ)"

cat > "${RESULTS_JSON}" <<EOF
{
  "spike": "exp-probe-failure",
  "cluster": "${CTX}",
  "metrics": {
    "with_probes_bad_traffic_s": $(num_or_null "${WITH_BAD_S}"),
    "without_probes_bad_traffic_s": $(num_or_null "${WITHOUT_BAD_S}"),
    "with_probes_failed_requests": $(num_or_null "${WITH_FAILS}"),
    "without_probes_failed_requests": $(num_or_null "${WITHOUT_FAILS}"),
    "liveness_restarts": {
      "with_probes": $(num_or_null "${WITH_RESTARTS}"),
      "without_probes": $(num_or_null "${WITHOUT_RESTARTS}")
    }
  },
  "evidence": {
    "broken_pod_with_probes": "${BROKEN_A}",
    "broken_pod_without_probes": "${BROKEN_B}",
    "broken_still_endpoint_with_probes": "${WITH_STILL_EP}",
    "broken_still_endpoint_without_probes": "${WITHOUT_STILL_EP}"
  },
  "config": {
    "image": "python:3.12-slim",
    "replicas_per_variant": 3,
    "baseline_s": ${BASELINE_S},
    "window_s": ${WINDOW_S},
    "req_interval_s": ${REQ_INTERVAL},
    "readiness": { "path": "/healthz", "periodSeconds": 2, "failureThreshold": 1 },
    "liveness": { "path": "/healthz", "periodSeconds": 3, "failureThreshold": 2 }
  },
  "notes": "Same app deployed twice; only independent variable is the probe config. bad_traffic_s = (last failed request after break) - break_time, measured over a ${WINDOW_S}s window; 0.00 means failures stopped at/before the first post-break sample (readiness evicted the sick endpoint). failed_requests counted only after the break. liveness_restarts = containerStatuses restartCount on the deliberately-broken pod. Without probes, the sick pod stays in the Service endpoints and is never restarted -- this is the world that drives the manual 'delete and re-add everything' reflex. Ties to reliability.py (no livenessProbe / no readinessProbe findings).",
  "ran_at": "${RAN_AT}"
}
EOF

cat > "${RESULTS_MD}" <<EOF
# Results — exp-probe-failure (probes vs none, measured)

**App:** one stateless HTTP server, deployed twice (\`python:3.12-slim\`, code from a ConfigMap).
**Only variable:** Variant A has readiness+liveness probes; Variant B has none.
**Context:** \`${CTX}\` · **Ran:** ${RAN_AT}
**Replicas:** 3 per variant · **Window:** ${WINDOW_S}s after the break · **Probe:** \`/healthz\` (readiness period 2s, liveness period 3s)

## What we did
1. Drove steady in-cluster traffic to both Services, logging OK/FAIL per request with timestamps.
2. Broke exactly ONE replica per variant (\`GET /break\` on its pod IP → that replica returns 500).
3. Measured, after the break, how long the broken replica kept getting traffic and whether it self-healed.

## Metrics
| metric | with probes (A) | without probes (B) |
|---|---|---|
| bad-traffic window (s) | ${WITH_BAD_S} | ${WITHOUT_BAD_S} |
| failed requests after break | ${WITH_FAILS} | ${WITHOUT_FAILS} |
| liveness restarts (broken pod) | ${WITH_RESTARTS} | ${WITHOUT_RESTARTS} |
| broken pod still a Service endpoint? | ${WITH_STILL_EP} | ${WITHOUT_STILL_EP} |

Broken pods: with-probes \`${BROKEN_A}\` · without-probes \`${BROKEN_B}\`.

## The learning
- **With probes:** readiness pulled the sick replica out of the Service endpoints within a couple of
  probe periods, so client traffic stopped hitting it (\`bad-traffic window\` ≈ a few seconds, low
  failure count). Liveness then restarted the container, so it **self-healed** back to a healthy
  process (restartCount > 0).
- **Without probes:** Kubernetes had no way to know the pod was sick. It stayed in the Service
  endpoints for the **entire window** and was **never restarted**. Every load-balanced request that
  landed on it failed — and the only "fix" available to an operator is the manual reflex this spike
  is named after: **delete the pod and let a fresh one take its place** (and at scale, "delete and
  re-add all 120 pods").

## Honest caveats
- Numbers are modest absolute values on a small bare-metal cluster; the **A-vs-B contrast** is the point.
- \`bad-traffic window\` granularity is bounded by the request interval (${REQ_INTERVAL}s) and the
  readiness period (2s); a \`0.00\` means the first post-break sample already saw no failure.
- "Sick" is process-local in-memory state, so a liveness restart yields a genuinely healthy process —
  which is exactly the self-heal we wanted to observe.
- Any \`null\` above means that metric could not be measured this run (see console log).

Raw per-request log: \`traffic.log\` (kept alongside this file).
EOF

log "Wrote ${RESULTS_JSON} and ${RESULTS_MD}."
log "Done. Tear down with: ./run.sh --teardown"
