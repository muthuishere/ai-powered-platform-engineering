#!/usr/bin/env bash
# Kill the primary and time time-to-writable.
#
#   failover-test.sh --context admin@dev --arm ss
#   failover-test.sh --context admin@dev --arm vm
#
# WHAT EACH ARM ACTUALLY MEASURES (these are NOT the same event — see README):
#
#   --arm ss : application-level failover. We delete the primary pod; CloudNativePG
#              detects it, PROMOTES a replica, and re-points the pg-rw Service.
#              time-to-writable = from kill until a write succeeds on pg-rw.
#
#   --arm vm : there is only ONE Postgres. Deleting the VM's launcher pod forces a
#              reschedule (only possible at all if the disk is on RWX storage),
#              then Postgres CRASH-RECOVERS on boot. time-to-writable = from delete
#              until a write succeeds again. This is reschedule+recovery, NOT a
#              promotion, and is shown only to make the difference concrete.
set -euo pipefail

CONTEXT=""
ARM=""
DBNAME=bench
DBUSER=bench
DBPASS=bench-spike-123
TIMEOUT=300        # seconds to wait for writable before giving up

log()  { printf '\033[1;34m==>\033[0m %s\n' "$*"; }
warn() { printf '\033[1;33m!! \033[0m %s\n' "$*"; }
die()  { printf '\033[1;31mxx \033[0m %s\n' "$*" >&2; exit 1; }

while [ $# -gt 0 ]; do
  case "$1" in
    --context) CONTEXT="$2"; shift 2 ;;
    --arm)     ARM="$2"; shift 2 ;;
    --timeout) TIMEOUT="$2"; shift 2 ;;
    -h|--help) grep '^#' "$0" | sed 's/^# \{0,1\}//'; exit 0 ;;
    *)         die "unknown arg: $1" ;;
  esac
done

[ -n "$CONTEXT" ] || die "--context is required (e.g. admin@dev)"
case "$ARM" in ss|vm) ;; *) die "--arm must be 'ss' or 'vm'" ;; esac
command -v kubectl >/dev/null 2>&1 || die "kubectl not found"
command -v psql    >/dev/null 2>&1 || die "psql not found (brew install libpq)"

NS=""; SVC=""; LPORT=""
case "$ARM" in
  ss) NS=pgbench-ss; SVC=pg-rw;  LPORT=55432 ;;
  vm) NS=pgbench-vm; SVC=pg-vm;  LPORT=55433 ;;
esac

# port-forward the write endpoint so we can poll it from here.
kubectl --context "$CONTEXT" -n "$NS" port-forward "svc/$SVC" "$LPORT:5432" >/dev/null 2>&1 &
PF=$!; trap 'kill $PF 2>/dev/null || true' EXIT
sleep 3
export PGPASSWORD="$DBPASS"

writable() {
  # returns 0 if we can do a write against the -rw endpoint
  psql -h 127.0.0.1 -p "$LPORT" -U "$DBUSER" -d "$DBNAME" -tAc \
    "CREATE TABLE IF NOT EXISTS failover_probe(t timestamptz); INSERT INTO failover_probe VALUES (now());" \
    >/dev/null 2>&1
}

log "pre-check: confirming the write endpoint is writable before we kill anything"
writable || die "endpoint not writable to begin with — bring the arm up first"

# ---- identify + kill the primary --------------------------------------------
case "$ARM" in
  ss)
    PRIMARY="$(kubectl --context "$CONTEXT" -n "$NS" get pods \
      -l 'cnpg.io/cluster=pg,cnpg.io/instanceRole=primary' \
      -o jsonpath='{.items[0].metadata.name}' 2>/dev/null || true)"
    [ -n "$PRIMARY" ] || die "could not find CNPG primary pod"
    log "killing CNPG primary pod: $PRIMARY"
    kubectl --context "$CONTEXT" -n "$NS" delete pod "$PRIMARY" --grace-period=0 --force >/dev/null 2>&1 || true
    ;;
  vm)
    LAUNCHER="$(kubectl --context "$CONTEXT" -n "$NS" get pods \
      -l 'kubevirt.io=virt-launcher,kubevirt.io/vm=pg-vm' \
      -o jsonpath='{.items[0].metadata.name}' 2>/dev/null || true)"
    [ -n "$LAUNCHER" ] || die "could not find virt-launcher pod for pg-vm"
    warn "deleting the VM launcher pod ($LAUNCHER) — this is reschedule+crash-recovery,"
    warn "NOT a replica promotion. See README HA section."
    kubectl --context "$CONTEXT" -n "$NS" delete pod "$LAUNCHER" --grace-period=0 --force >/dev/null 2>&1 || true
    ;;
esac

# ---- time to writable --------------------------------------------------------
START="$(date +%s)"
log "polling $SVC for write availability (timeout ${TIMEOUT}s)..."
while :; do
  NOW="$(date +%s)"; ELAPSED=$((NOW - START))
  if [ "$ELAPSED" -ge "$TIMEOUT" ]; then
    die "timed out after ${TIMEOUT}s — endpoint never became writable"
  fi
  # the port-forward may drop when the pod dies; restart it opportunistically.
  if ! kill -0 "$PF" 2>/dev/null; then
    kubectl --context "$CONTEXT" -n "$NS" port-forward "svc/$SVC" "$LPORT:5432" >/dev/null 2>&1 &
    PF=$!; sleep 2
  fi
  if writable; then
    log "WRITABLE again after ${ELAPSED}s"
    echo "arm=$ARM time_to_writable_s=$ELAPSED"
    break
  fi
  sleep 1
done

warn "record this as failover-time for arm '$ARM' in RESULTS-TEMPLATE.md."
warn "remember: ss=promotion, vm=reschedule+recovery — do not treat them as equal."
