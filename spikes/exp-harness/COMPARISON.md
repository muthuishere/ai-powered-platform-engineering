# Experiment Comparison — auto-graded

_Generated 2026-06-07T09:39:20Z by `aggregate.py`._

0/8 spikes have measured results. Numbers are measured on real Talos clusters (bare-metal QEMU/KVM); un-run metrics are shown as not-run, never invented.

## Data-format matrix

Parquet vs Iceberg vs DuckLake vs Vortex vs Arrow/Feather over MinIO. Winner per column flagged with **(best)**. `—` = not measured.

| format | on_disk_bytes | compression_ratio | ingest_s | scan_rows_per_s | query_p95_ms |
|---|---|---|---|---|---|
| **Parquet** | _not run_ | _not run_ | _not run_ | _not run_ | _not run_ |
| **Iceberg** | _not run_ | _not run_ | _not run_ | _not run_ | _not run_ |
| **DuckLake** | _not run_ | _not run_ | _not run_ | _not run_ | _not run_ |
| **Vortex** | _not run_ | _not run_ | _not run_ | _not run_ | _not run_ |
| **Arrow/Feather** | _not run_ | _not run_ | _not run_ | _not run_ | _not run_ |

## Postgres: StatefulSet vs KubeVirt

| backend | tps | query_p95_ms | failover_s |
|---|---|---|---|
| **StatefulSet** | _not run_ | _not run_ | _not run_ |
| **KubeVirt** | _not run_ | _not run_ | _not run_ |

**Nesting caveat:** the KubeVirt VM is one nesting layer deep (host KVM -> Talos QEMU VM -> KubeVirt VM). Numbers are directionally valid for container-vs-VM overhead, not absolute bare-metal figures.

## mochallama from MinIO

Model GGUF pulled from object storage (MinIO) at boot — not baked into the image.

| metric | value |
|---|---|
| model_pull_s | _not run_ |
| model_load_s | _not run_ |
| completion_ms | _not run_ |

## Missing / not-yet-run

Spikes whose `results.json` is absent, empty, malformed, or all-null. Per the spec, absent is shown explicitly as **not-run** — never fabricated.

| spike | reason |
|---|---|
| `exp-duckdb-parquet` | results.json absent (spike not yet run) |
| `exp-duckdb-iceberg` | results.json absent (spike not yet run) |
| `exp-ducklake` | results.json absent (spike not yet run) |
| `exp-vortex` | results.json absent (spike not yet run) |
| `exp-arrow-flight` | results.json absent (spike not yet run) |
| `exp-pg-statefulset` | results.json absent (spike not yet run) |
| `exp-pg-ss-vs-kubevirt` | results.json absent (spike not yet run) |
| `exp-mochallama-minio-operator` | results.json absent (spike not yet run) |
