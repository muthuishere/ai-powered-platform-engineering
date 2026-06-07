#!/usr/bin/env bash
# run.sh — stand up MinIO, create the bucket, run the DuckDB-over-Parquet benchmark,
# and scrape the Job logs into results.json + RESULTS.md per the experiments spec.
#
# DuckDB is the query runner. The dataset is one Parquet file on MinIO. There is no
# catalog DB and no local state — kill the pod, the data stays on the bucket.
#
# Targets the CURRENT kube context (the spike's own cluster). It does NOT switch
# contexts. Read the context line it prints before letting it apply anything.
#
# Usage:
#   ./run.sh              apply + wait + bench + scrape results.json/RESULTS.md
#   ./run.sh --teardown   delete the namespace (everything in it) and exit
#
# Idempotent: re-applying manifests is a no-op where unchanged; the bench Job is
# deleted-then-recreated each run so it actually re-executes.
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
K8S_DIR="${SCRIPT_DIR}/k8s"
NS="exp-duckdb-parquet"
SPIKE="exp-duckdb-parquet"
RESULTS_JSON="${SCRIPT_DIR}/results.json"
RESULTS_MD="${SCRIPT_DIR}/RESULTS.md"

log() { printf '\n=== %s ===\n' "$*" >&2; }

# --- teardown ---------------------------------------------------------------
if [[ "${1:-}" == "--teardown" ]]; then
  log "tearing down namespace ${NS}"
  kubectl delete namespace "${NS}" --ignore-not-found --wait=true
  echo "torn down." >&2
  exit 0
fi

command -v kubectl >/dev/null 2>&1 || { echo "error: kubectl not on PATH" >&2; exit 1; }

CTX="$(kubectl config current-context 2>/dev/null || echo '<none>')"
log "kube context: ${CTX}   (applying into namespace ${NS})"

# --- apply ------------------------------------------------------------------
log "applying manifests"
kubectl apply -f "${K8S_DIR}/00-namespace.yaml"
kubectl apply -f "${K8S_DIR}/10-minio.yaml"

log "waiting for MinIO to be ready"
kubectl -n "${NS}" rollout status statefulset/minio --timeout=180s

log "creating the bucket (one-time Job)"
kubectl -n "${NS}" delete job minio-make-bucket --ignore-not-found
kubectl apply -f "${K8S_DIR}/20-bucket-job.yaml"
kubectl -n "${NS}" wait --for=condition=complete job/minio-make-bucket --timeout=120s

# --- run the benchmark ------------------------------------------------------
log "running the DuckDB benchmark Job"
# Delete any prior run so the Job actually re-executes (Jobs are immutable once
# complete). The ConfigMap is re-applied so SQL edits take effect.
kubectl -n "${NS}" delete job duckdb-bench --ignore-not-found
kubectl apply -f "${K8S_DIR}/30-bench-job.yaml"

# 50M-row ingest + repeated scans can take a few minutes on a small box.
if ! kubectl -n "${NS}" wait --for=condition=complete job/duckdb-bench --timeout=900s; then
  echo "warning: bench Job did not complete in time; scraping whatever logs exist." >&2
fi

log "scraping bench logs"
LOGS="$(kubectl -n "${NS}" logs job/duckdb-bench --tail=-1 2>/dev/null || true)"
if [[ -z "${LOGS}" ]]; then
  echo "error: no logs from duckdb-bench; cannot produce metrics." >&2
fi

RAW_LOG="${SCRIPT_DIR}/.last-bench.log"
printf '%s\n' "${LOGS}" > "${RAW_LOG}"

# --- parse metrics ----------------------------------------------------------
# The log is a sequence of "@@BENCH_TAG <name>@@" markers, each followed (after the
# statement's result) by a "Run Time (s): real <sec> user <..> sys <..>" line from
# .timer on. We walk the log, remember the most recent tag, and attribute the next
# "Run Time" to it. Counts/sizes are read from the result rows themselves.
#
# Everything here is MEASURED from the log. If a value can't be found it stays the
# literal string null with a reason recorded in notes — never fabricated.

