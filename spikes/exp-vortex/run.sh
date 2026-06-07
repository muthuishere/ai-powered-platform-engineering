#!/usr/bin/env bash
# run.sh — exp-vortex: deploy MinIO, run the Vortex-vs-Parquet benchmark Job, lift
# results.json out of the pod logs, and render RESULTS.md. Idempotent: re-running
# re-applies manifests and re-runs the bench Job. `--teardown` deletes everything.
#
#   ./run.sh            deploy + run + emit results.json + RESULTS.md
#   ./run.sh --teardown delete the namespace (all resources + PVCs)
#
# Honesty contract: results.json is whatever the Job measured. If the Vortex wheel
# fails to install/run on the node, the Job still captures the Parquet baseline and
# leaves the Vortex metrics null with a reason — this script never invents numbers.
set -euo pipefail

NS="exp-vortex"
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
K8S_DIR="${SCRIPT_DIR}/k8s"
RESULTS_JSON="${SCRIPT_DIR}/results.json"
RESULTS_MD="${SCRIPT_DIR}/RESULTS.md"
JOB_TIMEOUT="${JOB_TIMEOUT:-900s}"

log() { printf '\033[1;36m==>\033[0m %s\n' "$*"; }
die() { printf '\033[1;31merror:\033[0m %s\n' "$*" >&2; exit 1; }

command -v kubectl >/dev/null 2>&1 || die "kubectl not found on PATH"

teardown() {
  log "tearing down namespace ${NS} ..."
  kubectl delete namespace "${NS}" --ignore-not-found --wait=true
  log "done."
}

if [[ "${1:-}" == "--teardown" ]]; then
  teardown
  exit 0
fi

# --- deploy -----------------------------------------------------------------
log "applying namespace + MinIO ..."
kubectl apply -f "${K8S_DIR}/00-namespace.yaml"
kubectl apply -f "${K8S_DIR}/10-minio.yaml"

log "waiting for MinIO to be ready ..."
kubectl -n "${NS}" rollout status statefulset/minio --timeout=300s

log "creating the bench bucket ..."
kubectl -n "${NS}" delete job minio-bootstrap --ignore-not-found
kubectl apply -f "${K8S_DIR}/20-minio-bootstrap-job.yaml"
kubectl -n "${NS}" wait --for=condition=complete job/minio-bootstrap --timeout=180s

# --- run the benchmark ------------------------------------------------------
log "running the Vortex-vs-Parquet benchmark Job (may take a few minutes; pip + 5M rows) ..."
kubectl -n "${NS}" delete job vortex-bench --ignore-not-found
# Re-apply the ConfigMap + Job (ConfigMap is in the same manifest).
kubectl apply -f "${K8S_DIR}/30-bench-job.yaml"

# Wait for completion OR failure, whichever comes first.
log "waiting for the bench Job to finish (timeout ${JOB_TIMEOUT}) ..."
if ! kubectl -n "${NS}" wait --for=condition=complete job/vortex-bench --timeout="${JOB_TIMEOUT}"; then
  # Surface a failure clearly but still try to grab whatever logs exist.
  if kubectl -n "${NS}" wait --for=condition=failed job/vortex-bench --timeout=10s 2>/dev/null; then
    kubectl -n "${NS}" logs job/vortex-bench --all-containers=true || true
    die "bench Job failed — see logs above."
  fi
  die "bench Job did not complete within ${JOB_TIMEOUT}."
fi

# --- lift results.json out of the logs --------------------------------------
log "extracting results.json from pod logs ..."
RAW="$(kubectl -n "${NS}" logs job/vortex-bench -c bench)"
echo "${RAW}" \
  | awk '/=====RESULTS_JSON_BEGIN=====/{f=1;next} /=====RESULTS_JSON_END=====/{f=0} f' \
  > "${RESULTS_JSON}"

[[ -s "${RESULTS_JSON}" ]] || { echo "${RAW}"; die "no results.json sentinel block in logs."; }

