#!/usr/bin/env bash
# exp-pg-statefulset — Postgres on Kubernetes as a StatefulSet (CloudNativePG).
#
# The StatefulSet BASELINE: deploy the CNPG operator + a 3-instance Cluster, run
# pgbench (TPS + p50/p95/p99 latency), then a failover test (delete primary, time
# to a writable primary). Writes results.json + RESULTS.md.
#
# This is the number the KubeVirt arm (exp-pg-ss-vs-kubevirt) compares against.
#
# Usage:
#   ./run.sh              deploy → wait healthy → pgbench → failover → results
#   ./run.sh --teardown   delete the cluster + operator + namespaces
#
# Idempotent. Uses the CURRENT kube context (does not switch it). No fabricated
# numbers — any metric we cannot measure stays null with a reason in notes.
set -euo pipefail

# ---------------------------------------------------------------------------
# Config (PINNED — keep reproducible vs the KubeVirt arm)
# ---------------------------------------------------------------------------
CNPG_VERSION="v1.29.1"
CNPG_MANIFEST="https://raw.githubusercontent.com/cloudnative-pg/cloudnative-pg/${CNPG_VERSION}/releases/cnpg-${CNPG_VERSION#v}.yaml"

NS="exp-pg-ss"
CLUSTER="pg"
OPERATOR_NS="cnpg-system"

# pgbench knobs (kept modest for small bare-metal boxes; comparisons matter, not
# absolute throughput).
PGB_SCALE="${PGB_SCALE:-10}"        # ~150MB at scale 10
PGB_CLIENTS="${PGB_CLIENTS:-8}"
PGB_JOBS="${PGB_JOBS:-2}"
PGB_TIME="${PGB_TIME:-60}"          # seconds of measured load

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
K8S_DIR="${SCRIPT_DIR}/k8s"
RESULTS_JSON="${SCRIPT_DIR}/results.json"
RESULTS_MD="${SCRIPT_DIR}/RESULTS.md"
WORK="$(mktemp -d)"
trap 'rm -rf "${WORK}"' EXIT

# Run pgbench job under a fixed name so re-runs are idempotent.
PGB_JOB="pgbench-load"
PSQL_POD="pg-psql-helper"

log()  { printf '\033[1;34m[run]\033[0m %s\n' "$*"; }
warn() { printf '\033[1;33m[warn]\033[0m %s\n' "$*" >&2; }
die()  { printf '\033[1;31m[err]\033[0m %s\n' "$*" >&2; exit 1; }

have_cnpg_plugin() { kubectl cnpg version >/dev/null 2>&1; }

# ---------------------------------------------------------------------------
# Teardown
# ---------------------------------------------------------------------------
teardown() {
  log "Tearing down exp-pg-statefulset…"
  kubectl delete job "${PGB_JOB}" -n "${NS}" --ignore-not-found --wait=false || true
  kubectl delete pod "${PSQL_POD}" -n "${NS}" --ignore-not-found --wait=false || true
  kubectl delete -f "${K8S_DIR}/30-podmonitor.yaml" --ignore-not-found 2>/dev/null || true
  kubectl delete -f "${K8S_DIR}/20-cluster.yaml" --ignore-not-found || true
  kubectl delete namespace "${NS}" --ignore-not-found --wait=false || true
  # Operator: remove via the same pinned upstream manifest.
  kubectl delete -f "${CNPG_MANIFEST}" --ignore-not-found --wait=false 2>/dev/null \
    || warn "operator manifest delete skipped (offline?) — delete ns ${OPERATOR_NS} by hand if needed"
  log "Teardown requested (namespaces finalize asynchronously)."
}

if [[ "${1:-}" == "--teardown" ]]; then
  teardown
  exit 0
fi

CTX="$(kubectl config current-context 2>/dev/null || true)"
[[ -n "${CTX}" ]] || die "no current kube context"
log "Using current context: ${CTX}"

