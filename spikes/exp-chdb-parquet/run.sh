#!/usr/bin/env bash
# run.sh — stand up MinIO, create the bucket, run the chDB-over-Parquet benchmark,
# and scrape the Job logs into results.json + RESULTS.md per the experiments spec.
#
# chDB (in-process ClickHouse, `pip install chdb`) is the query runner. The dataset
# is one Parquet file on MinIO — same shape as exp-duckdb-parquet, so the numbers are
# directly comparable. There is no catalog DB and no local state — kill the pod, the
# data stays on the bucket.
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
NS="exp-chdb-parquet"
SPIKE="exp-chdb-parquet"
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
log "running the chDB benchmark Job"
# Delete any prior run so the Job actually re-executes (Jobs are immutable once
# complete). The ConfigMap is re-applied so bench.py edits take effect.
kubectl -n "${NS}" delete job chdb-bench --ignore-not-found
kubectl apply -f "${K8S_DIR}/30-bench-job.yaml"

# pip-install + 50M-row ingest + repeated scans can take a few minutes on a small box.
if ! kubectl -n "${NS}" wait --for=condition=complete job/chdb-bench --timeout=900s; then
  echo "warning: bench Job did not complete in time; scraping whatever logs exist." >&2
fi

log "scraping bench logs"
LOGS="$(kubectl -n "${NS}" logs job/chdb-bench --tail=-1 2>/dev/null || true)"
if [[ -z "${LOGS}" ]]; then
  echo "error: no logs from chdb-bench; cannot produce metrics." >&2
fi

RAW_LOG="${SCRIPT_DIR}/.last-bench.log"
printf '%s\n' "${LOGS}" > "${RAW_LOG}"

# --- parse metrics ----------------------------------------------------------
# bench.py prints one machine-parseable line per metric: "@@METRIC key=value@@".
# Everything here is MEASURED in-pod (timed with perf_counter / read from ClickHouse).
# If a value can't be found it stays the literal string null with a reason in notes —
# never fabricated.
metric() {
  # last value for a given key (queries print multiple query_s; handled separately)
  awk -v k="$1" -F'[ =@]+' '
    /@@METRIC / { for (i=1;i<=NF;i++) if ($i==k) { v=$(i+1) } }
    END { if (v!="") print v }
  ' "${RAW_LOG}"
}

ROW_COUNT="$(metric row_count)"
INGEST_S="$(metric ingest_s)"
SCAN_S="$(metric scan_s)"
ROWS_SCANNED="$(metric rows_scanned)"
COMPRESSED_BYTES="$(metric compressed_bytes)"
UNCOMPRESSED_BYTES="$(metric uncompressed_bytes)"
CHDB_VER="$(metric chdb_version)"

# All query wall times (one per repetition) -> list for p50/p95.
QUERY_TIMES="$(awk -F'[ =@]+' '
  /@@METRIC / { for (i=1;i<=NF;i++) if ($i=="query_s") print $(i+1) }
' "${RAW_LOG}")"

# --- derive contract metrics (awk for float math) ---------------------------
QUERY_TIMES_SP="$(printf '%s' "${QUERY_TIMES}" | tr '\n' ' ')"
read -r SCAN_ROWS_PER_S QUERY_P50_MS QUERY_P95_MS COMPRESSION_RATIO <<EOF
$(awk -v rows="${ROWS_SCANNED:-${ROW_COUNT}}" -v scan="${SCAN_S}" \
      -v unc="${UNCOMPRESSED_BYTES}" -v comp="${COMPRESSED_BYTES}" \
      -v qt="${QUERY_TIMES_SP}" '
  function pct(arr, n, p,   idx) {
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
      for (i=1;i<=n;i++) for (j=i+1;j<=n;j++) if (q[j]<q[i]){t=q[i];q[i]=q[j];q[j]=t}
      p50 = sprintf("%.1f", pct(q,n,50)*1000.0)
      p95 = sprintf("%.1f", pct(q,n,95)*1000.0)
    }
    print srps, p50, p95, cr
  }')
EOF

INGEST_OUT="${INGEST_S:-null}"
[[ "${INGEST_OUT}" =~ ^[0-9.]+$ ]] || INGEST_OUT="null"
ONDISK_OUT="${COMPRESSED_BYTES:-null}"
[[ "${ONDISK_OUT}" =~ ^[0-9]+$ ]] || ONDISK_OUT="null"

NOTES="chDB ${CHDB_VER:-3.x} (in-process ClickHouse) over pure Parquet (zstd) on MinIO, single-node lab. Same dataset shape as exp-duckdb-parquet for comparability."
missing=""
[[ "${INGEST_OUT}" == null ]] && missing="${missing} ingest_s"
[[ "${SCAN_ROWS_PER_S}" == null ]] && missing="${missing} scan_rows_per_s"
[[ "${QUERY_P50_MS}" == null ]] && missing="${missing} query_p50_ms"
[[ "${QUERY_P95_MS}" == null ]] && missing="${missing} query_p95_ms"
[[ "${ONDISK_OUT}" == null ]] && missing="${missing} on_disk_bytes"
[[ "${COMPRESSION_RATIO}" == null ]] && missing="${missing} compression_ratio"
if [[ -n "${missing}" ]]; then
  NOTES="${NOTES} UNMEASURED (left null):${missing} — bench Job log lacked the expected @@METRIC@@ lines (job may not have completed; see .last-bench.log)."
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
  echo "- **Engine:** chDB ${CHDB_VER:-3.x} (in-process ClickHouse, \`pip install chdb\`)"
  echo "- **Format:** pure Parquet (ZSTD), no Iceberg / no DuckLake"
  echo "- **Object store:** MinIO (single node, S3-compatible)"
  echo "- **Cluster (kube context):** \`${CTX}\`"
  echo "- **Generated rows:** ${ROW_COUNT:-unknown} (scanned: ${ROWS_SCANNED:-unknown})"
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
  echo "Raw query wall times (s) used for p50/p95:"
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
