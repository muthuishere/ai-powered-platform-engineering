# Results — Postgres StatefulSet vs KubeVirt

> Fill this in from your own runs. **Do not pre-populate numbers.** A blank Arm B
> row with a "couldn't run — no KubeVirt" note is honest; a fabricated row is not.

## Run conditions (record these — they make or break comparability)

| Knob | Value used | Same for both arms? |
|---|---|---|
| Cluster / context | `admin@dev` (OrbStack lab) / `_____` | — |
| **Storage backend / class** | `__________` (e.g. local-path, Ceph RBD, EBS gp3) | MUST be ✅ |
| Postgres version | `17._` | MUST be ✅ |
| CPU per instance | `1 vCPU` | MUST be ✅ |
| RAM per instance | `1Gi` | MUST be ✅ |
| `shared_buffers` / `synchronous_commit` / `fsync` | `256MB` / `on` / `on` | MUST be ✅ |
| pgbench `--scale` | `10` | MUST be ✅ |
| pgbench `--clients` / `--jobs` | `16` / `4` | MUST be ✅ |
| pgbench `--duration` | `60s` | MUST be ✅ |
| pgbench location | ss=in-Job(cnpg)/port-forward · vm=port-forward | note it |

If any "MUST be ✅" row differs between arms, you measured that difference — not
the runtime model. Re-run before reporting.

## Throughput + latency (percentiles, not averages)

| Arm | Storage backend | TPS | p50 (ms) | p95 (ms) | p99 (ms) |
|---|---|---|---|---|---|
| **A — StatefulSet (CloudNativePG)** | `________` | `___` | `___` | `___` | `___` |
| **B — KubeVirt VM** | `________` | `___` | `___` | `___` | `___` |

> p50/p95/p99 come from the post-processed `pgbench -l` log (see the bottom of
> each `bench/results/bench-*.txt`). The single average pgbench prints is **not**
> what goes here.

## Failover / availability

| Arm | Event measured | Time-to-writable | Data copies surviving |
|---|---|---|---|
| **A — StatefulSet (CloudNativePG)** | replica **promotion** (operator-driven) | `___ s` | 2 (replicas) |
| **B — KubeVirt VM** | VM **reschedule + crash-recovery** (needs RWX) | `___ s` | 1 (single VM) |

> These two rows are **not the same event** and must not be averaged or ranked
> head-to-head as "failover". Arm A promotes an already-replicated standby; Arm B
> reboots the one and only Postgres after the VM moves nodes (and only if the disk
> is on RWX storage). See README "Failover is not one thing".

## What actually ran

- [ ] Arm A (StatefulSet) ran on: `__________`
- [ ] Arm B (KubeVirt) ran on: `__________`  /  ☐ **did not run — reason:** `__________`
      (e.g. "OrbStack lab has no /dev/kvm and no RWX CSI; manifests provided as
      illustrative only.")

## Notes / observations

- Checkpoint stalls seen in metrics? `__________`
- Replication lag during the bench (Arm A)? `__________`
- Any p99 spikes correlated with WAL / checkpoint activity? `__________`
