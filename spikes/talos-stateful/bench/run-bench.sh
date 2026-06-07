#!/usr/bin/env bash
# Run pgbench against one arm and capture TPS + p50/p95/p99 latency.
#
#   run-bench.sh --context admin@dev --arm ss [--scale 10] [--clients 16] \
#                [--jobs 4] [--duration 60]
#
# --arm ss : CloudNativePG StatefulSet  (namespace pgbench-ss, Cluster "pg")
# --arm vm : KubeVirt VM Postgres       (namespace pgbench-vm, Service "pg-vm")
#
# HONESTY: pgbench reports an AVERAGE latency by default. We additionally write a
# per-transaction latency log (-l) and post-process it for p50/p95/p99, because
# the tail is what hurts. We hold scale/clients/jobs/duration constant across
# arms — pass the SAME flags to both runs or the numbers aren't comparable.
#
# Where pgbench runs:
#   ss : prefers the `kubectl cnpg pgbench` plugin (runs as an in-cluster Job, so
#        no client-side network hop skews latency). Falls back to local pgbench
#        over a port-forward if the plugin is absent.
#   vm : local pgbench over the VM's NodePort/port-forward (no cnpg plugin there).
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
RESULTS_DIR="$SCRIPT_DIR/results"
mkdir -p "$RESULTS_DIR"

# ---- defaults (HELD CONSTANT across arms — override on the CLI, same for both) -
CONTEXT=""
ARM=""
SCALE=10
CLIENTS=16
JOBS=4
DURATION=60
DBNAME=bench
DBUSER=bench
DBPASS=bench-spike-123

log()  { printf '\033[1;34m==>\033[0m %s\n' "$*"; }
warn() { printf '\033[1;33m!! \033[0m %s\n' "$*"; }
die()  { printf '\033[1;31mxx \033[0m %s\n' "$*" >&2; exit 1; }

while [ $# -gt 0 ]; do
  case "$1" in
    --context)  CONTEXT="$2"; shift 2 ;;
    --arm)      ARM="$2"; shift 2 ;;
    --scale)    SCALE="$2"; shift 2 ;;
    --clients)  CLIENTS="$2"; shift 2 ;;
    --jobs)     JOBS="$2"; shift 2 ;;
    --duration) DURATION="$2"; shift 2 ;;
    -h|--help)  grep '^#' "$0" | sed 's/^# \{0,1\}//'; exit 0 ;;
    *)          die "unknown arg: $1" ;;
  esac
done

[ -n "$CONTEXT" ] || die "--context is required (e.g. admin@dev). Never relies on current context."
case "$ARM" in ss|vm) ;; *) die "--arm must be 'ss' or 'vm'" ;; esac

command -v kubectl >/dev/null 2>&1 || die "kubectl not found"

STAMP="$(date +%Y%m%d-%H%M%S)"
OUT="$RESULTS_DIR/bench-${ARM}-${STAMP}.txt"
LATLOG="$RESULTS_DIR/.lat-${ARM}-${STAMP}"

# ---- percentile post-processor (over the -l per-txn latency log) --------------
# pgbench -l writes one line per transaction; field 3 is latency in microseconds.
# We extract that column, sort numerically (portable — no gawk asort), and index
# the percentiles. Works with macOS BSD awk and Linux gawk alike.
percentiles_from_log() {
  local prefix="$1"
  # pgbench may shard the log per-thread: prefix, prefix.1, prefix.2, ...
  # Column 3 = latency (us). Sort once, then pick indices with awk.
  cat "${prefix}" "${prefix}".* 2>/dev/null \
    | awk '{print $3}' \
    | sort -n \
    | awk '
        { v[NR] = $1 }
        END {
          n = NR
          if (n == 0) { print "p50_ms=NA p95_ms=NA p99_ms=NA samples=0"; exit }
          i50 = int(0.50*n + 0.5); if (i50 < 1) i50 = 1
          i95 = int(0.95*n + 0.5); if (i95 < 1) i95 = 1
          i99 = int(0.99*n + 0.5); if (i99 < 1) i99 = 1
          printf "p50_ms=%.3f p95_ms=%.3f p99_ms=%.3f samples=%d\n", \
                 v[i50]/1000, v[i95]/1000, v[i99]/1000, n
        }'
}

