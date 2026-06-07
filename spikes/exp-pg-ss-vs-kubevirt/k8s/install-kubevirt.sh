#!/usr/bin/env bash
# install-kubevirt.sh — install KubeVirt + CDI on a Talos cluster and verify that
# /dev/kvm is usable (real nested virtualization), falling back to software
# emulation only if it is not.
#
#   install-kubevirt.sh --context admin@dev [--emulation-fallback]
#
# Pinned versions (bump deliberately, in lockstep):
#   KubeVirt v1.5.0  (released 2025-03; built for Kubernetes v1.32, +2 prior)
#   CDI      v1.62.0 (the CDI paired with the KubeVirt 1.5.x line)
# Refs:
#   https://docs.siderolabs.com/talos/v1.8/advanced-guides/install-kubevirt
#   https://kubevirt.io/2025/KubeVirt-v1-5_release.html
#   https://github.com/kubevirt/containerized-data-importer/releases
#
# KVM vs emulation:
#   This experiment WANTS real KVM (host KVM -> Talos QEMU VM -> KubeVirt VM, one
#   nesting layer). KubeVirt's virt-handler auto-detects /dev/kvm on each node and
#   advertises the `kvm` device + the `kvm-info-nfd-plugin` label. If KVM is NOT
#   present, KubeVirt VMs fail to start unless useEmulation=true is set on the CR
#   (software emulation — correct but much slower). We PREFER KVM and only enable
#   emulation when --emulation-fallback is passed AND KVM is absent. The chosen
#   mode is written to k8s/.vm-mode so run.sh records it (vm_mode + nested) in
#   results.json — no silently-emulated numbers.
#
# Talos note: KubeVirt needs no special Talos machine-config patch for KVM beyond
# the host exposing /dev/kvm to the Talos QEMU guest (nested virt enabled on the
# bare-metal host's BIOS + the host's QEMU/libvirt). virt-handler runs privileged;
# the kubevirt namespace is labeled privileged below for Pod Security admission.
set -euo pipefail

KUBEVIRT_VERSION="v1.5.0"
CDI_VERSION="v1.62.0"

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
MODE_FILE="$SCRIPT_DIR/.vm-mode"

CONTEXT=""
EMULATION_FALLBACK=0

log()  { printf '\033[1;34m==>\033[0m %s\n' "$*"; }
warn() { printf '\033[1;33m!! \033[0m %s\n' "$*"; }
die()  { printf '\033[1;31mxx \033[0m %s\n' "$*" >&2; exit 1; }

while [ $# -gt 0 ]; do
  case "$1" in
    --context)             CONTEXT="$2"; shift 2 ;;
    --emulation-fallback)  EMULATION_FALLBACK=1; shift ;;
    -h|--help)             grep '^#' "$0" | sed 's/^# \{0,1\}//'; exit 0 ;;
    *)                     die "unknown arg: $1" ;;
  esac
done

[ -n "$CONTEXT" ] || die "--context is required (e.g. admin@dev). Never relies on current context."
command -v kubectl >/dev/null 2>&1 || die "kubectl not found"

k() { kubectl --context "$CONTEXT" "$@"; }

# ---- KubeVirt operator + CR --------------------------------------------------
log "installing KubeVirt operator $KUBEVIRT_VERSION"
k apply -f "https://github.com/kubevirt/kubevirt/releases/download/${KUBEVIRT_VERSION}/kubevirt-operator.yaml"

# Label the kubevirt namespace privileged so virt-handler (privileged DaemonSet)
# is admitted under restricted Pod Security defaults.
k label namespace kubevirt pod-security.kubernetes.io/enforce=privileged --overwrite >/dev/null 2>&1 || true

log "applying KubeVirt CR (LiveMigration feature gate; emulation OFF — prefer real KVM)"
k apply -f "https://github.com/kubevirt/kubevirt/releases/download/${KUBEVIRT_VERSION}/kubevirt-cr.yaml"
# Enable LiveMigration (needed for the HA story); leave useEmulation false.
k -n kubevirt patch kubevirt kubevirt --type merge -p '{
  "spec":{"configuration":{"developerConfiguration":{
    "featureGates":["LiveMigration"]
  }}}}' >/dev/null 2>&1 || true

log "waiting for KubeVirt CR to become Available (up to 10m)..."
k -n kubevirt wait kv kubevirt --for=condition=Available --timeout=600s \
  || die "KubeVirt CR did not become Available — check 'kubectl -n kubevirt get kv kubevirt -o yaml'"

# ---- CDI operator + CR -------------------------------------------------------
log "installing CDI $CDI_VERSION (Containerized Data Importer)"
k apply -f "https://github.com/kubevirt/containerized-data-importer/releases/download/${CDI_VERSION}/cdi-operator.yaml"
k apply -f "https://github.com/kubevirt/containerized-data-importer/releases/download/${CDI_VERSION}/cdi-cr.yaml"
log "waiting for CDI to become Available (up to 10m)..."
k -n cdi wait cdi cdi --for=condition=Available --timeout=600s \
  || warn "CDI did not report Available within 10m — DataVolume import may stall; check 'kubectl -n cdi get cdi'"

# ---- verify /dev/kvm is usable ----------------------------------------------
# virt-handler advertises the kvm device-plugin resource on nodes that have a
# usable /dev/kvm. We check node allocatable for devices.kubevirt.io/kvm > 0.
log "checking whether nodes expose a usable /dev/kvm (devices.kubevirt.io/kvm)..."
KVM_COUNT="$(k get nodes -o jsonpath='{range .items[*]}{.status.allocatable.devices\.kubevirt\.io/kvm}{"\n"}{end}' 2>/dev/null \
  | awk '{ if ($1 ~ /^[0-9]+$/ && $1+0 > 0) c++ } END { print c+0 }')"

VM_MODE="kvm"
if [ "${KVM_COUNT:-0}" -gt 0 ]; then
  log "real KVM detected on $KVM_COUNT node(s) — VMs will use hardware virtualization (nested)."
  VM_MODE="kvm"
else
  warn "no node advertises devices.kubevirt.io/kvm — /dev/kvm is NOT exposed to this cluster."
  if [ "$EMULATION_FALLBACK" -eq 1 ]; then
    warn "enabling software emulation (useEmulation=true) — SLOW; results will be labeled vm_mode=emulation."
    k -n kubevirt patch kubevirt kubevirt --type merge -p '{
      "spec":{"configuration":{"developerConfiguration":{"useEmulation":true}}}}' \
      || die "failed to enable useEmulation"
    VM_MODE="emulation"
  else
    die "no usable /dev/kvm and --emulation-fallback not set. Enable nested virt on the host/Talos guest, or re-run with --emulation-fallback to benchmark in (slow) software emulation."
  fi
fi

printf '%s\n' "$VM_MODE" > "$MODE_FILE"
log "KubeVirt + CDI ready. vm_mode=$VM_MODE  (written to $MODE_FILE)"
log "install virtctl for console/migrate convenience: kubectl krew install virt"
