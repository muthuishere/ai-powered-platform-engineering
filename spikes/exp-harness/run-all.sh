#!/usr/bin/env bash
#
# run-all.sh — drive every spike's run.sh, then auto-grade with aggregate.py.
#
# Each spike deploys onto its own Talos cluster. You can either:
#   * point each spike at its own kubeconfig (a directory of per-spike files), or
#   * run them sequentially against one cluster (default — current KUBECONFIG).
#
# Resilience: a failing spike does NOT abort the rest. Its failure is recorded
# and the run continues. aggregate.py then reports any spike without a valid
# results.json as not-run.
#
# Usage:
#   ./run-all.sh                       # sequential, current KUBECONFIG
#   ./run-all.sh --kubeconfig-dir DIR  # per-spike: DIR/<spike>.kubeconfig
#   ./run-all.sh --only exp-vortex,exp-ducklake
#   ./run-all.sh --skip exp-pg-ss-vs-kubevirt
#   ./run-all.sh --dry-run
#
# Exit code is 0 even if some spikes fail (the harness still aggregates what
# ran). Use --strict to exit non-zero when any spike fails.

set -u
set -o pipefail

HARNESS_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
SPIKES_DIR="$(cd "${HARNESS_DIR}/.." && pwd)"

# Canonical spike list (keep in sync with aggregate.py ALL_SPIKES).
SPIKES=(
  exp-pg-statefulset
  exp-pg-ss-vs-kubevirt
  exp-duckdb-parquet
  exp-duckdb-iceberg
  exp-ducklake
  exp-vortex
  exp-arrow-flight
  exp-mochallama-minio-operator
)

KUBECONFIG_DIR=""
ONLY=""
SKIP=""
DRY_RUN=0
STRICT=0

while [ $# -gt 0 ]; do
  case "$1" in
    --kubeconfig-dir) KUBECONFIG_DIR="${2:-}"; shift 2 ;;
    --only)           ONLY="${2:-}"; shift 2 ;;
    --skip)           SKIP="${2:-}"; shift 2 ;;
    --dry-run)        DRY_RUN=1; shift ;;
    --strict)         STRICT=1; shift ;;
    -h|--help)
      sed -n '2,30p' "${BASH_SOURCE[0]}" | sed 's/^# \{0,1\}//'
      exit 0
      ;;
    *) echo "unknown arg: $1" >&2; exit 2 ;;
  esac
done

in_csv() {  # in_csv <needle> <csv>
  local needle="$1" csv="$2" item
  [ -z "$csv" ] && return 1
  IFS=',' read -ra parts <<< "$csv"
  for item in "${parts[@]}"; do
    [ "$item" = "$needle" ] && return 0
  done
  return 1
}

PASS=()
FAIL=()
SKIPPED=()

echo "== run-all: ${#SPIKES[@]} spikes =="
echo "spikes dir: ${SPIKES_DIR}"
[ -n "$KUBECONFIG_DIR" ] && echo "kubeconfig dir: ${KUBECONFIG_DIR} (per-spike)"
echo

for spike in "${SPIKES[@]}"; do
  if [ -n "$ONLY" ] && ! in_csv "$spike" "$ONLY"; then
    SKIPPED+=("$spike"); echo "[skip] $spike (not in --only)"; continue
  fi
  if in_csv "$spike" "$SKIP"; then
    SKIPPED+=("$spike"); echo "[skip] $spike (in --skip)"; continue
  fi

  run_sh="${SPIKES_DIR}/${spike}/run.sh"
  if [ ! -f "$run_sh" ]; then
    echo "[fail] $spike — no run.sh (not yet authored)"
    FAIL+=("$spike")
    continue
  fi

  # Per-spike kubeconfig, if a directory was supplied.
  spike_kubeconfig=""
  if [ -n "$KUBECONFIG_DIR" ]; then
    for cand in "${KUBECONFIG_DIR}/${spike}.kubeconfig" \
                "${KUBECONFIG_DIR}/${spike}.yaml" \
                "${KUBECONFIG_DIR}/${spike}"; do
      if [ -f "$cand" ]; then spike_kubeconfig="$cand"; break; fi
    done
    if [ -z "$spike_kubeconfig" ]; then
      echo "[fail] $spike — no kubeconfig under ${KUBECONFIG_DIR}"
      FAIL+=("$spike")
      continue
    fi
  fi

  echo "------------------------------------------------------------"
  echo "[run ] $spike"
  [ -n "$spike_kubeconfig" ] && echo "       KUBECONFIG=$spike_kubeconfig"

  if [ "$DRY_RUN" -eq 1 ]; then
    echo "       (dry-run; not executing)"
    PASS+=("$spike")
    continue
  fi

  # Run the spike. A non-zero exit is captured, not propagated.
  if [ -n "$spike_kubeconfig" ]; then
    KUBECONFIG="$spike_kubeconfig" bash "$run_sh"
  else
    bash "$run_sh"
  fi
  rc=$?

  if [ "$rc" -eq 0 ]; then
    echo "[ ok ] $spike"
    PASS+=("$spike")
  else
    echo "[fail] $spike (exit $rc) — continuing"
    FAIL+=("$spike")
  fi
done

echo
echo "============================================================"
echo "ran ok : ${#PASS[@]}  ${PASS[*]:-}"
echo "failed : ${#FAIL[@]}  ${FAIL[*]:-}"
echo "skipped: ${#SKIPPED[@]}  ${SKIPPED[*]:-}"
echo

# Always aggregate — even partial results are useful, and missing spikes are
# reported as not-run by aggregate.py.
echo "== auto-grade =="
python3 "${HARNESS_DIR}/aggregate.py"
agg_rc=$?

if [ "$agg_rc" -ne 0 ]; then
  echo "aggregate.py failed (exit $agg_rc)" >&2
  exit "$agg_rc"
fi

if [ "$STRICT" -eq 1 ] && [ "${#FAIL[@]}" -gt 0 ]; then
  echo "strict mode: ${#FAIL[@]} spike(s) failed" >&2
  exit 1
fi

exit 0
