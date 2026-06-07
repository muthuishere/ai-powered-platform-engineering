# exp-vortex — Vortex vs Parquet on MinIO (measured)

Dataset: **5,000,000 rows**, columns `user_id, city, status, fare, booked_at`, raw Arrow size **227.3 MiB**.

Cluster: `cherry-bench` · ran_at: `2026-06-07T09:59:22.399662+00:00`

| metric | Parquet (zstd) | Vortex |
|---|---|---|
| on-disk size (MinIO) | 28.2 MiB | 22.3 MiB |
| compression ratio (raw/disk) | 8.06x | 10.18x |
| write / ingest (s) | 1.002 | 1.927 |
| scan time (s) | 0.286 | 0.163 |
| scan throughput (rows/s) | 17,461,739 | 30,622,221 |

**On this dataset, Vortex is 20.8% smaller on disk than Parquet(zstd).**

## notes

vortex-data 0.74.0 vs pyarrow parquet(zstd); both round-tripped through MinIO.

_Numbers are measured per the EXPERIMENTS-SPEC contract; unmeasured metrics (query p50/p95) are null — this spike measures size + scan, not point-query latency._
