#!/usr/bin/env bash
# run.sh — deploy MinIO, create an Apache Iceberg table with pyiceberg, read it back
# with DuckDB, and emit MEASURED metrics to results.json + RESULTS.md.
#
# Self-contained: stands up its own MinIO + bucket in namespace exp-duckdb-iceberg,
# runs one bench Job (pyiceberg write -> DuckDB read + timings), scrapes the Job log
# for metric lines, and writes the metrics files. Numbers are measured in-cluster,
# never fabricated; anything that didn't run stays null with a reason.
#
# Usage:
#   ./run.sh             deploy + run + write results.json / RESULTS.md
#   ./run.sh --teardown  delete the namespace (all spike resources)
#
# Idempotent: re-applying is a no-op for unchanged manifests; the bench Job is
# delete-then-recreate each run (Jobs are immutable). Uses the CURRENT kube context.
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
NS="exp-duckdb-iceberg"
SPIKE="exp-duckdb-iceberg"
K8S="${SCRIPT_DIR}/k8s"
RESULTS_JSON="${SCRIPT_DIR}/results.json"
RESULTS_MD="${SCRIPT_DIR}/RESULTS.md"

log() { printf '\n\033[1;36m== %s ==\033[0m\n' "$*"; }

ctx="$(kubectl config current-context 2>/dev/null || echo '<none>')"

teardown() {
  log "tearing down namespace ${NS} (context: ${ctx})"
  kubectl delete namespace "${NS}" --ignore-not-found --wait=true
  echo "done."
}

if [[ "${1:-}" == "--teardown" ]]; then
  teardown
  exit 0
fi

command -v kubectl >/dev/null 2>&1 || { echo "error: kubectl not found on PATH" >&2; exit 1; }

log "kube context: ${ctx}"

# 1. Deploy MinIO + bucket. Order matters (namespace first); apply is idempotent.
log "applying manifests"
kubectl apply -f "${K8S}/00-namespace.yaml"
kubectl apply -f "${K8S}/10-minio.yaml"

log "waiting for MinIO to be ready"
kubectl -n "${NS}" rollout status statefulset/minio --timeout=180s

# 2. Bucket bootstrap (one-time, idempotent). Re-run cleanly each time.
log "creating bucket"
kubectl -n "${NS}" delete job minio-bucket --ignore-not-found
kubectl apply -f "${K8S}/20-bucket-job.yaml"
kubectl -n "${NS}" wait --for=condition=complete job/minio-bucket --timeout=120s

# 3. The bench Job. Jobs are immutable -> delete then recreate.
log "running benchmark Job (pyiceberg write -> DuckDB read)"
kubectl -n "${NS}" delete job iceberg-bench --ignore-not-found
kubectl apply -f "${K8S}/30-bench-job.yaml"

# Wait for completion OR failure (don't hang forever on a crashloop).
echo "waiting for iceberg-bench to finish (up to 8m)..."
if ! kubectl -n "${NS}" wait --for=condition=complete job/iceberg-bench --timeout=480s 2>/dev/null; then
  if kubectl -n "${NS}" wait --for=condition=failed job/iceberg-bench --timeout=5s 2>/dev/null; then
    echo "error: iceberg-bench FAILED. Logs:" >&2
    kubectl -n "${NS}" logs job/iceberg-bench --tail=80 >&2 || true
    exit 1
  fi
  echo "error: iceberg-bench did not complete in time. Logs:" >&2
  kubectl -n "${NS}" logs job/iceberg-bench --tail=80 >&2 || true
  exit 1
fi

# 4. Scrape metric lines from the Job log.
log "collecting metrics"
LOG="$(kubectl -n "${NS}" logs job/iceberg-bench)"
echo "${LOG}"

grab() {  # grab KEY -> value of last "KEY=value" line, or empty
  echo "${LOG}" | grep -E "^${1}=" | tail -1 | cut -d= -f2- || true
}

INGEST_S="$(grab ICEBERG_INGEST_S)"
ROWS="$(grab ICEBERG_ROWS)"
SCAN_RPS="$(grab M_SCAN_ROWS_PER_S)"
P50="$(grab M_QUERY_P50_MS)"
P95="$(grab M_QUERY_P95_MS)"
TT_MS="$(grab M_TIME_TRAVEL_MS)"
DISK="$(grab M_ON_DISK_BYTES)"
SCAN_ROWS="$(grab M_SCAN_ROWS)"