# The bench rows come out of DuckDB inside box-drawing tables (│ ... │), so we strip
# non-digits before matching. ROW_COUNT = first all-digit value after its marker,
# skipping the marker statement's own "Run Time" line (which also contains digits).
ROW_COUNT="$(awk '/@@BENCH_TAG rowcount@@/{f=1;next}
     f && /Run Time/ { next }
     f { line=$0; gsub(/[^0-9]/,"",line);
         if (line ~ /^[0-9]+$/ && length(line)>0) { print line; exit } }' "${RAW_LOG}")"
ROW_COUNT="${ROW_COUNT:-}"

# Timings per tag. With `.timer on`, EVERY statement prints a Run Time — including the
# tiny "SELECT '@@BENCH_TAG x@@'" marker statement itself. So between two markers there
# are two Run Times: the marker's (tiny) then the real query's. We take the LAST Run
# Time before the next marker = the real query's wall time. Output: "tag<TAB>seconds".
TIMINGS="$(awk '
  function flush() { if (tag!="" && have) print tag "\t" last }
  match($0, /@@BENCH_TAG [a-z]+@@/) {
    flush(); tag = substr($0, RSTART+12, RLENGTH-12-2); have=0; last=""; next
  }
  /Run Time \(s\): real/ {
    for (i=1;i<=NF;i++) if ($i=="real") { last=$(i+1); have=1 }
  }
  END { flush() }
' "${RAW_LOG}")"

field() { printf '%s\n' "${TIMINGS}" | awk -F'\t' -v t="$1" '$1==t{print $2}'; }

INGEST_S="$(field ingest | head -n1)"
SCAN_S="$(field scan | head -n1)"

# All query Run Times (one per repetition) -> array for p50/p95.
QUERY_TIMES="$(field query)"

# Parquet sizes from the filesize result row: "<compressed>\t<uncompressed>" (DuckDB
# prints a box table; we pull the two integers on the data row after the marker).
SIZES="$(awk '
  /@@BENCH_TAG filesize@@/ {f=1; next}
  f && /[0-9]/ {
    n=0; delete v;
    for (i=1;i<=NF;i++) if ($i ~ /^[0-9]+$/) { v[++n]=$i }
    if (n>=2) { print v[1] "\t" v[2]; exit }
  }
' "${RAW_LOG}")"
COMPRESSED_BYTES="$(printf '%s' "${SIZES}" | cut -f1)"
UNCOMPRESSED_BYTES="$(printf '%s' "${SIZES}" | cut -f2)"

