# Experiments Spec — one cluster per spike, real Talos on bare metal

**Goal:** maximize *learnings with real metrics* for the book. Each spike is a
**self-contained experiment** that deploys onto its **own independent Talos
cluster** (real `/dev/kvm`, QEMU VMs on Cherry bare metal), runs a benchmark,
and emits **metrics** to `results.json` + `RESULTS.md`. No cross-spike sharing —
each carries its own MinIO/Postgres so runs don't contend.

## Cluster topology (per spike)
- QEMU Talos cluster: **1 control-plane + 1 worker** (nested KVM on for the
  KubeVirt spike). Each on its own Cherry box (or packed 2/box when economizing).
- Shared per-cluster infra the spike's `run.sh` installs: **MinIO** (object store),
  **Prometheus** (metrics), and the spike's engine (DuckDB job / CNPG / KubeVirt).
- Cost guardrail: Cherry boxes ~$0.10–0.15/hr; tear down each box after its run.

## The spikes (each = its own cluster + dir under `spikes/`)
| # | dir | what it measures | engine + backend |
|---|-----|------------------|------------------|
| 1 | `exp-pg-statefulset` | Postgres on k8s baseline — TPS, p50/p95/p99 | CloudNativePG StatefulSet |
| 2 | `exp-pg-ss-vs-kubevirt` | **headline:** container vs VM Postgres overhead + failover | CNPG vs KubeVirt VM (real KVM) |
| 3 | `exp-duckdb-parquet` | scan throughput, query latency, file size | DuckDB over Parquet on MinIO |
| 4 | `exp-duckdb-iceberg` | same + snapshot/time-travel cost | DuckDB + Apache Iceberg on MinIO |
| 5 | `exp-ducklake` | metadata-in-SQL vs file-metadata; ingest + query | DuckLake (PG catalog) + Parquet on MinIO |
| 6 | `exp-vortex` | compression ratio + scan speed vs Parquet | Vortex format on MinIO |
| 7 | `exp-arrow-flight` | in-memory/Flight throughput, zero-copy interchange | Apache Arrow + Arrow Flight |
| 8 | `exp-mochallama-minio-operator` | model boots from object storage (not baked) | mochallama operator pulling GGUF from MinIO |

Plus `exp-harness/` — an **auto-grade** aggregator: collects every spike's
`results.json` into one comparison matrix + a Markdown report for the book
(format-vs-format table: size, ingest, scan, query p95, time-travel).

## Metrics contract (every spike writes this)
`results.json`:
```json
{ "spike":"exp-duckdb-parquet", "cluster":"cherry-bench",
  "metrics": { "ingest_s": 0.0, "scan_rows_per_s": 0, "query_p50_ms": 0,
               "query_p95_ms": 0, "on_disk_bytes": 0, "compression_ratio": 0.0 },
  "notes":"", "ran_at":"<stamped after run>" }
```
Numbers are **measured, never fabricated**; un-run metrics stay `null` with a reason.

## Honest caveats (carried into the book)
- KubeVirt VMs are **one nesting layer** deep (host KVM → Talos QEMU VM → KubeVirt
  VM) — directionally valid for container-vs-VM overhead; labeled as nested.
- Small bare-metal boxes → modest absolute numbers; the **comparisons** are the value.
- MinIO is used per request (note: community edition archived Feb 2026; Garage is the
  live alternative — both are S3-compatible, swappable).

## Agent team
One authoring agent per spike (parallel, disjoint dirs) writes the self-contained
spike + `run.sh` + metrics, verifying format specifics against current docs. Then
clusters are provisioned and each spike is run on its own cluster; the harness
aggregates the metrics into the book.
