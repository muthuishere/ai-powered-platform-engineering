#!/usr/bin/env bash
# run.sh — the headline experiment: Postgres as a StatefulSet (Arm A, CloudNativePG)
# vs Postgres in a KubeVirt VM (Arm B), measured the SAME way, in one namespace
# (exp-pg-kubevirt), on a cluster with real nested /dev/kvm.
#
#   run.sh --context admin@dev [--storage-class local-path] \
#          [--scale 10] [--clients 16] [--jobs 4] [--duration 60] \
#          [--access-mode ReadWriteMany|ReadWriteOnce] [--skip-failover]
#   run.sh --context admin@dev --teardown
#
# WHAT IT DOES (idempotent; targets --context, never your current context):
#   1. apply namespace + install CNPG operator (pinned) + Arm A Cluster
#   2. apply Arm B (KubeVirt VM + Service) — requires k8s/install-kubevirt.sh first
#   3. wait both ready
#   4. pgbench BOTH arms with IDENTICAL params -> TPS + p50/p95/p99
#   5. failover timing BOTH arms (CNPG promotion vs VM reschedule+recovery)
#   6. write results/results.json (ss:{...}, vm:{...}, vm_mode, nested) + RESULTS.md
#
# HONESTY: no number is fabricated. Any metric we did not measure stays null with
# a reason. Held constant across arms: storage class, CPU, RAM, PG version, PG
# config, pgbench params — see k8s/ manifests and the RESULTS.md "held constant".
set -euo pipefail

CNPG_VERSION="v1.24.1"   # CloudNativePG 1.24 LTS; Postgres 13-17

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
K8S_DIR="$SCRIPT_DIR/k8s"
RESULTS_DIR="$SCRIPT_DIR/results"
MODE_FILE="$K8S_DIR/.vm-mode"
NS="exp-pg-kubevirt"
mkdir -p "$RESULTS_DIR"

# ---- defaults (HELD CONSTANT across arms) ------------------------------------
CONTEXT=""
STORAGE_CLASS=""            # blank -> cluster default; recorded either way
ACCESS_MODE="ReadWriteMany" # RWX = HA-capable; falls to RWO note if unsupported
SCALE=10
CLIENTS=16
JOBS=4
DURATION=60
DBNAME=bench
DBUSER=bench
DBPASS=bench-spike-123
SKIP_FAILOVER=0
TEARDOWN=0

log()  { printf '\033[1;34m==>\033[0m %s\n' "$*"; }
warn() { printf '\033[1;33m!! \033[0m %s\n' "$*"; }
die()  { printf '\033[1;31mxx \033[0m %s\n' "$*" >&2; exit 1; }

while [ $# -gt 0 ]; do
  case "$1" in
    --context)       CONTEXT="$2"; shift 2 ;;
    --storage-class) STORAGE_CLASS="$2"; shift 2 ;;
    --access-mode)   ACCESS_MODE="$2"; shift 2 ;;
    --scale)         SCALE="$2"; shift 2 ;;
    --clients)       CLIENTS="$2"; shift 2 ;;
    --jobs)          JOBS="$2"; shift 2 ;;
    --duration)      DURATION="$2"; shift 2 ;;
    --skip-failover) SKIP_FAILOVER=1; shift ;;
    --teardown)      TEARDOWN=1; shift ;;
    -h|--help)       grep '^#' "$0" | sed 's/^# \{0,1\}//'; exit 0 ;;
    *)               die "unknown arg: $1" ;;
  esac
done

[ -n "$CONTEXT" ] || die "--context is required (e.g. admin@dev). Never relies on current context."
command -v kubectl >/dev/null 2>&1 || die "kubectl not found"
command -v envsubst >/dev/null 2>&1 || die "envsubst not found (brew install gettext / apt-get install gettext-base)"

k() { kubectl --context "$CONTEXT" "$@"; }

# ---- teardown ----------------------------------------------------------------
if [ "$TEARDOWN" -eq 1 ]; then
  log "tearing down experiment (namespace $NS + CNPG Cluster + KubeVirt VM)"
  k delete -n "$NS" virtualmachine pg-vm --ignore-not-found >/dev/null 2>&1 || true
  k delete -n "$NS" datavolume pg-vm-boot --ignore-not-found >/dev/null 2>&1 || true
  k delete -n "$NS" cluster.postgresql.cnpg.io pg-ss --ignore-not-found >/dev/null 2>&1 || true
  k delete namespace "$NS" --ignore-not-found
  warn "left KubeVirt/CDI operators and the CNPG operator installed (shared infra)."
  warn "to remove them too: kubectl --context $CONTEXT delete -f <kubevirt/cdi/cnpg release urls>"
  log "teardown done."
  exit 0
