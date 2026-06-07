#!/usr/bin/env bash
# 02-patch-existing.sh — turn KubeSpan ON for an ALREADY-running Talos cluster.
#
# Use this instead of 01-gen-config.sh when the two boxes already form a cluster
# (e.g. a lab cluster brought up without --with-kubespan) and you just want to
# light up the mesh. Patches every node in the talosconfig endpoints list.
#
# Usage:
#   TALOSCONFIG=~/.talos/config ./scripts/02-patch-existing.sh <NODE_IP> [<NODE_IP> ...]
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
EXP_DIR="$(cd "${SCRIPT_DIR}/.." && pwd)"
PATCH="${EXP_DIR}/patches/kubespan.yaml"

[[ $# -ge 1 ]] || { echo "usage: 02-patch-existing.sh <NODE_IP> [<NODE_IP> ...]" >&2; exit 1; }
command -v talosctl >/dev/null || { echo "talosctl not found on PATH" >&2; exit 1; }

for node in "$@"; do
  echo "[patch] KubeSpan ON -> ${node}"
  talosctl patch machineconfig -n "${node}" --patch "@${PATCH}"
done

echo
echo "[patch] done. Nodes will form WireGuard peers within ~30s. Verify with run.sh."
