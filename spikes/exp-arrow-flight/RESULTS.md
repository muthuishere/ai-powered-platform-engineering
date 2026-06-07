# Results — exp-arrow-flight

- cluster: `cherry-bench`
- ran_at: `2026-06-07T09:59:56Z`
- notes: measured in-cluster over Arrow Flight DoGet against the flight-server Service

## Flight (DoGet) throughput + latency

| metric | value |
|---|---|
| rows in dataset | 5,000,000 |
| scan_rows_per_s (best) | 34,758,070 |
| query_p50_ms | 149.39 |
| query_p95_ms | 160.856 |
| query_min_ms | 143.851 |
| query_mean_ms | 150.041 |
| iters | 20 |

## On-disk size — Feather (Arrow IPC) vs Parquet, both zstd

| store | size |
|---|---|
| in-memory (Arrow) | 160.0 MB (160,000,051 B) |
| Feather / Arrow IPC | 17.7 MB (17,732,986 B) |
| Parquet | 20.5 MB (20,507,074 B) |

Feather/Parquet size ratio: **0.86x** (>1 means Feather is larger on disk).
