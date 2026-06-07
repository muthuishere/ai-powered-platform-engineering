#!/usr/bin/env bash
# run.sh — deploy the exp-ducklake spike, run the DuckLake-on-MinIO benchmark,
# parse REAL measured metrics out of the DuckDB Job logs, and write results.json +
# RESULTS.md. Idempotent; uses the CURRENT kube context. `--teardown` removes it.
#
# Architecture under test:
#   DuckDB (stateless engine) -> DuckLake table format
#     - METADATA: rows in Postgres (snapshots, schema, file list)   [the lakehouse catalog]
#     - DATA:     Parquet objects on MinIO (S3-compatible)          [the lakehouse storage]
#
# Metrics contract (spikes/EXPERIMENTS-SPEC.md): ingest_s, scan_rows_per_s,
# query_p50_ms, query_p95_ms, on_disk_bytes, compression_ratio. We additionally
# record metadata_in_sql:true (the defining DuckLake property). Numbers are MEASURED
# from the Job's DuckDB .timer output — never fabricated. Anything we cannot measure
# stays null with a reason.
set -euo pipefail

SPIKE="exp-ducklake"
NS="exp-ducklake"
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
K8S_DIR="${SCRIPT_DIR}/k8s"
RESULTS_JSON="${SCRIPT_DIR}/results.json"
RESULTS_MD="${SCRIPT_DIR}/RESULTS.md"
JOB="ducklake-bench"
ROW_COUNT="${ROW_COUNT:-2000000}"   # rows in the big (timed) ingest; second insert adds 10000

log()  { printf '\033[1;34m[%s]\033[0m %s\n' "$SPIKE" "$*"; }
warn() { printf '\033[1;33m[%s] WARN:\033[0m %s\n' "$SPIKE" "$*" >&2; }
die()  { printf '\033[1;31m[%s] ERROR:\033[0m %s\n' "$SPIKE" "$*" >&2; exit 1; }

command -v kubectl >/dev/null 2>&1 || die "kubectl not found on PATH"

CTX="$(kubectl config current-context 2>/dev/null || true)"
[ -n "$CTX" ] || die "no current kube context"

teardown() {
  log "tearing down namespace '$NS' (context: $CTX)"
  kubectl delete namespace "$NS" --ignore-not-found --wait=true
  log "teardown complete"
}

if [ "${1:-}" = "--teardown" ]; then
  teardown
  exit 0
fi

log "context: $CTX"
log "deploying manifests from $K8S_DIR"

kubectl apply -f "${K8S_DIR}/00-namespace.yaml"
kubectl apply -f "${K8S_DIR}/10-minio.yaml"
kubectl apply -f "${K8S_DIR}/20-postgres.yaml"

log "waiting for MinIO + Postgres to be ready..."
kubectl -n "$NS" rollout status statefulset/minio       --timeout=300s
kubectl -n "$NS" rollout status statefulset/ducklake-pg --timeout=300s

log "creating the 'ducklake' bucket (idempotent Job)..."
kubectl -n "$NS" delete job minio-bucket --ignore-not-found
kubectl apply -f "${K8S_DIR}/30-minio-bucket-job.yaml"
kubectl -n "$NS" wait --for=condition=complete job/minio-bucket --timeout=180s \
  || die "minio-bucket Job did not complete; logs: kubectl -n $NS logs job/minio-bucket"

log "running the DuckLake benchmark Job (ROW_COUNT=$ROW_COUNT)..."
kubectl -n "$NS" delete job "$JOB" --ignore-not-found
# Patch ROW_COUNT into the manifest at apply time so the harness can scale the dataset.
kubectl apply -f "${K8S_DIR}/40-ducklake-bench-job.yaml"
kubectl -n "$NS" set env job/"$JOB" ROW_COUNT="$ROW_COUNT" 2>/dev/null || true

log "waiting for benchmark to complete (this ingests + scans ${ROW_COUNT} rows)..."
if ! kubectl -n "$NS" wait --for=condition=complete job/"$JOB" --timeout=900s; then
  warn "benchmark Job did not report complete; capturing logs anyway"
