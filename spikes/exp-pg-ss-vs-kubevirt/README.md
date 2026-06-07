# exp-pg-ss-vs-kubevirt — Postgres as a StatefulSet vs in a KubeVirt VM (measured)

**The headline experiment.** Two ways to run the *same* Postgres on Kubernetes,
benchmarked the *same* way, so the only variable is the **runtime model**:

- **Arm A — StatefulSet**: Postgres run by the [CloudNativePG](https://cloudnative-pg.io/)
  operator (3 instances: 1 primary + 2 replicas, operator-managed failover).
- **Arm B — KubeVirt VM**: the *same* Postgres version + config inside a
  [KubeVirt](https://kubevirt.io/) `VirtualMachine`, fronted by a Service.

Both arms live in one namespace, **`exp-pg-kubevirt`**, on a cluster with **real
nested `/dev/kvm`**. We hammer both with **pgbench** (identical params → TPS +
p50/p95/p99), then kill the primary and time **time-to-writable**. Output:
`results/results.json` (machine-readable, both arms) + `RESULTS.md` (the table).

This runs on a **bare-metal Talos** cluster where the host exposes nested KVM to
the Talos QEMU guest, so KubeVirt's `virt-handler` finds a usable `/dev/kvm` and
runs VMs with **hardware** virtualization. (Unlike the OrbStack lab in
`spikes/talos-stateful/`, where Arm B can only be illustrative.)

## The learning (what this experiment is *for*)

- **Container vs VM overhead.** Arm A is a process in a container sharing the host
  kernel. Arm B is a full guest OS (kernel, init, systemd, an `apt`-installed
  Postgres) running under QEMU/KVM. Expect the VM to cost TPS and add latency,
  especially tail (p95/p99) — the table makes the size of that tax concrete on
  *this* hardware. Small boxes give modest absolute numbers; the **comparison**
  is the value, not the absolutes.

- **The honest nesting caveat.** The KubeVirt VM here is **one nesting layer**
  deep: **host KVM → Talos QEMU VM → KubeVirt VM**. That extra layer makes the
  VM arm look *worse* than a bare KubeVirt-on-metal install would. It's
  directionally valid for container-vs-VM overhead and we **label it**:
  `results.json` carries `vm_mode` (`kvm` | `emulation`) and `nested`. If
  `/dev/kvm` isn't exposed and you opt into the fallback, the VM runs in
  **software emulation** — far slower, and clearly marked so nobody mistakes an
  emulated floor for a hardware-virt result.

- **HA is a different thing in each arm — don't rank them head-to-head.**
  - **Arm A (CNPG)** does **application-level failover**: the operator detects a
    dead primary, **promotes** an already-replicated standby, and re-points the
    `pg-ss-rw` Service. Seconds; two surviving data copies.
  - **Arm B (KubeVirt)** has **one** Postgres. Killing the VM's launcher pod
    forces a **reschedule** (only possible if the disk is on **RWX** storage),
    then Postgres **crash-recovers** on boot. Minutes; one data copy. This is
    *not* a promotion. To get CNPG-style HA inside VMs you'd run several Postgres
    VMs with streaming replication + a failover controller — i.e. reimplement
    CloudNativePG. **That tradeoff is the punchline.**

So Arm B's failover number is **VM-reschedule + crash-recovery**, labeled as
such in `results.json` and `RESULTS.md`. The two failover rows are shown side by
side to make the difference concrete, never to be averaged or ranked.

## Held constant (so the only variable is the runtime model)

| Held constant | Where |
|---|---|
| Postgres version (`17.2`) | Arm A `imageName`; Arm B cloud-init installs PGDG 17 |
| CPU / RAM (`1 vCPU` / `1Gi`) | Arm A `resources` (requests==limits); Arm B `domain.cpu`/`memory` |
| `postgresql.conf` knobs | identical block in both arms (shared_buffers, fsync, synchronous_commit, wal_level, …) |
| Storage class | `${STORAGE_CLASS}` injected into BOTH PVCs by `run.sh` |
| pgbench scale/clients/jobs/duration | same flags to both runs (`run.sh` defaults) |

Change one of these in only one arm and you measure *that*, not the runtime
model. The values actually used are recorded in `results.json.held_constant`.

## Prerequisites

- A bare-metal Talos cluster (1 control-plane + 1 worker) with **nested virt**
  enabled on the host BIOS and passed to the Talos QEMU guest.
- `kubectl` (current context is **not** used; everything takes `--context`).
- `envsubst` (from `gettext`) — `run.sh` renders the storage-class / access-mode
  tokens into the manifests.
- For HA (Arm B reschedule), a CSI that supports **RWX**. With RWO the VM is
  pinned to one node — `run.sh` records the access mode either way.

pgbench, psql, and the failover write-probe all run **in-cluster** (throwaway
`postgres:17` Jobs/pods), so you need **no** local Postgres client.

## How to run

```bash
CTX=admin@dev        # the workload cluster — NEVER your current context

# 1. Install KubeVirt + CDI and verify /dev/kvm (prefer real KVM).
#    Add --emulation-fallback ONLY if you accept slow software emulation.
k8s/install-kubevirt.sh --context "$CTX"            # writes k8s/.vm-mode

# 2. Deploy both arms, benchmark both, time failover both, write results.
k8s/install-kubevirt.sh --context "$CTX"            # if not already run
./run.sh --context "$CTX" --storage-class <rwx-class>

#   common overrides (held constant ACROSS arms — same for both):
#   ./run.sh --context "$CTX" --storage-class ceph-block \
#            --scale 10 --clients 16 --jobs 4 --duration 60 \
#            --access-mode ReadWriteMany

# 3. Read the results.
cat RESULTS.md
jq . results/results.json

# Tear down (keeps the KubeVirt/CDI/CNPG operators; drops the experiment).
./run.sh --context "$CTX" --teardown
```

`run.sh` is **idempotent** — re-running re-applies (server-side) and re-benches.
If Arm B can't come up (no `/dev/kvm`, no RWX, KubeVirt not installed), its
metrics stay **null** with a reason; we never fabricate a row.

## Files

```
exp-pg-ss-vs-kubevirt/
├── README.md                          ← you are here
├── run.sh                             ← deploy both → pgbench both → failover both → results.json + RESULTS.md ; --teardown
├── RESULTS.md                         ← generated by run.sh (the comparison table)
├── results/
│   ├── results.json                   ← generated: ss:{tps,p95,…}, vm:{…}, vm_mode, nested
│   └── bench-{ss,vm}.txt              ← generated: raw pgbench output + percentile post-process
└── k8s/
    ├── install-kubevirt.sh            ← KubeVirt v1.5.0 + CDI v1.62.0; verify /dev/kvm; useEmulation fallback
    ├── 00-namespace.yaml              ← exp-pg-kubevirt (privileged PSA for virt-launcher)
    ├── arm-a-statefulset/
    │   └── 10-cluster.yaml            ← CNPG Cluster (pinned PG/CPU/RAM/config/storageClass)
    └── arm-b-kubevirt/
        ├── 10-postgres-config.yaml    ← same PG config as Arm A (for diffing; VM applies it via cloud-init)
        └── 20-virtualmachine.yaml     ← VM running same Postgres + NodePort Service
```

## Metrics contract

`results/results.json` carries both arms plus the run's nesting state:

```json
{ "spike":"exp-pg-ss-vs-kubevirt", "vm_mode":"kvm", "nested":true,
  "ss":{ "tps":null, "p50_ms":null, "p95_ms":null, "p99_ms":null, "failover_s":null },
  "vm":{ "tps":null, "p50_ms":null, "p95_ms":null, "p99_ms":null, "failover_s":null },
  "held_constant":{ … }, "ran_at":"<stamped after run>" }
```

All metric fields are **`null` until measured** on a real run — no fabricated
numbers. `vm_mode`/`nested` record exactly how honest the VM arm's numbers are.

## References

- KubeVirt on Talos — [Sidero docs](https://docs.siderolabs.com/talos/v1.8/advanced-guides/install-kubevirt)
- KubeVirt v1.5 release — [kubevirt.io](https://kubevirt.io/2025/KubeVirt-v1-5_release.html)
- CDI releases — [github.com/kubevirt/containerized-data-importer](https://github.com/kubevirt/containerized-data-importer/releases)
- CloudNativePG releases — [github.com/cloudnative-pg/cloudnative-pg](https://github.com/cloudnative-pg/cloudnative-pg/releases)
```