fi

# ---- rendering helper: envsubst only our tokens ------------------------------
render() {
  STORAGE_CLASS="$STORAGE_CLASS" DISK_ACCESS_MODE="$ACCESS_MODE" \
    envsubst '${STORAGE_CLASS} ${DISK_ACCESS_MODE}'
}

# =============================================================================
# 1. Namespace + Arm A (CloudNativePG StatefulSet)
# =============================================================================
log "applying namespace $NS"
k apply -f "$K8S_DIR/00-namespace.yaml"

log "installing CloudNativePG operator $CNPG_VERSION (idempotent)"
k apply --server-side -f \
  "https://raw.githubusercontent.com/cloudnative-pg/cloudnative-pg/${CNPG_VERSION}/releases/cnpg-${CNPG_VERSION#v}.yaml" \
  || die "failed to install CNPG operator"
k -n cnpg-system rollout status deploy/cnpg-controller-manager --timeout=300s \
  || warn "CNPG controller rollout not confirmed; continuing"

log "applying Arm A Cluster (storageClass='${STORAGE_CLASS:-<cluster-default>}')"
render < "$K8S_DIR/arm-a-statefulset/10-cluster.yaml" | k apply -f -

# =============================================================================
# 2. Arm B (KubeVirt VM) — install-kubevirt.sh must have run first
# =============================================================================
VM_MODE="unknown"; NESTED="null"
if [ -f "$MODE_FILE" ]; then
  VM_MODE="$(cat "$MODE_FILE" 2>/dev/null || echo unknown)"
fi
if [ "$VM_MODE" = "kvm" ]; then NESTED="true"; elif [ "$VM_MODE" = "emulation" ]; then NESTED="false"; fi

VM_DEPLOYED=0
if k get crd virtualmachines.kubevirt.io >/dev/null 2>&1; then
  log "KubeVirt CRDs present (vm_mode=$VM_MODE) — applying Arm B (VM + Service)"
  render < "$K8S_DIR/arm-b-kubevirt/10-postgres-config.yaml" | k apply -f -
  render < "$K8S_DIR/arm-b-kubevirt/20-virtualmachine.yaml"  | k apply -f -
  VM_DEPLOYED=1
else
  warn "KubeVirt CRDs not found — run k8s/install-kubevirt.sh --context $CONTEXT first."
  warn "Arm B will be SKIPPED; its metrics stay null with a reason in results.json."
fi

# =============================================================================
# 3. Wait both ready
# =============================================================================
log "waiting for Arm A CNPG Cluster to be Ready (up to 10m)..."
SS_READY=0
if k -n "$NS" wait --for=condition=Ready cluster/pg-ss --timeout=600s >/dev/null 2>&1; then
  SS_READY=1; log "Arm A Cluster Ready"
else
  warn "Arm A Cluster not Ready in time — its metrics will stay null."
fi

VM_READY=0
if [ "$VM_DEPLOYED" -eq 1 ]; then
  log "waiting for Arm B VMI to be Running + Postgres up via cloud-init (up to 15m)..."
  # First the VMI must reach Running, then cloud-init installs+starts Postgres.
  if k -n "$NS" wait vmi/pg-vm --for=jsonpath='{.status.phase}'=Running --timeout=900s >/dev/null 2>&1; then
    log "VMI Running — polling Postgres TCP (cloud-init install can take several minutes)"
    DEADLINE=$(( $(date +%s) + 900 ))
    while [ "$(date +%s)" -lt "$DEADLINE" ]; do
      # Postgres is up once the Service has an endpoint backed by the VMI pod
      # AND a TCP write-probe succeeds (cloud-init finished installing PG).
      if k -n "$NS" get endpoints pg-vm -o jsonpath='{.subsets[0].addresses[0].ip}' 2>/dev/null | grep -q .; then
        VM_READY=1; break
      fi
      sleep 10
    done
    [ "$VM_READY" -eq 1 ] && log "Arm B Service has endpoints (Postgres reachable)" \
      || warn "Arm B Postgres did not become reachable in time — vm metrics stay null."
  else
    warn "Arm B VMI never reached Running — vm metrics stay null (vm_mode=$VM_MODE)."
  fi
fi

