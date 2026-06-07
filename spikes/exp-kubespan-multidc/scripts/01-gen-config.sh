#!/usr/bin/env bash
# 01-gen-config.sh — generate Talos machine config WITH KubeSpan baked in.
#
# Produces controlplane.yaml / worker.yaml / talosconfig under ./_out, applying
# patches/kubespan.yaml to BOTH so every node joins the WireGuard mesh.
#
# Usage:
#   ./scripts/01-gen-config.sh <cluster-name> <controlplane-endpoint>
# e.g.
#   ./scripts/01-gen-config.sh kubespan-multidc https://<BOX_A_PUBLIC_IP>:6443
#
# <controlplane-endpoint> is how the WORKER and your laptop reach the control
# plane's Kubernetes API. Across DCs this is BOX A's PUBLIC IP (or a DNS name).
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
EXP_DIR="$(cd "${SCRIPT_DIR}/.." && pwd)"
OUT="${EXP_DIR}/_out"
PATCH="${EXP_DIR}/patches/kubespan.yaml"

CLUSTER_NAME="${1:?usage: 01-gen-config.sh <cluster-name> <https://CP_ENDPOINT:6443>}"
CP_ENDPOINT="${2:?usage: 01-gen-config.sh <cluster-name> <https://CP_ENDPOINT:6443>}"

command -v talosctl >/dev/null || { echo "talosctl not found on PATH" >&2; exit 1; }
[[ -f "${PATCH}" ]] || { echo "missing ${PATCH}" >&2; exit 1; }

mkdir -p "${OUT}"

# --with-kubespan would enable it too, but we apply our explicit patch so the
# exact filters/mtu/discovery settings are reviewable in patches/kubespan.yaml.
echo "[gen] talosctl gen config ${CLUSTER_NAME} ${CP_ENDPOINT}"
talosctl gen config "${CLUSTER_NAME}" "${CP_ENDPOINT}" \
  --output-dir "${OUT}" \
  --config-patch "@${PATCH}" \
  --force

echo
echo "[gen] wrote:"
ls -1 "${OUT}"
echo
echo "Next:"
echo "  1. Boot a Talos node on BOX A (control plane) and BOX B (worker)."
echo "     See setup.md for the QEMU / bare-metal boot options."
echo "  2. Apply config to each by its reachable address:"
echo "       talosctl apply-config --insecure -n <BOX_A_IP> --file ${OUT}/controlplane.yaml"
echo "       talosctl apply-config --insecure -n <BOX_B_IP> --file ${OUT}/worker.yaml"
echo "  3. Bootstrap etcd ONCE on the control plane:"
echo "       talosctl --talosconfig ${OUT}/talosconfig -e <BOX_A_IP> -n <BOX_A_IP> bootstrap"
echo "  4. Fetch kubeconfig:"
echo "       talosctl --talosconfig ${OUT}/talosconfig -e <BOX_A_IP> -n <BOX_A_IP> kubeconfig ${EXP_DIR}/_out/kubeconfig"
