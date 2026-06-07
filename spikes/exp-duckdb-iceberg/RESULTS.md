# Results — exp-duckdb-iceberg

DuckDB querying an **Apache Iceberg** table (Parquet + Iceberg metadata) on **MinIO**.
Table created with **pyiceberg** (SQLite catalog); read back with DuckDB's `iceberg`
extension (`iceberg_scan` / `iceberg_snapshots` / `iceberg_metadata`).

- **Kube context:** `admin@cherry-bench`
- **Ran at:** 2026-06-07T09:58:29Z
- **Rows:** 200000 (two appends => two snapshots)
- **Scan rows verified:** 200000

| metric | value | meaning |
|---|---|---|
| ingest_s | 10.4492 | pyiceberg: two appends (create + 2 snapshots) |
| scan_rows_per_s | 17092049 | DuckDB full-scan throughput over Iceberg on S3 |
| query_p50_ms | 5.148 | group-by aggregation, p50 of N hot runs |
| query_p95_ms | 6.750 | same query, p95 |
| time_travel_ms | 5.036 | `iceberg_scan(..., snapshot_from_id=<first>)` — read older snapshot |
| on_disk_bytes | 0 | total bytes of the Iceberg tree on S3 (data + metadata) |
| compression_ratio | null | not measured here (source already columnar) |

**Time-travel note:** Iceberg time-travel is reading an OLDER `snapshot_id` recorded
in the metadata tree on object storage. Unlike DuckLake (history is a SQL table), the
cost includes resolving the manifest list + manifest files for that snapshot from S3.
`time_travel_ms` above is the wall time of a count over the first snapshot.

> Numbers are measured in-cluster on the lab; absolute values are modest. The
> **format-vs-format comparison** (vs exp-duckdb-parquet / exp-ducklake) is the value.