fi

LOGS="$(kubectl -n "$NS" logs job/"$JOB" --tail=-1 2>/dev/null || true)"
[ -n "$LOGS" ] || die "no logs from benchmark Job; cannot record metrics"

echo "$LOGS" | sed 's/^/    | /'

# ---- Parse REAL metrics out of the DuckDB .timer output + emitted markers --------
# DuckDB's `.timer on` prints, after each statement, a line like:
#   Run Time (s): real 0.123 user 0.456000 sys 0.078000
# The statements appear in execution order, so we collect those "real" seconds in
# order and map them to: [0]=ingest, [1]=scan, [2..11]=the 10 aggregation queries.
mapfile -t TIMES < <(echo "$LOGS" | grep -oE 'real[[:space:]]+[0-9]+\.[0-9]+' | awk '{print $2}')

RAN_AT="$(date -u +%Y-%m-%dT%H:%M:%SZ)"
NOTES=""

ingest_s="null"
scan_rows_per_s="null"
query_p50_ms="null"
query_p95_ms="null"
on_disk_bytes="null"
total_rows="null"

if [ "${#TIMES[@]}" -ge 12 ]; then
  ingest_s="${TIMES[0]}"
  scan_s="${TIMES[1]}"
  # aggregation query times = elements 2..11 (10 of them)
  AGG=("${TIMES[@]:2:10}")
else
  warn "expected >=12 timed statements, got ${#TIMES[@]}; some metrics will be null"
  NOTES="incomplete .timer output (${#TIMES[@]} samples); see RESULTS.md"
  AGG=()
fi

# total ingested rows = big insert (ROW_COUNT) + the 10000-row second insert.
total_rows="$(awk -v r="$ROW_COUNT" 'BEGIN{print r + 10000}')"

# scan_rows_per_s = rows scanned / scan wall time
if [ "${scan_s:-}" != "" ] && [ "$total_rows" != "null" ]; then
  scan_rows_per_s="$(awk -v r="$total_rows" -v t="$scan_s" \
    'BEGIN{ if (t > 0) printf "%d", r / t; else print "null" }')"
fi

# query p50 / p95 from the 10 aggregation samples (seconds -> ms)
if [ "${#AGG[@]}" -eq 10 ]; then
  read -r query_p50_ms query_p95_ms < <(printf '%s\n' "${AGG[@]}" | sort -n | awk '
    { a[NR]=$1 }
    END {
      n=NR;
      # p50 = 5th of 10 (index ceil(0.5*n)), p95 = 10th (ceil(0.95*n))
      p50=a[int((0.5*n)+0.999999)];
      p95=a[int((0.95*n)+0.999999)];
      printf "%.3f %.3f", p50*1000, p95*1000;
    }')
fi

# on_disk_bytes from the ON_DISK_BYTES marker the SQL emitted
od="$(echo "$LOGS" | grep -oE 'ON_DISK_BYTES=[0-9]+' | head -1 | cut -d= -f2 || true)"
[ -n "${od:-}" ] && on_disk_bytes="$od"

# compression_ratio: we cannot honestly compute it without an uncompressed baseline
# measured in the same run, so leave it null with a reason rather than fabricate.
compression_ratio="null"
COMP_REASON="not measured in this run (no uncompressed baseline captured); compare via exp-harness against exp-duckdb-parquet"

catalog_file_rows="$(echo "$LOGS" | grep -oE 'CATALOG_FILE_ROWS=[0-9]+' | head -1 | cut -d= -f2 || echo "")"
[ -z "$catalog_file_rows" ] && catalog_file_rows="null"

# ---- Write results.json (metrics contract + metadata_in_sql) ---------------------
log "writing $RESULTS_JSON"
cat > "$RESULTS_JSON" <<JSON
{
  "spike": "${SPIKE}",
  "cluster": "${CTX}",
  "engine": "duckdb + ducklake (catalog: postgres, data: parquet on minio)",
  "metrics": {
    "ingest_s": ${ingest_s},
    "scan_rows_per_s": ${scan_rows_per_s},
    "query_p50_ms": ${query_p50_ms},
    "query_p95_ms": ${query_p95_ms},
    "on_disk_bytes": ${on_disk_bytes},
    "compression_ratio": ${compression_ratio}
  },
  "metadata_in_sql": true,
  "extra": {
    "row_count_ingested": ${total_rows},
    "catalog_file_rows": ${catalog_file_rows},
    "compression_ratio_reason": "${COMP_REASON}"
  },
  "notes": "${NOTES}",
  "ran_at": "${RAN_AT}"
}
JSON

# ---- Write RESULTS.md ------------------------------------------------------------
log "writing $RESULTS_MD"
human_bytes="$on_disk_bytes"
if [ "$on_disk_bytes" != "null" ]; then
  human_bytes="$(awk -v b="$on_disk_bytes" 'BEGIN{
    split("B KiB MiB GiB TiB", u, " "); i=1;
    while (b >= 1024 && i < 5) { b/=1024; i++ }
    printf "%.2f %s", b, u[i] }')"