# ---------------------------------------------------------------------------
# 1. Operator
# ---------------------------------------------------------------------------
log "Applying CNPG operator ${CNPG_VERSION} (server-side)…"
kubectl apply -f "${K8S_DIR}/00-namespace.yaml"
kubectl apply -f "${K8S_DIR}/10-operator.yaml"
# Server-side apply: the CRDs are too large for the last-applied annotation.
kubectl apply --server-side -f "${CNPG_MANIFEST}"
log "Waiting for the operator deployment to be ready…"
kubectl -n "${OPERATOR_NS}" rollout status deploy/cnpg-controller-manager --timeout=180s

# ---------------------------------------------------------------------------
# 2. Cluster
# ---------------------------------------------------------------------------
log "Applying the 3-instance Cluster…"
kubectl apply -f "${K8S_DIR}/20-cluster.yaml"

# PodMonitor only if the Prometheus Operator CRD is present.
if kubectl get crd podmonitors.monitoring.coreos.com >/dev/null 2>&1; then
  log "Prometheus Operator detected — applying PodMonitor."
  kubectl apply -f "${K8S_DIR}/30-podmonitor.yaml"
else
  warn "no PodMonitor CRD — skipping metrics scrape object (CNPG still exposes :9187)."
fi

log "Waiting for the Cluster to report healthy (this includes initial base backup)…"
# CNPG sets a 'ready' condition / phase. Wait on the status.phase == "Cluster in
# healthy state" via a polling loop (kubectl wait on CRD condition is flaky
# across CNPG versions, so we poll the phase string).
deadline=$(( $(date +%s) + 600 ))
until kubectl -n "${NS}" get cluster "${CLUSTER}" \
        -o jsonpath='{.status.phase}' 2>/dev/null | grep -q "healthy"; do
  [[ $(date +%s) -lt ${deadline} ]] || { kubectl -n "${NS}" get pods; die "cluster not healthy in time"; }
  sleep 5
done
# Belt-and-suspenders: all 3 instances reported ready.
until [[ "$(kubectl -n "${NS}" get cluster "${CLUSTER}" -o jsonpath='{.status.readyInstances}' 2>/dev/null)" == "3" ]]; do
  [[ $(date +%s) -lt ${deadline} ]] || { kubectl -n "${NS}" get pods; die "not all instances ready"; }
  sleep 5
done
log "Cluster healthy: 3/3 instances ready."
kubectl -n "${NS}" get pods -l "cnpg.io/cluster=${CLUSTER}"

RW_SVC="${CLUSTER}-rw"   # CNPG read-write Service → always the current primary
PGHOST="${RW_SVC}.${NS}.svc"
PGUSER="bench"
PGPASS="bench-spike-123"
PGDB="bench"

# ---------------------------------------------------------------------------
# 3. pgbench  (TPS + p50/p95/p99 from per-transaction log)
# ---------------------------------------------------------------------------
# We run pgbench from an in-cluster Job using the SAME postgres image as the
# instances (psql/pgbench guaranteed present, version-matched). pgbench -l writes
# one line per transaction; we compute percentiles from that log so the numbers
# are real measurements, not pgbench's summary-only latency.
#
# We deliberately do NOT use `kubectl cnpg pgbench` as the primary path: that
# plugin's Job does not emit the per-transaction -l log we need for percentiles.
# We note the plugin in README as the day-2 convenience path.

PG_IMAGE="ghcr.io/cloudnative-pg/postgresql:17.5"