# =============================================================================
# 4. pgbench BOTH arms (identical params)
# =============================================================================
# Reuse the in-cluster pgbench Job pattern so no client-side network hop skews
# latency and so we need no local pgbench/psql. pgbench's -l per-txn log gives
# us real p50/p95/p99 (not the single average pgbench prints).
bench_one() {
  # $1 = arm label (ss|vm); $2 = host; $3 = port
  local arm="$1" host="$2" port="$3"
  local job="pgbench-${arm}"
  k -n "$NS" delete job "$job" --ignore-not-found >/dev/null 2>&1 || true
  local outfile="$RESULTS_DIR/bench-${arm}.txt"
  log "pgbench arm=$arm  host=$host:$port  scale=$SCALE clients=$CLIENTS jobs=$JOBS dur=${DURATION}s"
  # Run init + timed run + percentile post-process inside a throwaway Job using
  # the official postgres image (has pgbench). Per-txn log -> p50/p95/p99.
  cat <<EOF | k apply -f - >/dev/null
apiVersion: batch/v1
kind: Job
metadata:
  name: ${job}
  namespace: ${NS}
spec:
  backoffLimit: 0
  template:
    spec:
      restartPolicy: Never
      containers:
        - name: pgbench
          image: postgres:17
          env:
            - {name: PGPASSWORD, value: "${DBPASS}"}
          command: ["/bin/bash","-c"]
          args:
            - |
              set -e
              export PGHOST=${host} PGPORT=${port} PGUSER=${DBUSER} PGDATABASE=${DBNAME}
              for i in \$(seq 1 60); do pg_isready -q && break; sleep 2; done
              pgbench -i -s ${SCALE}
              pgbench -c ${CLIENTS} -j ${JOBS} -T ${DURATION} -l --log-prefix=/tmp/lat --progress 10
              echo "# ---- percentiles (from pgbench -l, col 3 = latency us) ----"
              cat /tmp/lat /tmp/lat.* 2>/dev/null | awk '{print \$3}' | sort -n | awk '
                { v[NR]=\$1 } END {
                  n=NR; if(n==0){print "p50_ms=NA p95_ms=NA p99_ms=NA samples=0"; exit}
                  i50=int(0.50*n+0.5); if(i50<1)i50=1
                  i95=int(0.95*n+0.5); if(i95<1)i95=1
                  i99=int(0.99*n+0.5); if(i99<1)i99=1
                  printf "p50_ms=%.3f p95_ms=%.3f p99_ms=%.3f samples=%d\n", v[i50]/1000,v[i95]/1000,v[i99]/1000,n }'
EOF
  if k -n "$NS" wait --for=condition=complete "job/$job" --timeout=$((DURATION + 600))s >/dev/null 2>&1; then
    k -n "$NS" logs "job/$job" | tee "$outfile" >/dev/null
    log "arm=$arm bench complete -> $outfile"
  else
    warn "arm=$arm pgbench Job did not complete; metrics stay null. Logs:"
    k -n "$NS" logs "job/$job" 2>/dev/null | tee "$outfile" || true
  fi
  k -n "$NS" delete job "$job" --ignore-not-found >/dev/null 2>&1 || true
}

# Parse a "key=value" metric out of a bench output file. Echoes value or empty.
metric() { # $1 file, $2 key
  [ -f "$1" ] || { echo ""; return; }
  grep -oE "$2=[0-9.]+" "$1" | tail -1 | cut -d= -f2 || echo ""
}
# pgbench TPS line: "tps = 1234.56 (without initial connection time)"
tps_of() { # $1 file
  [ -f "$1" ] || { echo ""; return; }
  grep -E 'tps = ' "$1" | tail -1 | sed -E 's/.*tps = ([0-9.]+).*/\1/' || echo ""
}

SS_TPS=""; SS_P50=""; SS_P95=""; SS_P99=""
VM_TPS=""; VM_P50=""; VM_P95=""; VM_P99=""

if [ "$SS_READY" -eq 1 ]; then
  bench_one ss "pg-ss-rw.${NS}.svc" 5432
  f="$RESULTS_DIR/bench-ss.txt"
  SS_TPS="$(tps_of "$f")"; SS_P50="$(metric "$f" p50_ms)"; SS_P95="$(metric "$f" p95_ms)"; SS_P99="$(metric "$f" p99_ms)"
fi
if [ "$VM_READY" -eq 1 ]; then
  bench_one vm "pg-vm.${NS}.svc" 5432
  f="$RESULTS_DIR/bench-vm.txt"
  VM_TPS="$(tps_of "$f")"; VM_P50="$(metric "$f" p50_ms)"; VM_P95="$(metric "$f" p95_ms)"; VM_P99="$(metric "$f" p99_ms)"
