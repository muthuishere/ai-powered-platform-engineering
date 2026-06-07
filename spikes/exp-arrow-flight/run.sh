#!/usr/bin/env bash
# run.sh — deploy the Arrow Flight spike, run the client benchmark, emit metrics.
#
#   ./run.sh            deploy server -> wait ready -> run client Job -> results.json + RESULTS.md
#   ./run.sh --teardown delete the namespace (everything in it) and exit
#
# Idempotent: re-applies manifests, recreates the client Job, uses the CURRENT
# kube context (does not switch contexts). Numbers come from the client Job logs —
# nothing here is fabricated; if the run fails, metrics stay null with a reason.
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
K8S_DIR="${SCRIPT_DIR}/k8s"
NS="exp-arrow-flight"
SPIKE="exp-arrow-flight"
RESULTS_JSON="${SCRIPT_DIR}/results.json"
RESULTS_MD="${SCRIPT_DIR}/RESULTS.md"
CLUSTER="unknown"

log() { printf '\033[1;36m==>\033[0m %s\n' "$*"; }
err() { printf '\033[1;31merror:\033[0m %s\n' "$*" >&2; }

# write_results <metrics-json-or-"null"> <note>  ->  results.json (contract envelope) + RESULTS.md
write_results() {
  local metrics="$1" note="$2" ran_at
  ran_at="$(date -u +%Y-%m-%dT%H:%M:%SZ)"
  if [[ "${metrics}" == "null" ]]; then
    cat > "${RESULTS_JSON}" <<EOF
{
  "spike": "${SPIKE}",
  "cluster": "${CLUSTER}",
  "metrics": {
    "scan_rows_per_s": null,
    "query_p50_ms": null,
    "query_p95_ms": null,
    "on_disk_bytes": null
  },
  "notes": "${note}",
  "ran_at": "${ran_at}"
}
EOF
  elif command -v python3 >/dev/null 2>&1; then
    SPIKE="${SPIKE}" CLUSTER="${CLUSTER}" NOTE="${note}" RAN_AT="${ran_at}" \
      METRICS="${metrics}" python3 - "${RESULTS_JSON}" <<'PY'
import json, os, sys
m = json.loads(os.environ["METRICS"])
out = {
    "spike": os.environ["SPIKE"],
    "cluster": os.environ["CLUSTER"],
    "metrics": m,
    "notes": os.environ["NOTE"],
    "ran_at": os.environ["RAN_AT"],
}
with open(sys.argv[1], "w") as f:
    json.dump(out, f, indent=2)
    f.write("\n")
PY
  else
    cat > "${RESULTS_JSON}" <<EOF
{ "spike": "${SPIKE}", "cluster": "${CLUSTER}",
  "metrics": ${metrics},
  "notes": "${note}", "ran_at": "${ran_at}" }
EOF
  fi
  render_md
}

render_md() {
  command -v python3 >/dev/null 2>&1 || return 0
  [[ -f "${RESULTS_JSON}" ]] || return 0
  python3 - "${RESULTS_JSON}" "${RESULTS_MD}" <<'PY'
import json, sys
data = json.load(open(sys.argv[1]))
m = data.get("metrics", {})
def g(k):
    v = m.get(k)
    return "null" if v is None else v
def mb(k):
    v = m.get(k)
    return "null" if v is None else f"{v/1e6:.1f} MB ({v:,} B)"
def intcell(k):
    v = g(k)
    return f"{v:,}" if isinstance(v, int) else f"{v}"
L = []
L.append(f"# Results — {data['spike']}\n")
L.append(f"- cluster: `{data.get('cluster','?')}`")
L.append(f"- ran_at: `{data.get('ran_at','?')}`")
L.append(f"- notes: {data.get('notes','')}\n")
L.append("## Flight (DoGet) throughput + latency\n")
L.append("| metric | value |")
L.append("|---|---|")
L.append(f"| rows in dataset | {intcell('rows')} |")
L.append(f"| scan_rows_per_s (best) | {intcell('scan_rows_per_s')} |")
L.append(f"| query_p50_ms | {g('query_p50_ms')} |")
L.append(f"| query_p95_ms | {g('query_p95_ms')} |")
L.append(f"| query_min_ms | {g('query_min_ms')} |")
L.append(f"| query_mean_ms | {g('query_mean_ms')} |")
L.append(f"| iters | {g('iters')} |")
L.append("\n## On-disk size — Feather (Arrow IPC) vs Parquet, both zstd\n")
L.append("| store | size |")
L.append("|---|---|")
L.append(f"| in-memory (Arrow) | {mb('in_memory_bytes')} |")
L.append(f"| Feather / Arrow IPC | {mb('feather_bytes')} |")
L.append(f"| Parquet | {mb('parquet_bytes')} |")
fb, pb = m.get("feather_bytes"), m.get("parquet_bytes")
if isinstance(fb, int) and isinstance(pb, int) and pb:
    L.append(f"\nFeather/Parquet size ratio: **{fb/pb:.2f}x** "
             f"(>1 means Feather is larger on disk).")
open(sys.argv[2], "w").write("\n".join(L) + "\n")
PY
}