run_pgbench_job() {
  kubectl delete job "${PGB_JOB}" -n "${NS}" --ignore-not-found --wait=true >/dev/null 2>&1 || true

  cat <<EOF | kubectl apply -f -
apiVersion: batch/v1
kind: Job
metadata:
  name: ${PGB_JOB}
  namespace: ${NS}
spec:
  backoffLimit: 0
  template:
    spec:
      restartPolicy: Never
      containers:
        - name: pgbench
          image: ${PG_IMAGE}
          env:
            - name: PGHOST
              value: "${PGHOST}"
            - name: PGUSER
              value: "${PGUSER}"
            - name: PGPASSWORD
              value: "${PGPASS}"
            - name: PGDATABASE
              value: "${PGDB}"
          command: ["/bin/bash","-c"]
          args:
            - |
              set -e
              echo "== pgbench init (scale ${PGB_SCALE}) =="
              pgbench -i -s ${PGB_SCALE} --quiet
              echo "== pgbench run: clients=${PGB_CLIENTS} jobs=${PGB_JOBS} time=${PGB_TIME}s =="
              # -l writes per-transaction latency log to /tmp/pgbench_log.<pid>.*
              cd /tmp
              pgbench -c ${PGB_CLIENTS} -j ${PGB_JOBS} -T ${PGB_TIME} -l --log-prefix=pgbench_log -r
              echo "== PGBENCH_LOG_BEGIN =="
              # Emit every per-transaction latency (microseconds, field 3) so the
              # driver can compute percentiles. Cat ALL shards (one per thread).
              cat pgbench_log.* 2>/dev/null
              echo "== PGBENCH_LOG_END =="
EOF

  log "pgbench running (init + ${PGB_TIME}s load)… streaming when complete."
  # Wait for completion (init + load + a margin).
  if ! kubectl wait --for=condition=complete "job/${PGB_JOB}" -n "${NS}" \
        --timeout=$(( PGB_TIME + 240 ))s 2>/dev/null; then
    # Surface failure logs and bail.
    kubectl logs -n "${NS}" "job/${PGB_JOB}" --tail=50 || true
    die "pgbench job did not complete"
  fi
  kubectl logs -n "${NS}" "job/${PGB_JOB}" > "${WORK}/pgbench.out"
}

run_pgbench_job
cp "${WORK}/pgbench.out" "${SCRIPT_DIR}/pgbench.out"

# --- parse TPS from pgbench summary -----------------------------------------
# Line looks like: "tps = 1234.567890 (without initial connection time)"
TPS="$(grep -E '^tps = ' "${WORK}/pgbench.out" | head -1 | sed -E 's/^tps = ([0-9.]+).*/\1/')"
[[ -n "${TPS}" ]] || warn "could not parse TPS from pgbench output"

# --- compute p50/p95/p99 from the per-transaction log ------------------------
# pgbench -l format (no rate limit, no --aggregate-interval):
#   client_id transaction_no time(us) script_no time_epoch time_us [schedule_lag]
# field 3 (1-indexed) = transaction latency in MICROseconds.
awk '/== PGBENCH_LOG_BEGIN ==/{f=1; next} /== PGBENCH_LOG_END ==/{f=0} f && NF>=3 {print $3}' \
    "${WORK}/pgbench.out" > "${WORK}/latencies_us.txt" || true