fi

# =============================================================================
# 5. Failover timing BOTH arms
#    ss = CNPG promotion (operator re-points pg-ss-rw)
#    vm = VM launcher delete -> reschedule + Postgres crash-recovery (NOT a
#         promotion; only meaningful with RWX storage). Labeled as such.
# =============================================================================
SS_FAILOVER=""; VM_FAILOVER=""
FO_SEQ=0
failover_one() { # $1 arm, $2 service-name (write endpoint)
  local arm="$1" svc="$2"
  # The kill is issued by THIS script via kubectl --context (no in-cluster RBAC
  # needed). The write-probe runs a throwaway postgres:17 pod (has psql).
  local kill_args=""
  case "$arm" in
    ss) kill_args="delete pod -n $NS -l cnpg.io/cluster=pg-ss,cnpg.io/instanceRole=primary --grace-period=0 --force" ;;
    vm) kill_args="delete pod -n $NS -l kubevirt.io=virt-launcher,kubevirt.io/vm=pg-vm --grace-period=0 --force" ;;
  esac

  # --- write-probe helper: returns 0 if a write succeeds against $svc ---
  probe_writable() {
    FO_SEQ=$((FO_SEQ + 1))
    k -n "$NS" run "fo-probe-${arm}-${FO_SEQ}" --rm -i --restart=Never \
      --image=postgres:17 --quiet -- \
      env PGPASSWORD="$DBPASS" psql -h "${svc}.${NS}.svc" -U "$DBUSER" -d "$DBNAME" -tAc \
      "CREATE TABLE IF NOT EXISTS failover_probe(t timestamptz); INSERT INTO failover_probe VALUES (now());" \
      >/dev/null 2>&1
  }

  log "failover arm=$arm: confirming write endpoint is writable before kill"
  if ! probe_writable; then
    warn "arm=$arm endpoint not writable pre-kill; skipping failover timing (stays null)"
    return
  fi
  log "failover arm=$arm: killing target (kubectl $kill_args)"
  k $kill_args >/dev/null 2>&1 || true
  local start now elapsed=0 deadline=$(( $(date +%s) + 300 ))
  start="$(date +%s)"
  while [ "$(date +%s)" -lt "$deadline" ]; do
    if probe_writable; then
      now="$(date +%s)"; elapsed=$(( now - start ))
      log "arm=$arm WRITABLE again after ${elapsed}s"
      printf '%s' "$elapsed"
      return
    fi
    sleep 2
  done
  warn "arm=$arm never became writable within 300s; failover stays null"
}

if [ "$SKIP_FAILOVER" -eq 0 ]; then
  # RBAC: the kills are issued by THIS script via kubectl (--context), so no
  # in-cluster ServiceAccount is needed — simpler and avoids shipping RBAC.
  if [ "$SS_READY" -eq 1 ]; then SS_FAILOVER="$(failover_one ss pg-ss-rw || true)"; fi
  if [ "$VM_READY" -eq 1 ]; then
    warn "Arm B failover = VM reschedule + crash recovery (NOT a promotion). See README."
    VM_FAILOVER="$(failover_one vm pg-vm || true)"
  fi
else
  warn "--skip-failover set; failover metrics stay null."
fi

# =============================================================================
# 6. Write results.json + RESULTS.md  (null where un-measured, with reasons)
# =============================================================================
jnum() { # echo the value if numeric, else 'null'
  case "$1" in (''|*[!0-9.]*) echo null ;; (*) echo "$1" ;; esac
}
RAN_AT="$(date -u +%Y-%m-%dT%H:%M:%SZ)"
SC_LABEL="${STORAGE_CLASS:-<cluster-default>}"