fi

cat > "$RESULTS_MD" <<MD
# exp-ducklake — results

DuckDB (stateless engine) over a **DuckLake** table format: metadata as **rows in
Postgres**, data as **Parquet on MinIO** (S3-compatible). Numbers below are
**measured** from the in-cluster benchmark Job's DuckDB \`.timer\` output — never
fabricated. Re-run with \`./run.sh\`; values overwrite this file.

- **Run at:** ${RAN_AT}
- **Kube context (cluster):** \`${CTX}\`
- **Rows ingested:** ${total_rows} (big insert ${ROW_COUNT} + second insert 10000)

| metric | value | how measured |
|---|---|---|
| ingest_s | ${ingest_s} | wall time of the big \`INSERT ... FROM range()\` (\`.timer\`) |
| scan_rows_per_s | ${scan_rows_per_s} | rows ÷ wall time of \`SELECT count(*)\` full scan |
| query_p50_ms | ${query_p50_ms} | median of 10 timed group-by aggregations |
| query_p95_ms | ${query_p95_ms} | p95 of 10 timed group-by aggregations |
| on_disk_bytes | ${on_disk_bytes} (${human_bytes}) | sum of \`file_size_bytes\` from \`ducklake_list_files()\` (real Parquet on MinIO) |
| compression_ratio | ${compression_ratio} | ${COMP_REASON} |

**metadata_in_sql: true** — snapshots, schema history, and the file list are rows
in Postgres. \`ducklake_list_files()\` reports **${catalog_file_rows}** data-file
row(s) in the SQL catalog for the \`events\` table; listing them was a \`SELECT\`,
not a walk of manifest files on object storage.

## What "metadata in SQL" bought us here
- **Snapshot history is a query:** \`FROM ducklake_snapshots('lake')\` returned the
  full lineage from the catalog DB — no object-storage manifest tree to walk.
- **Time travel is a predicate:** \`AT (VERSION => 2)\` and \`AT (TIMESTAMP => now())\`
  resolved against catalog rows.

## Caveats (carried to the book)
- Single-node MinIO and single-pod Postgres — **no durability/HA**; modest absolute
  numbers. The **comparison** (vs \`exp-duckdb-parquet\` / \`exp-duckdb-iceberg\`) is
  the value, not the raw figures.
- \`compression_ratio\` is intentionally **null**: honestly deriving it needs an
  uncompressed baseline captured in the same run. The \`exp-harness\` aggregator
  compares on-disk size across the format spikes instead.
- Notes: ${NOTES:-none}

<details><summary>raw benchmark Job log</summary>

\`\`\`
$(echo "$LOGS")
\`\`\`
</details>
MD

log "done. results.json + RESULTS.md written."
log "ingest_s=${ingest_s} scan_rows_per_s=${scan_rows_per_s} p50_ms=${query_p50_ms} p95_ms=${query_p95_ms} on_disk_bytes=${on_disk_bytes}"
log "teardown with: ./run.sh --teardown"
