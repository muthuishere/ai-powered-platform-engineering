# setup.md — bring up a Talos cluster with KubeSpan across **2 boxes**

> **This experiment needs 2 separate hosts.** KubeSpan is a WireGuard full-mesh
> *between nodes that sit on different networks*. A control plane on **Box A** and
> a worker on **Box B** (two Cherry bare-metal boxes, or two QEMU clusters on two
> machines) form the mesh over the **public network**. It does **not** fully
> demonstrate on a single host — there's no second network location for the
> tunnel to span. (You *can* boot 2 QEMU VMs on one box for a smoke test, but the
> "cross-DC" framing — and any latency that isn't ~0 — only appears with 2 boxes.)

Verified against **Talos v1.11** docs (docs.siderolabs.com/talos/v1.11/networking/kubespan, 2026-06).

## What KubeSpan needs (2 ingredients)
1. `machine.network.kubespan.enabled: true` on every node — each node makes a
   WireGuard keypair (its *identity*) and dials every peer.
2. **Cluster discovery** (`cluster.discovery.enabled: true`, **service** registry =
   `discovery.talos.dev`) — how nodes in different DCs *find* each other and learn
   peers' public keys + endpoints. Without it there's no peer list to mesh.

Both live in [`patches/kubespan.yaml`](patches/kubespan.yaml).

## Network prerequisites (between Box A and Box B)
- **UDP/51820** reachable both directions (KubeSpan/WireGuard data plane).
- **TCP/6443** (Kubernetes API) and **TCP/50000** (Talos API) reachable from your
  laptop and from the worker to the control plane's public IP.
- Each box has a routable address the other can reach (public IP, or both on a
  shared VPC/WireGuard underlay). `filters.endpoints: 0.0.0.0/0` lets peers use
  whatever address discovery advertises; narrow it to force a specific path.

---

## Path A — brand-new cluster (recommended)

### 1. Generate config with the KubeSpan patch baked in (on your laptop)
```bash
cd spikes/exp-kubespan-multidc
./scripts/01-gen-config.sh kubespan-multidc https://<BOX_A_PUBLIC_IP>:6443
# writes _out/controlplane.yaml, _out/worker.yaml, _out/talosconfig
```
`<BOX_A_PUBLIC_IP>` is how the **worker** and your laptop reach the control
plane's API — across DCs that's Box A's **public** IP (or a DNS name).

### 2. Boot Talos on each box
Boot the Talos ISO / disk image so each box comes up in **maintenance mode**
(no config yet). Options, pick one per box:

- **Bare metal:** PXE/ISO boot the Talos image (`talosctl gen` matches your
  installed Talos version). Note each box's maintenance-mode IP.
- **QEMU on the box** (nested KVM, matches the rest of these spikes):
  ```bash
  # on Box A and Box B respectively — one Talos VM each, bridged to a routable NIC
  qemu-system-x86_64 -enable-kvm -m 4096 -smp 2 \
    -drive file=talos.qcow2,if=virtio \
    -netdev bridge,id=n0,br=br0 -device virtio-net,netdev=n0 \
    -nographic
  ```
  Bridge the VM to a NIC that the *other box* can route to (public or VPC),
  otherwise the tunnel has no path.

### 3. Apply config (from your laptop, addressing each box)
```bash
# Box A = control plane
talosctl apply-config --insecure -n <BOX_A_IP> --file _out/controlplane.yaml
# Box B = worker
talosctl apply-config --insecure -n <BOX_B_IP> --file _out/worker.yaml
```

### 4. Bootstrap etcd ONCE (control plane only)
```bash
export TALOSCONFIG=$PWD/_out/talosconfig
talosctl config endpoint <BOX_A_IP>
talosctl config node <BOX_A_IP>
talosctl bootstrap
```

### 5. Get kubeconfig + point kubectl at it
```bash
talosctl kubeconfig _out/kubeconfig
export KUBECONFIG=$PWD/_out/kubeconfig
kubectl get nodes -o wide      # expect 2 nodes, Ready, on the 2 boxes
```

### 6. Confirm the mesh formed
```bash
talosctl get kubespanidentities -o yaml     # each node has a WireGuard key
talosctl get kubespanpeerstatuses           # one row per remote node; state: up
```
Within ~30s of both nodes being up, discovery pairs them and the WireGuard
handshake completes. Now run the benchmark: [`./run.sh`](run.sh).

---

## Path B — cluster already up, just light up KubeSpan
If the two boxes already form a cluster (e.g. brought up without `--with-kubespan`):
```bash
export TALOSCONFIG=~/.talos/config
./scripts/02-patch-existing.sh <BOX_A_IP> <BOX_B_IP>
# patches machine.network.kubespan.enabled=true on each; peers form in ~30s
```

---

## Then
```bash
./run.sh             # verify mesh -> deploy split iperf app -> measure -> results
./run.sh --teardown  # remove the app namespace (mesh/cluster stay up)
```
`run.sh` is honest: with <2 nodes or an unreachable mesh it writes the affected
metrics as `null` with a reason — it never fabricates cross-DC numbers.
