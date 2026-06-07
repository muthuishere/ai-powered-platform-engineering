# Results — exp-duckdb-parquet

- **Engine:** DuckDB 1.5.3 (official distroless CLI image)
- **Format:** pure Parquet (ZSTD), no DuckLake / no Iceberg
- **Object store:** MinIO (single node, S3-compatible)
- **Cluster (kube context):** `admin@cherry-bench`
- **Generated rows:** 32
- **Ran at (UTC):** 2026-06-07T09:54:50Z

## Metrics (contract)

| metric | value |
|---|---|
| ingest_s | 15.940 |
| scan_rows_per_s | 8000 |
| query_p50_ms | 189.0 |
| query_p95_ms | 237.0 |
| on_disk_bytes | 92966955 |
| compression_ratio | 7.598 |

Uncompressed Parquet (logical) bytes: 706408082

## Notes

DuckDB 1.5.3 over pure Parquet (zstd) on MinIO, single-node lab.

Raw query Run Times (s) used for p50/p95:

```
0.237
0.190
0.179
0.185
0.200
0.185
0.189
```

_Full bench log: `.last-bench.log`._
