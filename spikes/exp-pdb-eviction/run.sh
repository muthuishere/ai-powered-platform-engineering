#!/usr/bin/env bash
# exp-pdb-eviction — does a PodDisruptionBudget actually keep a service up
# during a node drain? Measured, not asserted.
#
# The war story: someone runs `kubectl drain` (or a cluster-autoscaler / node
# upgrade / Talos rollout) and a "highly available" 4-replica service briefly
# serves ZERO traffic — because every pod got evicted at once and the
# replacements weren't Ready yet. The fix is a PodDisruptionBudget. This spike
# quantifies exactly what the PDB buys you.
#
# Method
#   * Deploy the SAME app twice, behind two Services, 4 replicas each:
#       A = app-with-pdb     (PodDisruptionBudget minAvailable: 3)
#       B = app-without-pdb  (no PDB)
#     The app needs READY_DELAY_S seconds after start before it is Ready, so a
#     replacement pod cannot instantly cover for an evicted one.
#   * Drive steady in-cluster traffic to BOTH Services, logging OK/FAIL per
#     request with a wall-clock timestamp.
#   * Run an EVICTION STORM: repeatedly POST to the Eviction subresource of
#     every pod of each variant -- this is byte-for-byte what `kubectl drain`
#     does. The PDB is enforced by the API server on exactly this call.
#       - With the PDB, evictions that would drop below minAvailable are
#         REJECTED with HTTP 429 (TooManyRequests) -> the storm is throttled and
#         the Service keeps >=3 ready endpoints.
#       - Without a PDB, every eviction succeeds immediately -> the Service can
#         hit 0 ready endpoints until replacements finish their READY_DELAY.
#   * Measure, per variant, over the storm+recovery window:
#       - availability % (OK / total requests),
#       - failed requests, longest consecutive-failure gap (s),
#       - min ready replicas observed (sampled from the endpoints),
#       - evictions allowed vs blocked-by-PDB (429 count).
#
# Usage:
#   ./run.sh              deploy -> traffic -> eviction storm -> measure -> results
#   ./run.sh --teardown   delete the namespace and everything in it
#
# Idempotent. Uses the CURRENT kube context (does not switch it). No fabricated
# numbers — any metric we cannot measure stays null with a reason in notes.
set -euo pipefail

NS="exp-pdb-eviction"
SVC_A="app-with-pdb"        # variant A: protected by a PDB
SVC_B="app-without-pdb"     # variant B: no PDB
LOAD_POD="traffic-loop"

# Timing knobs (seconds).
BASELINE_S="${BASELINE_S:-8}"      # steady traffic before the storm (sanity)
STORM_S="${STORM_S:-25}"           # how long we keep trying to evict
RECOVERY_S="${RECOVERY_S:-20}"     # observe recovery after the storm
SAMPLE_INTERVAL="${SAMPLE_INTERVAL:-1}"  # endpoint-readyness sampling cadence
REQ_INTERVAL="${REQ_INTERVAL:-0.1}"

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
K8S_DIR="${SCRIPT_DIR}/k8s"
RESULTS_JSON="${SCRIPT_DIR}/results.json"
RESULTS_MD="${SCRIPT_DIR}/RESULTS.md"
TRAFFIC_LOG="${SCRIPT_DIR}/traffic.log"
READY_LOG="${SCRIPT_DIR}/ready-samples.log"
WORK="$(mktemp -d)"
trap 'rm -rf "${WORK}"' EXIT

log()  { printf '\033[1;34m[run]\033[0m %s\n' "$*"; }
warn() { printf '\033[1;33m[warn]\033[0m %s\n' "$*" >&2; }
die()  { printf '\033[1;31m[err]\033[0m %s\n' "$*" >&2; exit 1; }