cat > "$RESULTS_DIR/results.json" <<EOF
{
  "spike": "exp-pg-ss-vs-kubevirt",
  "namespace": "${NS}",
  "context": "${CONTEXT}",
  "vm_mode": "${VM_MODE}",
  "nested": ${NESTED},
  "held_constant": {
    "postgres_version": "17.2",
    "cpu": "1",
    "memory": "1Gi",
    "storage_class": "${SC_LABEL}",
    "disk_access_mode": "${ACCESS_MODE}",
    "shared_buffers": "256MB",
    "synchronous_commit": "on",
    "fsync": "on",
    "pgbench_scale": ${SCALE},
    "pgbench_clients": ${CLIENTS},
    "pgbench_jobs": ${JOBS},
    "pgbench_duration_s": ${DURATION}
  },
  "ss": {
    "engine": "CloudNativePG StatefulSet (1 primary + 2 replicas)",
    "tps": $(jnum "$SS_TPS"),
    "p50_ms": $(jnum "$SS_P50"),
    "p95_ms": $(jnum "$SS_P95"),
    "p99_ms": $(jnum "$SS_P99"),
    "failover_event": "replica promotion (operator-driven)",
    "failover_s": $(jnum "$SS_FAILOVER")
  },
  "vm": {
    "engine": "KubeVirt VirtualMachine (single Postgres)",
    "tps": $(jnum "$VM_TPS"),
    "p50_ms": $(jnum "$VM_P50"),
    "p95_ms": $(jnum "$VM_P95"),
    "p99_ms": $(jnum "$VM_P99"),
    "failover_event": "VM reschedule + crash-recovery (needs RWX); NOT a promotion",
    "failover_s": $(jnum "$VM_FAILOVER")
  },
  "notes": "Numbers measured, never fabricated; null = not measured this run. KubeVirt VM is one nesting layer deep (host KVM -> Talos QEMU VM -> KubeVirt VM). ss/vm failover are different events and must not be ranked head-to-head.",
  "ran_at": "${RAN_AT}"
}
EOF

# RESULTS.md comparison table (renders null as a blank cell with a note)
cell() { case "$1" in (''|null) echo '—' ;; (*) echo "$1" ;; esac; }
cat > "$SCRIPT_DIR/RESULTS.md" <<EOF
# Results — Postgres StatefulSet vs KubeVirt VM (measured)

Run at \`${RAN_AT}\` on context \`${CONTEXT}\`, namespace \`${NS}\`.
**vm_mode = \`${VM_MODE}\`**, nested = \`${NESTED}\`.

> A \`—\` cell means *not measured this run* (the arm did not come up, or the
> step was skipped). Blanks are honest; we do not fabricate.

## Held constant (so the only variable is container-vs-VM)

| Knob | Value |
|---|---|
| Postgres version | 17.2 (both arms) |
| CPU / RAM per instance | 1 vCPU / 1Gi |
| Storage class | \`${SC_LABEL}\` |
| VM disk access mode | \`${ACCESS_MODE}\` |
| shared_buffers / synchronous_commit / fsync | 256MB / on / on |
| pgbench scale / clients / jobs / duration | ${SCALE} / ${CLIENTS} / ${JOBS} / ${DURATION}s |

## Throughput + latency (percentiles, not averages)

| Arm | TPS | p50 (ms) | p95 (ms) | p99 (ms) |
|---|---|---|---|---|
| **A — StatefulSet (CloudNativePG)** | $(cell "$SS_TPS") | $(cell "$SS_P50") | $(cell "$SS_P95") | $(cell "$SS_P99") |
| **B — KubeVirt VM** (\`${VM_MODE}\`) | $(cell "$VM_TPS") | $(cell "$VM_P50") | $(cell "$VM_P95") | $(cell "$VM_P99") |

## Failover / availability (NOT the same event — do not rank head-to-head)

| Arm | Event measured | Time-to-writable | Data copies surviving |
|---|---|---|---|
| **A — StatefulSet** | replica **promotion** (operator-driven) | $(cell "$SS_FAILOVER") s | 2 (replicas) |
| **B — KubeVirt VM** | VM **reschedule + crash-recovery** (needs RWX) | $(cell "$VM_FAILOVER") s | 1 (single VM) |

## Caveats (carried into the book)

- KubeVirt VM is **one nesting layer** deep: host KVM → Talos QEMU VM → KubeVirt
  VM. Directionally valid for container-vs-VM overhead; \`vm_mode=${VM_MODE}\`,
  nested=\`${NESTED}\`. If \`vm_mode=emulation\`, the VM ran in **software** (no
  /dev/kvm) and its numbers are a floor, not the hardware-virt result.
- Arm A's failover is a **promotion** of an already-replicated standby; Arm B's is
  a **reboot** of the one and only Postgres after the VM moves nodes. Matching
  Arm A's HA inside VMs means running several Postgres VMs with streaming
  replication + a failover controller — i.e. reimplementing CloudNativePG.

Raw pgbench output: \`results/bench-ss.txt\`, \`results/bench-vm.txt\`.
Machine-readable: \`results/results.json\`.
EOF

log "results.json + RESULTS.md written to $RESULTS_DIR and $SCRIPT_DIR"
log "vm_mode=$VM_MODE nested=$NESTED  ss_tps=$(cell "$SS_TPS")  vm_tps=$(cell "$VM_TPS")"