# Null-out anything missing, with a reason, rather than fabricate.
notes="DuckDB 1.5.3 reads an Iceberg table created by pyiceberg 0.9.1 (SqlCatalog/SQLite) on MinIO; writes go through pyiceberg because DuckDB's Iceberg write path targets REST catalogs. Lab numbers are modest — comparisons matter, not absolutes."
missing=""
for pair in "ingest_s:${INGEST_S}" "scan_rows_per_s:${SCAN_RPS}" "query_p50_ms:${P50}" \
            "query_p95_ms:${P95}" "on_disk_bytes:${DISK}" "time_travel_ms:${TT_MS}"; do
  k="${pair%%:*}"; v="${pair#*:}"
  [[ -z "${v}" ]] && missing="${missing}${k} "
done
[[ -n "${missing}" ]] && notes="${notes} MISSING (not emitted by bench): ${missing% }."

jnum() { [[ -n "${1}" ]] && printf '%s' "${1}" || printf 'null'; }

RAN_AT="$(date -u +%Y-%m-%dT%H:%M:%SZ)"

# Iceberg has no Parquet-vs-raw compression baseline in this spike (the source is
# already columnar), so compression_ratio is intentionally null with a reason.
cat > "${RESULTS_JSON}" <<JSON
{
  "spike": "${SPIKE}",
  "cluster": "${ctx}",
  "metrics": {
    "ingest_s": $(jnum "${INGEST_S}"),
    "scan_rows_per_s": $(jnum "${SCAN_RPS}"),
    "query_p50_ms": $(jnum "${P50}"),
    "query_p95_ms": $(jnum "${P95}"),
    "on_disk_bytes": $(jnum "${DISK}"),
    "compression_ratio": null,
    "time_travel_ms": $(jnum "${TT_MS}")
  },
  "notes": "${notes} compression_ratio is null: no raw-vs-Parquet baseline measured in this spike.",
  "ran_at": "${RAN_AT}"
}
JSON

cat > "${RESULTS_MD}" <<MD
# Results — ${SPIKE}

DuckDB querying an **Apache Iceberg** table (Parquet + Iceberg metadata) on **MinIO**.
Table created with **pyiceberg** (SQLite catalog); read back with DuckDB's \`iceberg\`
extension (\`iceberg_scan\` / \`iceberg_snapshots\` / \`iceberg_metadata\`).

- **Kube context:** \`${ctx}\`
- **Ran at:** ${RAN_AT}
- **Rows:** ${ROWS:-?} (two appends => two snapshots)
- **Scan rows verified:** ${SCAN_ROWS:-?}

| metric | value | meaning |
|---|---|---|
| ingest_s | ${INGEST_S:-null} | pyiceberg: two appends (create + 2 snapshots) |
| scan_rows_per_s | ${SCAN_RPS:-null} | DuckDB full-scan throughput over Iceberg on S3 |
| query_p50_ms | ${P50:-null} | group-by aggregation, p50 of N hot runs |
| query_p95_ms | ${P95:-null} | same query, p95 |
| time_travel_ms | ${TT_MS:-null} | \`iceberg_scan(..., snapshot_from_id=<first>)\` — read older snapshot |
| on_disk_bytes | ${DISK:-null} | total bytes of the Iceberg tree on S3 (data + metadata) |
| compression_ratio | null | not measured here (source already columnar) |

**Time-travel note:** Iceberg time-travel is reading an OLDER \`snapshot_id\` recorded
in the metadata tree on object storage. Unlike DuckLake (history is a SQL table), the
cost includes resolving the manifest list + manifest files for that snapshot from S3.
\`time_travel_ms\` above is the wall time of a count over the first snapshot.

> Numbers are measured in-cluster on the lab; absolute values are modest. The
> **format-vs-format comparison** (vs exp-duckdb-parquet / exp-ducklake) is the value.
MD

log "wrote results"
echo "  ${RESULTS_JSON}"
echo "  ${RESULTS_MD}"
[[ -n "${missing}" ]] && echo "  (note: some metrics were null — see notes in results.json)" >&2 || true
echo
echo "teardown when done:  ${0} --teardown"
