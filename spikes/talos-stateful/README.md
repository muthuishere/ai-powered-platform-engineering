# Postgres: StatefulSet vs KubeVirt — an honest benchmark

Chapter 8 lab. Two ways to run a stateful database on Kubernetes, measured the
same way, so the comparison is about the **runtime model** (containerised
StatefulSet vs a VM on the cluster) and not about some accidental difference in
hardware or config.

- **Arm A — StatefulSet**: Postgres run by the [CloudNativePG](https://cloudnative-pg.io/)
  operator. 3 instances (1 primary + 2 replicas), operator-managed failover.
- **Arm B — KubeVirt VM**: the *same* Postgres version inside a
  [KubeVirt](https://kubevirt.io/) `VirtualMachine`, on a PVC-backed disk.

Both arms get hammered with **pgbench**; we record TPS and latency
**percentiles**, then kill the primary and time **time-to-writable**.

---

## What this measures (and what it does NOT)

This measures the *overhead and failover behaviour of the runtime model*. To
make that the only variable, everything else is **held constant**:

| Held constant | Why |
|---|---|
| **Storage class** | Different storage = you're benchmarking disks, not SS-vs-VM. Pin the same `storageClassName` in both arms. |
| **CPU / RAM** | The VM gets the same vCPU + memory as the CNPG pod's requests/limits. |
| **Postgres version** | Same `postgres:17.x` image / package. A minor version bump moves TPS more than the runtime model does. |
| **Postgres config** | `shared_buffers`, `max_connections`, `wal_level`, `fsync`, `synchronous_commit` — identical in both arms. See each arm's config block. |
| **pgbench parameters** | Same `--scale`, `--client`, `--jobs`, `--time`, same warm-up. |

If you change any of these between arms, you are no longer measuring the runtime
model. **Record the values you used in `RESULTS-TEMPLATE.md`.**

### Report percentiles, not averages

An average TPS/latency hides the tail that actually hurts users. We report
**p50 / p95 / p99 latency** and **TPS**. pgbench gives you the average and (with
`--progress`) a feel for variance; for true percentiles we run with
`--report-per-command` plus per-transaction latency logging and post-process the
log (`bench/run-bench.sh` does this). Never report a single mean and call it a
benchmark.

### Failover is not one thing

- **CloudNativePG** does **application-level failover**: the operator detects a
  dead primary, promotes a replica, and re-points the `-rw` Service. The app's
  write endpoint becomes writable again automatically. We time that.
- **KubeVirt** HA is **storage-layer + live migration**, *not* automatic app
  failover:
  - The VM's disk must live on a CSI that supports **RWX** (ReadWriteMany) block/
    filesystem so the disk can move with the VM. With RWO you can't live-migrate.
  - **Live migration** moves a *running* VM to another node (e.g. for a drain).
    It does **not** restart Postgres or promote a replica — there is only one
    Postgres here.
  - If the *node* dies, KubeVirt can reschedule the VM elsewhere **only if the
    disk is on RWX storage**, and Postgres then does crash recovery on boot.
    That is minutes, not seconds, and there is no second copy of the data.
  - To get CNPG-style HA inside VMs you'd run **multiple** Postgres VMs with
    streaming replication + a failover controller — i.e. you'd rebuild what
    CloudNativePG already gives you. That's the honest punchline of this chapter.

So Arm B's "failover" number is really **VM-reschedule + Postgres crash-recovery
time**, and we label it as such. It is not comparable to Arm A's promotion time;
it is shown to make the difference concrete.

---

## What runs where (lab limits — be honest)

| Arm | OrbStack lab (`admin@dev`) | Needs |
|---|---|---|
| **A — CloudNativePG StatefulSet** | ✅ runs | a storage class with a working provisioner (the lab's `local-path` / OrbStack default is fine for a single-node-per-cluster spike) |
| **B — KubeVirt VM** | ⚠️ probably **not** | KubeVirt needs **nested virtualization** (KVM) and a **RWX CSI**. Talos-in-Docker under OrbStack does not expose `/dev/kvm` to the nodes, and the lab has no RWX CSI. KubeVirt *can* fall back to software emulation (`useEmulation`), but it's slow and still needs the CRDs + CDI installed. |

**Therefore:**

- **Arm A is runnable in the lab today.** `01-cloudnativepg/` + `bench/` will
  produce real numbers against `admin@dev`.
- **Arm B is provided as correct, illustrative manifests** with a clearly marked
  *"run on a cluster that has KubeVirt + CDI + an RWX CSI installed"* note. Do
  not expect it to come up on the OrbStack lab. When you have a KubeVirt-capable
  cluster (bare-metal Talos with KVM, or a cloud cluster with KubeVirt), the same
  `bench/` scripts target it.

We do **not** fabricate the Arm B numbers to fill the table. If you can't run it,
the Arm B row stays blank with a note saying why. An honest blank beats a made-up
benchmark.

---

## Prerequisites

```bash
# CloudNativePG kubectl plugin (Arm A convenience + benchmarks)
kubectl krew install cnpg          # or see 01-cloudnativepg/README.md
# pgbench + psql client (run from your laptop; the scripts also offer an in-cluster fallback)
brew install libpq && brew link --force libpq   # gives psql + pgbench on macOS
```

---

## How to run

```bash
CTX=admin@dev          # the workload cluster, NOT ops, NEVER your current context

# --- Arm A: StatefulSet (runs in the lab) -------------------------------------
kubectl --context "$CTX" apply -f 01-cloudnativepg/00-operator.yaml      # CNPG operator
kubectl --context "$CTX" apply -f 01-cloudnativepg/10-cluster.yaml       # 3-instance Cluster
kubectl --context "$CTX" -n pgbench-ss wait --for=condition=Ready cluster/pg --timeout=300s

# --- Arm B: KubeVirt VM (needs a KubeVirt cluster; skip in OrbStack) -----------
# Only on a cluster with KubeVirt + CDI + RWX CSI:
kubectl --context "$CTX" apply -f 02-kubevirt-postgres/

# --- Benchmark ----------------------------------------------------------------
bench/run-bench.sh --context "$CTX" --arm ss        # StatefulSet arm
bench/run-bench.sh --context "$CTX" --arm vm        # KubeVirt arm (if available)

# --- Failover ----------------------------------------------------------------
bench/failover-test.sh --context "$CTX" --arm ss
bench/failover-test.sh --context "$CTX" --arm vm    # = reschedule+recovery, see above

# Results land in bench/results/. Copy them into RESULTS-TEMPLATE.md.
```

---

## Files

```
talos-stateful/
├── README.md                         ← you are here
├── RESULTS-TEMPLATE.md               ← fill this in; do NOT pre-populate numbers
├── 01-cloudnativepg/
│   ├── README.md                     ← operator install, cnpg plugin notes
│   ├── 00-operator.yaml              ← CloudNativePG operator
│   └── 10-cluster.yaml              ← 3-instance Cluster, pinned storageClass/CPU/RAM/version
├── 02-kubevirt-postgres/
│   ├── README.md                     ← KubeVirt/CDI/RWX prereqs, "illustrative" warning
│   ├── 00-namespace.yaml
│   ├── 10-postgres-config.yaml       ← same PG config as Arm A (cloud-init)
│   └── 20-virtualmachine.yaml        ← the VM running Postgres + a NodePort Service
├── bench/
│   ├── run-bench.sh                  ← pgbench → TPS + p50/p95/p99 → results file
│   ├── failover-test.sh              ← kill primary, time time-to-writable
│   └── results/                      ← .gitkeep; benchmark output lands here
└── metrics/
    └── README.md                     ← Prometheus + postgres_exporter pointers
```