# --- derive contract metrics (in awk for float math) ------------------------
# scan_rows_per_s = ROW_COUNT / scan_seconds
# query p50/p95   = percentiles over the repeated query Run Times (ms)
# compression_ratio = uncompressed / compressed
# QUERY_TIMES is newline-separated; awk -v can't carry newlines, so pass it as a
# space-separated string and split on whitespace.
QUERY_TIMES_SP="$(printf '%s' "${QUERY_TIMES}" | tr '\n' ' ')"
read -r SCAN_ROWS_PER_S QUERY_P50_MS QUERY_P95_MS COMPRESSION_RATIO <<EOF
$(awk -v rows="${ROW_COUNT}" -v scan="${SCAN_S}" \
      -v unc="${UNCOMPRESSED_BYTES}" -v comp="${COMPRESSED_BYTES}" \
      -v qt="${QUERY_TIMES_SP}" '
  function pct(arr, n, p,   idx) {
    # nearest-rank percentile on a 1-indexed sorted array
    idx = int((p/100.0)*n + 0.999999); if (idx<1) idx=1; if (idx>n) idx=n
    return arr[idx]
  }
  BEGIN {
    srps="null"; p50="null"; p95="null"; cr="null"
    if (rows ~ /^[0-9]+$/ && scan ~ /^[0-9.]+$/ && scan+0>0)
      srps = sprintf("%d", rows/scan)
    if (unc ~ /^[0-9]+$/ && comp ~ /^[0-9]+$/ && comp+0>0)
      cr = sprintf("%.3f", unc/comp)
    n=0
    m=split(qt, lines, /[ \t]+/)
    for (i=1;i<=m;i++) if (lines[i] ~ /^[0-9.]+$/) q[++n]=lines[i]+0
    if (n>0) {
      # sort
      for (i=1;i<=n;i++) for (j=i+1;j<=n;j++) if (q[j]<q[i]){t=q[i];q[i]=q[j];q[j]=t}
      p50 = sprintf("%.1f", pct(q,n,50)*1000.0)
      p95 = sprintf("%.1f", pct(q,n,95)*1000.0)
    }
    print srps, p50, p95, cr
  }')
EOF

# ingest seconds & on-disk bytes as the contract fields (numeric or null)
INGEST_OUT="${INGEST_S:-null}"
[[ "${INGEST_OUT}" =~ ^[0-9.]+$ ]] || INGEST_OUT="null"
ONDISK_OUT="${COMPRESSED_BYTES:-null}"
[[ "${ONDISK_OUT}" =~ ^[0-9]+$ ]] || ONDISK_OUT="null"

# Build a notes string explaining any nulls.
NOTES="DuckDB ${DUCKDB_VER:-1.5.3} over pure Parquet (zstd) on MinIO, single-node lab."
missing=""
[[ "${INGEST_OUT}" == null ]] && missing="${missing} ingest_s"
[[ "${SCAN_ROWS_PER_S}" == null ]] && missing="${missing} scan_rows_per_s"
[[ "${QUERY_P50_MS}" == null ]] && missing="${missing} query_p50_ms"
[[ "${QUERY_P95_MS}" == null ]] && missing="${missing} query_p95_ms"
[[ "${ONDISK_OUT}" == null ]] && missing="${missing} on_disk_bytes"
[[ "${COMPRESSION_RATIO}" == null ]] && missing="${missing} compression_ratio"
if [[ -n "${missing}" ]]; then
  NOTES="${NOTES} UNMEASURED (left null):${missing} — bench Job log lacked the expected markers/Run Time lines (job may not have completed; see .last-bench.log)."
fi

RAN_AT="$(date -u +%Y-%m-%dT%H:%M:%SZ)"

# --- write results.json -----------------------------------------------------
log "writing ${RESULTS_JSON}"
cat > "${RESULTS_JSON}" <<EOF
{
  "spike": "${SPIKE}",
  "cluster": "${CTX}",
  "metrics": {
    "ingest_s": ${INGEST_OUT},
    "scan_rows_per_s": ${SCAN_ROWS_PER_S},
    "query_p50_ms": ${QUERY_P50_MS},
    "query_p95_ms": ${QUERY_P95_MS},
    "on_disk_bytes": ${ONDISK_OUT},
    "compression_ratio": ${COMPRESSION_RATIO}
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
  echo "- **Engine:** DuckDB ${DUCKDB_VER:-1.5.3} (official distroless CLI image)"
  echo "- **Format:** pure Parquet (ZSTD), no DuckLake / no Iceberg"
  echo "- **Object store:** MinIO (single node, S3-compatible)"
  echo "- **Cluster (kube context):** \`${CTX}\`"
  echo "- **Generated rows:** ${ROW_COUNT:-unknown}"
  echo "- **Ran at (UTC):** ${RAN_AT}"
  echo
  echo "## Metrics (contract)"
  echo
  echo "| metric | value |"
  echo "|---|---|"
  echo "| ingest_s | ${INGEST_OUT} |"
  echo "| scan_rows_per_s | ${SCAN_ROWS_PER_S} |"
  echo "| query_p50_ms | ${QUERY_P50_MS} |"
  echo "| query_p95_ms | ${QUERY_P95_MS} |"
  echo "| on_disk_bytes | ${ONDISK_OUT} |"
  echo "| compression_ratio | ${COMPRESSION_RATIO} |"
  echo
  if [[ -n "${UNCOMPRESSED_BYTES:-}" && "${UNCOMPRESSED_BYTES}" =~ ^[0-9]+$ ]]; then
    echo "Uncompressed Parquet (logical) bytes: ${UNCOMPRESSED_BYTES}"
    echo
  fi
  echo "## Notes"
  echo
  echo "${NOTES}"
  echo
  echo "Raw query Run Times (s) used for p50/p95:"
  echo
  echo '```'
  printf '%s\n' "${QUERY_TIMES:-<none captured>}"
  echo '```'
  echo
  echo "_Full bench log: \`.last-bench.log\`._"
} > "${RESULTS_MD}"

log "done"
echo "results.json:" >&2
cat "${RESULTS_JSON}" >&2
