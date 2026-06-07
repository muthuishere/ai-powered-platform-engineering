# exp-pg-statefulset — Postgres on Kubernetes as a StatefulSet (the baseline)

The headline question of the stateful arc is: *should production Postgres run as
containers on Kubernetes, or inside a VM (KubeVirt) on Kubernetes?* You can't
answer that without a credible **container baseline**. This spike is that
baseline.

It runs Postgres the way most teams should run it on k8s today —
[**CloudNativePG**](https://cloudnative-pg.io/) (CNPG), an operator that manages
Postgres as a set of pods (the StatefulSet pattern) with streaming replication,
**operator-driven automatic failover**, a read-write / read-only Service split,
and first-class backup. Then it measures the things the book cares about:
throughput, tail latency, and how long a failover actually takes.

## The learning

**CNPG makes Postgres-on-Kubernetes production-credible.** The hard parts of
running a database — leader election, promoting a replica when the primary dies,
re-pointing clients at the new primary, base backups, PITR — are not bolt-ons
here; they're the operator's job. You declare `instances: 3` and a storage class,
and you get an HA Postgres whose failover is a control-loop, not a runbook.

What this spike proves with numbers:

1. **Throughput + tail latency** of containerized Postgres under pgbench — the
   p50/p95/p99 a container-native primary delivers on this hardware.
2. **Failover time** — delete the primary pod and measure wall-clock until a
   *writable* primary is back through the `pg-rw` Service. No human, no script:
   the operator promotes a replica.

These numbers are the **StatefulSet baseline** that the KubeVirt arm
(`exp-pg-ss-vs-kubevirt`) compares against — same PG version, same CPU/RAM, same
`postgresql.conf`, same storage class, so the only variable is container-vs-VM.

## What's in here

```
k8s/
  00-namespace.yaml    exp-pg-ss namespace
  10-operator.yaml     PINNED CNPG operator pointer (v1.29.1) — run.sh applies the
                       real upstream release manifest server-side
  20-cluster.yaml      3-instance Cluster: PG 17.5, 1 vCPU / 2Gi, fixed storageClass,
                       pinned postgresql.conf knobs, unsupervised failover
  30-podmonitor.yaml   PodMonitor for CNPG's :9187 metrics (applied only if the
                       Prometheus Operator CRDs exist) + a metrics note
run.sh                 deploy → wait healthy → pgbench → failover → results.json + RESULTS.md
```

Everything that **must match the KubeVirt arm** is pinned in `20-cluster.yaml`
(PG version, CPU, RAM, storageClass, postgresql parameters). Change it in *both*
arms or the comparison is meaningless.

## Run it

```bash
./run.sh              # full experiment on the CURRENT kube context
./run.sh --teardown   # remove cluster + operator + namespaces
```

The script uses your current context (it does **not** switch contexts) and is
idempotent — re-running re-applies manifests and re-runs the benchmark Job.

Tunables via env: `PGB_SCALE`, `PGB_CLIENTS`, `PGB_JOBS`, `PGB_TIME`.

### How the metrics are measured (no fabrication)

- **TPS** — parsed from pgbench's own `tps = …` summary line.
- **p50 / p95 / p99 latency** — pgbench is run with `-l`, which logs *one line per
  transaction* with its latency in microseconds. `run.sh` collects every line and
  computes nearest-rank percentiles (µs → ms). These are real per-transaction
  measurements, not pgbench's summary-only average.
- **failover_s** — a helper pod writes a row through the `pg-rw` Service every
  0.25s. We force-delete the primary pod, then time the wall-clock from the delete
  to the *first successful INSERT after the kill*. That captures the full path:
  pod deletion → CNPG promotion → Service endpoint reprogramming.

Any metric that can't be measured on a given run is written as `null` with a
reason — never a made-up number.

### The `cnpg` kubectl plugin (day-2 convenience)

CNPG ships a kubectl plugin (`kubectl krew install cnpg`) that turns day-2 ops
into one-liners:

```bash
kubectl cnpg status pg -n exp-pg-ss      # topology + health
kubectl cnpg psql pg -n exp-pg-ss        # psql into the primary
kubectl cnpg pgbench pg -n exp-pg-ss     # pgbench as a Job (summary metrics only)
kubectl cnpg promote pg <replica> -n exp-pg-ss
```

`run.sh` does **not** depend on the plugin: `kubectl cnpg pgbench` doesn't emit
the per-transaction `-l` log we need for percentiles, so the script runs its own
pgbench Job over the `pg-rw` Service using the same pinned Postgres image. The
plugin is the convenient interactive path; the Job is the reproducible measured
path.

## Metrics emitted (`results.json`)

```json
{
  "spike": "exp-pg-statefulset",
  "cluster": "<current-context>",
  "metrics": { "tps": 0, "query_p50_ms": 0, "query_p95_ms": 0, "query_p99_ms": 0, "failover_s": 0 },
  "config": { "...": "pinned knobs, mirrored by the KubeVirt arm" },
  "notes": "...",
  "ran_at": "<stamped after run>"
}
```

Plus a human-readable `RESULTS.md` and the raw `pgbench.out`.
