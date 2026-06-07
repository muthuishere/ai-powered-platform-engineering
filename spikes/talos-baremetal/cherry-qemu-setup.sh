#!/usr/bin/env bash
# cherry-qemu-setup.sh — stand up a real Talos cluster on a Cherry Servers
# bare-metal box (the runnable form of Appendix A). PROVEN on an E3-1240v5.
#
# Run this ON the rented bare-metal host (Ubuntu), as root. It installs QEMU +
# talosctl + the boot assets, creates a multi-node Talos cluster as KVM VMs on the
# host's real /dev/kvm, and applies the two Talos-specific fixes (writable-path
# local-path storage + PodSecurity) without which PVCs hang forever.
#
# Usage:  TALOS_VERSION=v1.13.3 ./cherry-qemu-setup.sh
# Verify bare metal first: systemd-detect-virt MUST print "none" and /dev/kvm exist.
set -euo pipefail

TALOS_VERSION="${TALOS_VERSION:-v1.13.3}"
CLUSTER="${CLUSTER:-cherry-bench}"
WORKER_CPUS="${WORKER_CPUS:-4}"
WORKER_MEM="${WORKER_MEM:-18432}"   # MB

echo "==> sanity: this must be real bare metal"
virt="$(systemd-detect-virt || true)"
[ "$virt" = "none" ] || { echo "WARN: systemd-detect-virt=$virt (not bare metal). KubeVirt needs real /dev/kvm."; }
ls -l /dev/kvm || { echo "FATAL: no /dev/kvm — this box can't run the Talos VMs with acceleration."; exit 1; }

echo "==> install qemu + tools"
export DEBIAN_FRONTEND=noninteractive
apt-get update -qq
apt-get install -y -qq qemu-system-x86 qemu-utils bridge-utils iptables dmsetup curl xz-utils >/dev/null

echo "==> talosctl ${TALOS_VERSION} + kubectl + CNI plugins"
curl -fsSL "https://github.com/siderolabs/talos/releases/download/${TALOS_VERSION}/talosctl-linux-amd64" -o /usr/local/bin/talosctl
chmod +x /usr/local/bin/talosctl
curl -fsSL "https://dl.k8s.io/release/v1.32.0/bin/linux/amd64/kubectl" -o /usr/local/bin/kubectl
chmod +x /usr/local/bin/kubectl
mkdir -p /opt/cni/bin
curl -fsSL https://github.com/containernetworking/plugins/releases/download/v1.5.1/cni-plugins-linux-amd64-v1.5.1.tgz | tar -xz -C /opt/cni/bin

echo "==> boot assets (WITHOUT these every VM dies: 'could not open kernel file _out/vmlinuz-amd64')"
mkdir -p /root/_out
curl -fsSL "https://github.com/siderolabs/talos/releases/download/${TALOS_VERSION}/vmlinuz-amd64"    -o /root/_out/vmlinuz-amd64
curl -fsSL "https://github.com/siderolabs/talos/releases/download/${TALOS_VERSION}/initramfs-amd64.xz" -o /root/_out/initramfs-amd64.xz

echo "==> create the Talos cluster as QEMU VMs (run from /root so _out/ resolves)"
cd /root
talosctl cluster create --provisioner qemu --name "${CLUSTER}" \
  --controlplanes 1 --cpus 2 --memory 3072 \
  --workers 1 --cpus-workers "${WORKER_CPUS}" --memory-workers "${WORKER_MEM}" \
  --disk 40960 --wait-timeout 18m

export KUBECONFIG=/root/.kube/config
talosctl --talosconfig /root/.talos/config kubeconfig /root/.kube/config

echo "==> fix 1: default StorageClass (local-path on a Talos-WRITABLE /var path)"
curl -fsSL https://raw.githubusercontent.com/rancher/local-path-provisioner/v0.0.30/deploy/local-path-storage.yaml \
  | sed 's#/opt/local-path-provisioner#/var/local-path-provisioner#g' | kubectl apply -f -
kubectl -n local-path-storage rollout status deploy/local-path-provisioner --timeout=120s
kubectl patch storageclass local-path -p '{"metadata":{"annotations":{"storageclass.kubernetes.io/is-default-class":"true"}}}'

echo "==> fix 2: local-path helper pod uses hostPath -> Talos PodSecurity 'baseline' denies it -> label privileged"
kubectl label ns local-path-storage pod-security.kubernetes.io/enforce=privileged --overwrite

echo "==> done. nodes:"; kubectl get nodes -o wide
echo "KubeVirt-capable (after installing KubeVirt): kubectl get nodes -o jsonpath='{.items[*].status.allocatable.devices\\.kubevirt\\.io/kvm}'"
echo
echo "Teardown to STOP billing (delete the server; powering off still bills):"
echo "  curl -sS -X DELETE -H \"Authorization: Bearer \$CHERRY_SERVER_TOKEN\" https://api.cherryservers.com/v1/servers/<SERVER_ID>"