# ---- Arm A: StatefulSet via cnpg plugin (preferred) --------------------------
run_ss() {
  local host port
  if kubectl cnpg version >/dev/null 2>&1; then
    log "cnpg plugin found — initialising + running pgbench as an in-cluster Job"
    # init (scale) then run; the plugin creates a Job that runs pgbench in-cluster.
    kubectl --context "$CONTEXT" cnpg pgbench pg -n pgbench-ss \
      --db-name "$DBNAME" -- --initialize --scale "$SCALE"
    kubectl --context "$CONTEXT" cnpg pgbench pg -n pgbench-ss \
      --db-name "$DBNAME" -- \
        --client "$CLIENTS" --jobs "$JOBS" --time "$DURATION" \
        --progress 10 | tee "$OUT"
    warn "cnpg in-Job pgbench reports AVERAGE latency only; for p50/p95/p99 re-run"
    warn "with the --arm ss port-forward path below, or read the note in OUT."
    {
      echo
      echo "# percentiles: in-Job pgbench has no -l log to post-process here."
      echo "# For p50/p95/p99 on the SS arm, set CNPG_PORTFORWARD=1 to use local pgbench."
    } >> "$OUT"
    if [ "${CNPG_PORTFORWARD:-0}" != "1" ]; then return 0; fi
  fi

  command -v pgbench >/dev/null 2>&1 || die "pgbench not found locally (brew install libpq)"
  log "port-forwarding the CNPG -rw Service for local pgbench (percentiles path)"
  kubectl --context "$CONTEXT" -n pgbench-ss port-forward svc/pg-rw 55432:5432 >/dev/null 2>&1 &
  local pf=$!; trap 'kill $pf 2>/dev/null || true' RETURN
  sleep 3
  host=127.0.0.1; port=55432
  bench_local "$host" "$port"
}

# ---- Arm B: KubeVirt VM via NodePort / port-forward --------------------------
run_vm() {
  command -v pgbench >/dev/null 2>&1 || die "pgbench not found locally (brew install libpq)"
  log "port-forwarding the VM Postgres Service for local pgbench"
  kubectl --context "$CONTEXT" -n pgbench-vm port-forward svc/pg-vm 55433:5432 >/dev/null 2>&1 &
  local pf=$!; trap 'kill $pf 2>/dev/null || true' RETURN
  sleep 3
  bench_local 127.0.0.1 55433
}

# ---- shared local pgbench runner with -l percentile logging ------------------
bench_local() {
  local host="$1" port="$2"
  export PGPASSWORD="$DBPASS"
  log "pgbench init  scale=$SCALE  host=$host:$port"
  pgbench -h "$host" -p "$port" -U "$DBUSER" -d "$DBNAME" -i -s "$SCALE"
  log "pgbench run   clients=$CLIENTS jobs=$JOBS duration=${DURATION}s"
  pgbench -h "$host" -p "$port" -U "$DBUSER" -d "$DBNAME" \
    -c "$CLIENTS" -j "$JOBS" -T "$DURATION" \
    -l --log-prefix "$LATLOG" --progress 10 | tee "$OUT"
  {
    echo
    echo "# ---- post-processed percentiles (from pgbench -l per-txn log) ----"
    percentiles_from_log "$LATLOG"
  } | tee -a "$OUT"
  rm -f "${LATLOG}" "${LATLOG}".* 2>/dev/null || true
}

case "$ARM" in
  ss) run_ss ;;
  vm) run_vm ;;
esac

log "results written to: $OUT"
log "copy the TPS + p50/p95/p99 lines into RESULTS-TEMPLATE.md (label the storage backend!)"