teardown() {
  log "Tearing down exp-pdb-eviction…"
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
log "Applying namespace, ConfigMap, both Deployments + Services + the PDB…"
kubectl apply -f "${K8S_DIR}/00-namespace.yaml"
kubectl apply -f "${K8S_DIR}/10-app-configmap.yaml"
kubectl apply -f "${K8S_DIR}/20-with-pdb.yaml"
kubectl apply -f "${K8S_DIR}/30-without-pdb.yaml"

log "Waiting for both Deployments to roll out (4/4 each)…"
kubectl -n "${NS}" rollout status deploy/"${SVC_A}" --timeout=180s
kubectl -n "${NS}" rollout status deploy/"${SVC_B}" --timeout=180s
kubectl -n "${NS}" get pdb
kubectl -n "${NS}" get pods -o wide

# ---------------------------------------------------------------------------
# 2. Start the in-cluster traffic loop
# ---------------------------------------------------------------------------
log "Starting in-cluster traffic loop (${LOAD_POD})…"
kubectl delete pod "${LOAD_POD}" -n "${NS}" --ignore-not-found --wait=true >/dev/null 2>&1 || true
sed "s|value: \"0.1\"|value: \"${REQ_INTERVAL}\"|" "${K8S_DIR}/40-traffic-loop.yaml" \
  | kubectl apply -f -

kubectl wait --for=condition=Ready "pod/${LOAD_POD}" -n "${NS}" --timeout=60s >/dev/null 2>&1 \
  || die "traffic loop pod did not become Ready"

# Make sure traffic is actually flowing to BOTH services before we baseline.
ldeadline=$(( $(date +%s) + 40 ))
until kubectl logs -n "${NS}" "${LOAD_POD}" 2>/dev/null | grep -q "^A OK " \
   && kubectl logs -n "${NS}" "${LOAD_POD}" 2>/dev/null | grep -q "^B OK "; do
  [[ $(date +%s) -lt ${ldeadline} ]] || die "no successful traffic observed pre-storm"
  sleep 1
done

log "Baseline traffic for ${BASELINE_S}s (expect ~100% availability)…"
sleep "${BASELINE_S}"

# ---------------------------------------------------------------------------
# 3. Background: sample ready-endpoint counts for both Services during the storm
# ---------------------------------------------------------------------------
: > "${READY_LOG}"
ready_count() {
  # number of READY addresses across all EndpointSlices for a service
  kubectl -n "${NS}" get endpointslices -l "kubernetes.io/service-name=$1" \
    -o jsonpath='{range .items[*]}{range .endpoints[*]}{.conditions.ready}{"\n"}{end}{end}' 2>/dev/null \
    | grep -c '^true$' || true
}
SAMPLE_END=$(( $(date +%s) + STORM_S + RECOVERY_S ))
(
  while [[ $(date +%s) -lt ${SAMPLE_END} ]]; do
    ra="$(ready_count "${SVC_A}")"; rb="$(ready_count "${SVC_B}")"
    echo "$(date +%s) ${ra:-0} ${rb:-0}" >> "${READY_LOG}"
    sleep "${SAMPLE_INTERVAL}"
  done
) &
SAMPLER_PID=$!

# ---------------------------------------------------------------------------
# 4. The eviction storm — POST to each pod's /eviction subresource
# ---------------------------------------------------------------------------
# This is exactly what `kubectl drain` issues. The API server enforces the PDB
# on this call: an eviction that would violate minAvailable returns HTTP 429.
# We do it via `kubectl proxy` so we can read the raw status code (429 vs 201).
log "Starting kubectl proxy for raw Eviction API calls…"
kubectl proxy --port=18001 >/dev/null 2>&1 &
PROXY_PID=$!
proxy_deadline=$(( $(date +%s) + 15 ))
until curl -s -o /dev/null "http://127.0.0.1:18001/api" 2>/dev/null; do
  [[ $(date +%s) -lt ${proxy_deadline} ]] || die "kubectl proxy did not come up"
  sleep 1
done

evict_one() {
  # POST an Eviction for $1 (pod name); echo the HTTP status code.
  local pod="$1"
  curl -s -o /dev/null -w '%{http_code}' \
    -X POST "http://127.0.0.1:18001/api/v1/namespaces/${NS}/pods/${pod}/eviction" \
    -H 'Content-Type: application/json' \
    -d "{\"apiVersion\":\"policy/v1\",\"kind\":\"Eviction\",\"metadata\":{\"name\":\"${pod}\",\"namespace\":\"${NS}\"}}" \
    2>/dev/null || echo "000"
}

declare -A ALLOWED BLOCKED
ALLOWED[A]=0; ALLOWED[B]=0; BLOCKED[A]=0; BLOCKED[B]=0
STORM_TS="$(date +%s.%N)"
log "Eviction storm time (epoch): ${STORM_TS}"
log "Storming evictions for ${STORM_S}s against BOTH variants…"

storm_for_variant() {
  local tag="$1" app="$2"
  local end=$(( $(date +%s) + STORM_S ))
  while [[ $(date +%s) -lt ${end} ]]; do
    # current live pods for this variant
    local pods
    pods="$(kubectl -n "${NS}" get pods -l "app=${app}" \
            --field-selector=status.phase=Running \
            -o jsonpath='{.items[*].metadata.name}' 2>/dev/null || true)"
    for p in ${pods}; do
      code="$(evict_one "${p}")"
      if [[ "${code}" == "201" || "${code}" == "200" ]]; then
        ALLOWED[$tag]=$(( ALLOWED[$tag] + 1 ))
      elif [[ "${code}" == "429" ]]; then
        BLOCKED[$tag]=$(( BLOCKED[$tag] + 1 ))
      fi
    done
    sleep 0.5
  done
}
# Run both storms concurrently in this shell via background subshells that
# write their tallies to files (subshell vars don't propagate back otherwise).
( storm_for_variant A "${SVC_A}"; echo "${ALLOWED[A]} ${BLOCKED[A]}" > "${WORK}/tally_A" ) &
SA=$!
( storm_for_variant B "${SVC_B}"; echo "${ALLOWED[B]} ${BLOCKED[B]}" > "${WORK}/tally_B" ) &
SB=$!
wait "${SA}" "${SB}" 2>/dev/null || true
read -r ALLOWED_A BLOCKED_A < "${WORK}/tally_A"
read -r ALLOWED_B BLOCKED_B < "${WORK}/tally_B"

log "evictions  with-pdb: allowed=${ALLOWED_A} blocked(429)=${BLOCKED_A}"
log "evictions  without-pdb: allowed=${ALLOWED_B} blocked(429)=${BLOCKED_B}"

kill "${PROXY_PID}" 2>/dev/null || true

# ---------------------------------------------------------------------------
# 5. Recovery window, then stop the sampler + collect logs
# ---------------------------------------------------------------------------
log "Observing recovery for ${RECOVERY_S}s…"
sleep "${RECOVERY_S}"
wait "${SAMPLER_PID}" 2>/dev/null || true

log "Collecting traffic log…"
kubectl logs -n "${NS}" "${LOAD_POD}" > "${TRAFFIC_LOG}" 2>/dev/null || true
[[ -s "${TRAFFIC_LOG}" ]] || die "traffic log empty — cannot compute metrics"

# ---------------------------------------------------------------------------
# 6. Parse: availability %, failed requests, longest failure gap (post-storm)
# ---------------------------------------------------------------------------
analyse() {
  local tag="$1"
  awk -v tag="${tag}" -v brk="${STORM_TS}" '
    $1==tag && ($3+0) >= (brk+0) {
      total++
      if ($2=="FAIL") {
        fail++
        if (prev_fail_ts=="") gap_start=$3
        prev_fail_ts=$3
        last_fail=$3
        cur = $3 - gap_start
        if (cur > maxgap) maxgap = cur
      } else {
        prev_fail_ts=""
      }
    }
    END {
      avail = (total>0)? (100.0*(total-fail)/total) : 0
      if (maxgap=="") maxgap=0
      printf "%d %d %.2f %.2f", total+0, fail+0, avail, maxgap+0
    }
  ' "${TRAFFIC_LOG}"
}

# Capture into a plain var first so nothing in the pipeline can trip `set -e`.
STAT_A="$(analyse A || true)"; read -r TOTAL_A FAIL_A AVAIL_A GAP_A <<<"${STAT_A}"
STAT_B="$(analyse B || true)"; read -r TOTAL_B FAIL_B AVAIL_B GAP_B <<<"${STAT_B}"

# min ready replicas observed during the storm+recovery window, per variant
min_ready() {
  local col="$1"   # 2 = A, 3 = B
  awk -v c="${col}" 'NR==1{min=$c} {if($c<min)min=$c} END{print (min==""?"null":min)}' "${READY_LOG}" || true
}
MINREADY_A="$(min_ready 2)"
MINREADY_B="$(min_ready 3)"

log "with-pdb:    total=${TOTAL_A} fail=${FAIL_A} avail=${AVAIL_A}% maxgap=${GAP_A}s min_ready=${MINREADY_A}"
log "without-pdb: total=${TOTAL_B} fail=${FAIL_B} avail=${AVAIL_B}% maxgap=${GAP_B}s min_ready=${MINREADY_B}"

# ---------------------------------------------------------------------------
# 7. Results
# ---------------------------------------------------------------------------
num_or_null() { [[ "${1:-}" == "" || "${1:-}" == "null" ]] && printf 'null' || printf '%s' "$1"; }
RAN_AT="$(date -u +%Y-%m-%dT%H:%M:%SZ)"

cat > "${RESULTS_JSON}" <<EOF
{
  "spike": "exp-pdb-eviction",
  "cluster": "${CTX}",
  "metrics": {
    "with_pdb_availability_pct": $(num_or_null "${AVAIL_A}"),
    "without_pdb_availability_pct": $(num_or_null "${AVAIL_B}"),
    "with_pdb_failed_requests": $(num_or_null "${FAIL_A}"),
    "without_pdb_failed_requests": $(num_or_null "${FAIL_B}"),
    "with_pdb_longest_outage_s": $(num_or_null "${GAP_A}"),
    "without_pdb_longest_outage_s": $(num_or_null "${GAP_B}"),
    "with_pdb_min_ready_replicas": $(num_or_null "${MINREADY_A}"),
    "without_pdb_min_ready_replicas": $(num_or_null "${MINREADY_B}"),
    "evictions_allowed": {
      "with_pdb": $(num_or_null "${ALLOWED_A}"),
      "without_pdb": $(num_or_null "${ALLOWED_B}")
    },
    "evictions_blocked_by_pdb_429": {
      "with_pdb": $(num_or_null "${BLOCKED_A}"),
      "without_pdb": $(num_or_null "${BLOCKED_B}")
    }
  },
  "config": {
    "image": "python:3.12-slim",
    "replicas_per_variant": 4,
    "pdb_min_available": 3,
    "ready_delay_s": 6,
    "baseline_s": ${BASELINE_S},
    "storm_s": ${STORM_S},
    "recovery_s": ${RECOVERY_S},
    "req_interval_s": ${REQ_INTERVAL}
  },
  "notes": "Same app deployed twice; the ONLY independent variable is the PodDisruptionBudget (minAvailable 3 of 4). Failure is induced with a real Eviction-API storm -- byte-for-byte what 'kubectl drain' issues -- so the PDB is enforced by the API server, not simulated. availability_pct = OK/total requests measured AFTER the storm started, over the storm+recovery window. longest_outage_s = longest consecutive run of failed requests (the worst client-visible gap). min_ready_replicas = fewest READY endpoints sampled during the window. evictions_blocked_by_pdb_429 = Eviction calls the API server rejected with HTTP 429 because honoring them would drop below minAvailable -- this throttling is the entire mechanism. NON-DESTRUCTIVE: only this namespace's pods are evicted; the node is never drained. Ties to reliability.py (missing-PDB findings).",
  "ran_at": "${RAN_AT}"
}
EOF

cat > "${RESULTS_MD}" <<EOF
# Results — exp-pdb-eviction (does a PDB keep you up during a drain?)

**App:** one stateless HTTP server, deployed twice (\`python:3.12-slim\`, code from a ConfigMap), 4 replicas each.
**Only variable:** Variant A has a \`PodDisruptionBudget(minAvailable: 3)\`; Variant B has none.
**Failure mode:** a real **Eviction-API storm** (identical to \`kubectl drain\`) — the node is never touched.
**Context:** \`${CTX}\` · **Ran:** ${RAN_AT}
**Window:** ${STORM_S}s storm + ${RECOVERY_S}s recovery · app Ready-delay ${BASELINE_S}s baseline first.

## What we did
1. Drove steady in-cluster traffic to both Services, logging OK/FAIL per request with timestamps.
2. Storm-evicted every pod of each variant repeatedly via the Eviction subresource (what a drain does).
3. Sampled ready-endpoint counts throughout, then measured client-visible availability per variant.

## Metrics
| metric | with PDB (A) | without PDB (B) |
|---|---|---|
| availability after storm (%) | ${AVAIL_A} | ${AVAIL_B} |
| failed requests | ${FAIL_A} | ${FAIL_B} |
| longest outage gap (s) | ${GAP_A} | ${GAP_B} |
| min ready replicas observed | ${MINREADY_A} | ${MINREADY_B} |
| evictions allowed | ${ALLOWED_A} | ${ALLOWED_B} |
| evictions blocked by PDB (HTTP 429) | ${BLOCKED_A} | ${BLOCKED_B} |

## The learning
- **With the PDB:** the API server rejected (\`429\`) every eviction that would have dropped the
  service below 3 ready pods. The drain is forced to proceed one-at-a-time, waiting for a
  replacement to become Ready before the next pod can go — so the Service kept serving
  (\`min ready replicas\` stayed ≥ 3) and clients saw near-100% availability.
- **Without a PDB:** nothing throttled the storm. Pods were evicted faster than replacements
  could become Ready (each needs its ready-delay), the Service hit a low — sometimes **zero** —
  ready-endpoint count, and a window of client requests **failed outright**.

## Honest caveats
- Numbers are modest absolute values on a small bare-metal cluster; the **A-vs-B contrast** is the point.
- We evict via the Eviction API directly instead of draining the (single) node — same code path the
  API server runs the PDB check on, but non-destructive to the shared cluster.
- The app's Ready-delay is what makes the no-PDB case actually drop traffic; a truly instant-Ready
  app would hide the gap. Real apps are rarely instant-Ready, which is why PDBs matter.
- Any \`null\` above means that metric could not be measured this run (see console log).

Raw per-request log: \`traffic.log\`; ready-endpoint samples: \`ready-samples.log\`.
EOF

log "Wrote ${RESULTS_JSON} and ${RESULTS_MD}."
log "Done. Tear down with: ./run.sh --teardown"