P50_MS=null; P95_MS=null; P99_MS=null
N_LAT="$(wc -l < "${WORK}/latencies_us.txt" | tr -d ' ')"
if [[ "${N_LAT}" -gt 0 ]]; then
  read -r P50_MS P95_MS P99_MS < <(
    sort -n "${WORK}/latencies_us.txt" | awk '
      { a[NR]=$1 }
      END {
        n=NR
        # nearest-rank percentile, convert microseconds -> milliseconds
        p50=a[int((50/100.0)*n + 0.999999)]; if(p50=="")p50=a[n]
        p95=a[int((95/100.0)*n + 0.999999)]; if(p95=="")p95=a[n]
        p99=a[int((99/100.0)*n + 0.999999)]; if(p99=="")p99=a[n]
        printf "%.3f %.3f %.3f", p50/1000.0, p95/1000.0, p99/1000.0
      }')
  log "pgbench: tps=${TPS:-null}  p50=${P50_MS}ms p95=${P95_MS}ms p99=${P99_MS}ms  (n=${N_LAT} txns)"
else
  warn "no per-transaction latencies parsed — percentiles stay null"
fi

# ---------------------------------------------------------------------------
# 4. Failover test  (delete primary → time to a writable primary)
# ---------------------------------------------------------------------------
# CNPG's pg-rw Service always points at the current primary. We delete the
# primary pod and poll the pg-rw endpoint until a write succeeds, timing it.
log "Failover test: identifying current primary…"
PRIMARY_POD="$(kubectl -n "${NS}" get pods \
  -l "cnpg.io/cluster=${CLUSTER},cnpg.io/instanceRole=primary" \
  -o jsonpath='{.items[0].metadata.name}' 2>/dev/null || true)"
if [[ -z "${PRIMARY_POD}" ]]; then
  # older CNPG used role=primary label
  PRIMARY_POD="$(kubectl -n "${NS}" get pods \
    -l "cnpg.io/cluster=${CLUSTER},role=primary" \
    -o jsonpath='{.items[0].metadata.name}' 2>/dev/null || true)"
fi

FAILOVER_S=null
if [[ -z "${PRIMARY_POD}" ]]; then
  warn "could not identify primary pod — failover metric stays null"
else
  log "Current primary: ${PRIMARY_POD}. A long-lived psql helper will probe writes through pg-rw."

  # Start a helper pod that loops a write through the pg-rw Service and prints a
  # timestamped OK on each success. We diff timestamps around the kill.
  kubectl delete pod "${PSQL_POD}" -n "${NS}" --ignore-not-found --wait=true >/dev/null 2>&1 || true
  kubectl run "${PSQL_POD}" -n "${NS}" --image="${PG_IMAGE}" --restart=Never \
    --env="PGHOST=${PGHOST}" --env="PGUSER=${PGUSER}" \
    --env="PGPASSWORD=${PGPASS}" --env="PGDATABASE=${PGDB}" \
    --command -- /bin/bash -c '
      psql -tAc "CREATE TABLE IF NOT EXISTS failover_probe(id serial primary key, ts timestamptz default now());" >/dev/null 2>&1 || true
      while true; do
        if psql -tAc "INSERT INTO failover_probe DEFAULT VALUES;" >/dev/null 2>&1; then
          echo "WRITE_OK $(date +%s.%N)"
        else
          echo "WRITE_FAIL $(date +%s.%N)"
        fi
        sleep 0.25
      done' >/dev/null 2>&1 || true

  # Wait until the probe is writing successfully.
  kubectl wait --for=condition=Ready "pod/${PSQL_POD}" -n "${NS}" --timeout=60s >/dev/null 2>&1 || true
  pdeadline=$(( $(date +%s) + 60 ))
  until kubectl logs -n "${NS}" "${PSQL_POD}" --tail=3 2>/dev/null | grep -q "WRITE_OK"; do
    [[ $(date +%s) -lt ${pdeadline} ]] || { warn "probe never wrote successfully pre-kill"; break; }
    sleep 1
  done

  KILL_TS="$(date +%s.%N)"
  log "Deleting primary ${PRIMARY_POD} at ${KILL_TS}…"
  kubectl delete pod "${PRIMARY_POD}" -n "${NS}" --grace-period=0 --force >/dev/null 2>&1 || true

  # Watch the probe log for the FIRST WRITE_OK whose timestamp is after KILL_TS.
  log "Waiting for the first successful write after the kill…"
  RECOVER_TS=""
  fdeadline=$(( $(date +%s) + 300 ))
  while [[ $(date +%s) -lt ${fdeadline} ]]; do
    RECOVER_TS="$(kubectl logs -n "${NS}" "${PSQL_POD}" 2>/dev/null \
      | awk -v k="${KILL_TS}" '$1=="WRITE_OK" && ($2+0) > (k+0) {print $2; exit}')"
    [[ -n "${RECOVER_TS}" ]] && break
    sleep 1
  done

  if [[ -n "${RECOVER_TS}" ]]; then
    FAILOVER_S="$(awk -v a="${KILL_TS}" -v b="${RECOVER_TS}" 'BEGIN{printf "%.2f", b-a}')"
    log "Failover complete: writable primary back in ${FAILOVER_S}s."
  else
    warn "no successful write observed within timeout — failover metric stays null"
  fi

  kubectl delete pod "${PSQL_POD}" -n "${NS}" --ignore-not-found --wait=false >/dev/null 2>&1 || true
fi

# ---------------------------------------------------------------------------
# 5. Results
# ---------------------------------------------------------------------------
RAN_AT="$(date -u +%Y-%m-%dT%H:%M:%SZ)"
jq_or_raw() { [[ "$1" == "null" || -z "$1" ]] && printf 'null' || printf '%s' "$1"; }

cat > "${RESULTS_JSON}" <<EOF
{
  "spike": "exp-pg-statefulset",
  "cluster": "${CTX}",
  "metrics": {
    "tps": $(jq_or_raw "${TPS:-null}"),
    "query_p50_ms": $(jq_or_raw "${P50_MS}"),
    "query_p95_ms": $(jq_or_raw "${P95_MS}"),
    "query_p99_ms": $(jq_or_raw "${P99_MS}"),
    "failover_s": $(jq_or_raw "${FAILOVER_S}")
  },
  "config": {
    "cnpg_version": "${CNPG_VERSION}",
    "pg_image": "${PG_IMAGE}",
    "instances": 3,
    "cpu": "1",
    "memory": "2Gi",
    "storageClass": "local-path",
    "pgbench": { "scale": ${PGB_SCALE}, "clients": ${PGB_CLIENTS}, "jobs": ${PGB_JOBS}, "time_s": ${PGB_TIME} }
  },
  "notes": "StatefulSet baseline (CloudNativePG). Percentiles from pgbench -l per-transaction log (nearest-rank, us->ms). Failover = wall time from primary pod force-delete to first successful INSERT through pg-rw. Compare vs exp-pg-ss-vs-kubevirt.",
  "ran_at": "${RAN_AT}"
}
EOF

cat > "${RESULTS_MD}" <<EOF
# Results — exp-pg-statefulset (Postgres on k8s, StatefulSet baseline)

**Engine:** CloudNativePG ${CNPG_VERSION} · **PG image:** \`${PG_IMAGE}\`
**Topology:** 3 instances (1 primary + 2 replicas) · 1 vCPU / 2Gi each · storageClass \`local-path\`
**Context:** \`${CTX}\` · **Ran:** ${RAN_AT}

## Workload
pgbench TPC-B-like, scale ${PGB_SCALE}, ${PGB_CLIENTS} clients / ${PGB_JOBS} threads, ${PGB_TIME}s measured.
Percentiles computed from the \`pgbench -l\` per-transaction log (${N_LAT} transactions, nearest-rank).

## Metrics
| metric | value |
|---|---|
| TPS | ${TPS:-null} |
| query p50 (ms) | ${P50_MS} |
| query p95 (ms) | ${P95_MS} |
| query p99 (ms) | ${P99_MS} |
| failover (s) | ${FAILOVER_S} |

## Failover
Force-deleted the primary pod \`${PRIMARY_POD:-?}\`; timed wall-clock from delete to the
first successful \`INSERT\` through the \`${CLUSTER}-rw\` Service. CNPG promoted a replica
and re-pointed the read-write Service with no human in the loop.

## Honest caveats
- Modest bare-metal box → modest absolute TPS; the **comparison** against the
  KubeVirt arm (\`exp-pg-ss-vs-kubevirt\`) is the value, not the raw number.
- failover_s includes pod-delete propagation + CNPG promotion + Service endpoint
  reprogramming + one probe poll interval (0.25s granularity).
- Any \`null\` above means that metric could not be measured this run (see console log).

Raw pgbench output: \`pgbench.out\` (kept alongside this file).
EOF

log "Wrote ${RESULTS_JSON} and ${RESULTS_MD}."
log "Done. Tear down with: ./run.sh --teardown"