# Stamp ran_at (the Job doesn't know wall-clock reliably; stamp it here).
python3 - "${RESULTS_JSON}" <<'PY'
import json, sys, datetime
p = sys.argv[1]
d = json.load(open(p))
d["ran_at"] = datetime.datetime.now(datetime.timezone.utc).isoformat()
json.dump(d, open(p, "w"), indent=2)
PY

log "results.json written to ${RESULTS_JSON}"

# --- render RESULTS.md ------------------------------------------------------
log "rendering RESULTS.md ..."
python3 - "${RESULTS_JSON}" "${RESULTS_MD}" <<'PY'
import json, sys
res = json.load(open(sys.argv[1]))
out = sys.argv[2]

def human(n):
    if n is None: return "—"
    for u in ("B","KiB","MiB","GiB"):
        if n < 1024: return f"{n:.1f} {u}"
        n /= 1024
    return f"{n:.1f} TiB"

f = res.get("formats", {})
pq = f.get("parquet") or {}
vx = f.get("vortex")

def cell(d, k, fmt=str):
    if not d or d.get(k) is None: return "—"
    return fmt(d[k])

lines = []
lines.append("# exp-vortex — Vortex vs Parquet on MinIO (measured)\n")
ds = res.get("dataset", {})
lines.append(f"Dataset: **{ds.get('rows','?'):,} rows**, "
             f"columns `{', '.join(ds.get('schema', []))}`, "
             f"raw Arrow size **{human(ds.get('raw_arrow_bytes'))}**.\n")
lines.append(f"Cluster: `{res.get('cluster','?')}` · ran_at: `{res.get('ran_at','?')}`\n")

lines.append("| metric | Parquet (zstd) | Vortex |")
lines.append("|---|---|---|")
lines.append(f"| on-disk size (MinIO) | {human(pq.get('on_disk_bytes'))} | "
             f"{human(vx.get('on_disk_bytes') if vx else None)} |")
lines.append(f"| compression ratio (raw/disk) | {cell(pq,'compression_ratio', lambda x: f'{x:.2f}x')} | "
             f"{cell(vx,'compression_ratio', lambda x: f'{x:.2f}x') if vx else '—'} |")
lines.append(f"| write / ingest (s) | {cell(pq,'ingest_s', lambda x: f'{x:.3f}')} | "
             f"{cell(vx,'ingest_s', lambda x: f'{x:.3f}') if vx else '—'} |")
lines.append(f"| scan time (s) | {cell(pq,'scan_s', lambda x: f'{x:.3f}')} | "
             f"{cell(vx,'scan_s', lambda x: f'{x:.3f}') if vx else '—'} |")
lines.append(f"| scan throughput (rows/s) | {cell(pq,'scan_rows_per_s', lambda x: f'{x:,}')} | "
             f"{cell(vx,'scan_rows_per_s', lambda x: f'{x:,}') if vx else '—'} |")
lines.append("")

if vx and pq and vx.get("on_disk_bytes") and pq.get("on_disk_bytes"):
    smaller = (1 - vx["on_disk_bytes"]/pq["on_disk_bytes"]) * 100
    verb = "smaller" if smaller >= 0 else "larger"
    lines.append(f"**On this dataset, Vortex is {abs(smaller):.1f}% {verb} on disk than Parquet(zstd).**\n")
elif not vx:
    lines.append("> **Vortex did not run on this node** — Parquet baseline only. "
                 f"Reason: {res.get('notes','')}\n")

lines.append("## notes\n")
lines.append(res.get("notes", "") + "\n")
lines.append("_Numbers are measured per the EXPERIMENTS-SPEC contract; unmeasured "
             "metrics (query p50/p95) are null — this spike measures size + scan, not "
             "point-query latency._\n")

open(out, "w").write("\n".join(lines))
PY

log "RESULTS.md written to ${RESULTS_MD}"
echo
log "summary:"
cat "${RESULTS_JSON}"
echo
log "done. To clean up: ./run.sh --teardown"