teardown() {
  log "tearing down namespace ${NS} (current context: $(kubectl config current-context))"
  kubectl delete namespace "${NS}" --ignore-not-found --wait=false
  log "teardown requested."
}

main() {
  command -v kubectl >/dev/null 2>&1 || { err "kubectl not found on PATH"; exit 1; }

  if [[ "${1:-}" == "--teardown" ]]; then
    teardown
    exit 0
  fi

  local ctx
  ctx="$(kubectl config current-context)"
  CLUSTER="$(kubectl config view --minify -o jsonpath='{.clusters[0].name}' 2>/dev/null || echo unknown)"
  log "current kube context: ${ctx} (cluster: ${CLUSTER})"

  # ---- deploy --------------------------------------------------------------
  log "applying namespace + Flight server"
  kubectl apply -f "${K8S_DIR}/00-namespace.yaml"
  kubectl apply -f "${K8S_DIR}/10-flight-server.yaml"

  log "waiting for flight-server ready (pip install + table build can take a minute)"
  if ! kubectl -n "${NS}" rollout status deploy/flight-server --timeout=300s; then
    err "flight-server did not become ready; recent logs:"
    kubectl -n "${NS}" logs deploy/flight-server --tail=40 || true
    write_results "null" "flight-server failed to become ready"
    exit 1
  fi

  # ---- run the client Job --------------------------------------------------
  log "(re)creating client Job"
  kubectl -n "${NS}" delete job flight-client --ignore-not-found --wait=true
  kubectl apply -f "${K8S_DIR}/20-flight-client-job.yaml"

  log "waiting for client Job to finish"
  if ! kubectl -n "${NS}" wait --for=condition=complete job/flight-client --timeout=300s 2>/dev/null; then
    if kubectl -n "${NS}" wait --for=condition=failed job/flight-client --timeout=10s 2>/dev/null; then
      err "client Job failed; logs:"
      kubectl -n "${NS}" logs job/flight-client --tail=60 || true
      write_results "null" "client Job failed"
      exit 1
    fi
  fi

  log "client Job logs:"
  local client_log metrics_line metrics
  client_log="$(kubectl -n "${NS}" logs job/flight-client)"
  printf '%s\n' "${client_log}"

  # ---- extract measured metrics -------------------------------------------
  metrics_line="$(printf '%s\n' "${client_log}" | grep -E '^RESULTS_JSON=' | tail -1 || true)"
  if [[ -z "${metrics_line}" ]]; then
    err "no RESULTS_JSON line in client logs — metrics unavailable"
    write_results "null" "client produced no RESULTS_JSON line"
    exit 1
  fi
  metrics="${metrics_line#RESULTS_JSON=}"

  write_results "${metrics}" "measured in-cluster over Arrow Flight DoGet against the flight-server Service"
  log "wrote ${RESULTS_JSON} and ${RESULTS_MD}"
}

main "$@"
