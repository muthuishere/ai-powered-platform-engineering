# Results — exp-chdb-parquet

- **Engine:** chDB 3.6.0 (in-process ClickHouse, `pip install chdb`)
- **Format:** pure Parquet (ZSTD), no Iceberg / no DuckLake
- **Object store:** MinIO (single node, S3-compatible)
- **Cluster (kube context):** `admin@cherry-bench`
- **Generated rows:** 50000000 (scanned: 50000000)
- **Ran at (UTC):** 2026-06-07T10:22:38Z

## Metrics (contract)

| metric | value |
|---|---|
| ingest_s | 28.7331 |
| scan_rows_per_s | 52926855 |
| query_p50_ms | 2141.7 |
| query_p95_ms | 2530.8 |
| on_disk_bytes | 338044922 |
| compression_ratio | 2.080 |

Uncompressed Parquet (logical) bytes: 703170229

## Notes

chDB 3.6.0 (in-process ClickHouse) over pure Parquet (zstd) on MinIO, single-node lab. Same dataset shape as exp-duckdb-parquet for comparability.

Raw query wall times (s) used for p50/p95:

```
2.439410
2.418482
2.530793
2.104903
2.003997
2.140326
2.141691
```

_Full bench log: `.last-bench.log`._
