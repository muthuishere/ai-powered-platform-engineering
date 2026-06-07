#!/usr/bin/env python3
"""chDB-over-Parquet benchmark — the in-cluster query runner for exp-chdb-parquet.

chDB is ClickHouse compiled as an in-process engine (``pip install chdb``). Like the
sibling DuckDB spike it is a STATELESS query runner: this script spins up, writes a
synthetic Parquet file to MinIO via ``INSERT INTO FUNCTION s3(...)``, scans it,
times a few aggregations, reports the on-disk size, and exits. All durable state
stays on MinIO as a plain Parquet file — kill the pod, the data survives.

Dataset shape is IDENTICAL to exp-duckdb-parquet so the numbers are comparable:
    id     : row number
    city   : one of 5 (chennai, bengaluru, mumbai, delhi, pune)
    amount : (id * 2654435761 % 100000) / 100.0
    ts     : 2026-06-01 00:00:00 + (id % 86400) seconds

Output is a sequence of ``@@METRIC key=value@@`` lines that run.sh scrapes into the
results.json contract. Every number printed is MEASURED here (timed with
time.perf_counter / read back from ClickHouse system metrics), never fabricated.

Env (injected by the Job): S3_ENDPOINT, S3_BUCKET, S3_KEY_ID, S3_SECRET, ROW_COUNT.
"""
import json
import os
import sys
import time

import chdb

ENDPOINT = os.environ["S3_ENDPOINT"]          # e.g. minio:9000  (path-style, http)
BUCKET = os.environ["S3_BUCKET"]              # e.g. bench
KEY_ID = os.environ["S3_KEY_ID"]
SECRET = os.environ["S3_SECRET"]
ROW_COUNT = int(os.environ.get("ROW_COUNT", "50000000"))

# Path-style MinIO URL. ClickHouse's s3() function accepts a plain http URL with the
# bucket in the path; MinIO speaks that natively.
URL = "http://{ep}/{bucket}/data.parquet".format(ep=ENDPOINT, bucket=BUCKET)


def emit(key, value):
    """One machine-parseable metric line."""
    print("@@METRIC {k}={v}@@".format(k=key, v=value), flush=True)


def q(sql):
    """Run a SQL statement, return the chDB result object."""
    return chdb.query(sql, "JSONCompact")


# The synthetic generator, reused by ingest. ClickHouse `numbers(N)` is the analogue
# of DuckDB's range(N). modulo math matches the DuckDB spike exactly.
GEN = """
SELECT
    number AS id,
    ['chennai','bengaluru','mumbai','delhi','pune'][(number % 5) + 1] AS city,
    toFloat64((number * 2654435761) % 100000) / 100.0                 AS amount,
    toDateTime('2026-06-01 00:00:00') + toIntervalSecond(number % 86400) AS ts
FROM numbers({rows})
""".format(rows=ROW_COUNT)


def main():
    print("chDB version: {}".format(chdb.__version__), flush=True)
    emit("chdb_version", chdb.__version__)
    emit("row_count", ROW_COUNT)

    # ClickHouse needs S3 creds passed positionally in the s3() function. We build a
    # reusable s3(...) source expression for reads and a destination for the write.
    s3_src = "s3('{url}', '{k}', '{s}', 'Parquet')".format(url=URL, k=KEY_ID, s=SECRET)
    # For the write we also specify the structure so ClickHouse picks Parquet+codec.
    s3_dst = "s3('{url}', '{k}', '{s}', 'Parquet')".format(url=URL, k=KEY_ID, s=SECRET)

    # --- INGEST: generate + write Parquet (zstd) to MinIO ---------------------
    # output_format_parquet_compression_method=zstd matches the DuckDB COPY
    # COMPRESSION zstd; row group size aligned to 1,000,000 like the sibling spike.
    print("\n=== ingest: writing {} rows of Parquet to {} ===".format(ROW_COUNT, URL),
          flush=True)
    t0 = time.perf_counter()
    q("""
        INSERT INTO FUNCTION {dst}
        SETTINGS
            output_format_parquet_compression_method = 'zstd',
            output_format_parquet_row_group_size = 1000000,
            s3_truncate_on_insert = 1
        {gen}
    """.format(dst=s3_dst, gen=GEN))
    ingest_s = time.perf_counter() - t0
    emit("ingest_s", "{:.4f}".format(ingest_s))
    print("ingest done in {:.4f}s".format(ingest_s), flush=True)

    # --- ON-DISK SIZE + COMPRESSION RATIO -------------------------------------
    # Compressed bytes: the actual object size on MinIO (Parquet file on disk).
    # Uncompressed (logical) bytes: sum of total_uncompressed_size across row groups,
    # read from ClickHouse's ParquetMetadata format — the same logical size DuckDB's
    # parquet_metadata() reports, so compression_ratio is apples-to-apples.
    size_res = q("SELECT sum(_size) FROM {src}".format(
        src="s3('{url}', '{k}', '{s}', 'One')".format(url=URL, k=KEY_ID, s=SECRET)))
    try:
        compressed_bytes = int(json.loads(str(size_res))["data"][0][0])
    except Exception:
        # Fallback: query the object size via the virtual _file/_size column on a read.
        size_res = q("SELECT any(_size) FROM {src} LIMIT 1".format(src=s3_src))
        compressed_bytes = int(json.loads(str(size_res))["data"][0][0])
    emit("compressed_bytes", compressed_bytes)

    # ParquetMetadata yields ONE row per file with file-level totals. Read the
    # top-level total_uncompressed_size directly (logical Parquet size) — NOT a sum
    # over the row_groups array, which over-counts. This is the same logical figure
    # DuckDB's parquet_metadata() reports, so compression_ratio is apples-to-apples.
    meta = q("""
        SELECT toUInt64(total_uncompressed_size) AS unc,
               toUInt64(total_compressed_size)   AS cmp
        FROM s3('{url}', '{k}', '{s}', 'ParquetMetadata')
    """.format(url=URL, k=KEY_ID, s=SECRET))
    try:
        mrow = json.loads(str(meta))["data"][0]
        uncompressed_bytes = int(mrow[0])
    except Exception:
        uncompressed_bytes = None
    if uncompressed_bytes:
        emit("uncompressed_bytes", uncompressed_bytes)

    # --- SCAN: full column scan over the Parquet file -------------------------
    # NOTE: count(*) is answered from the Parquet footer (metadata only) and never
    # reads column data, so it is NOT a throughput signal. We instead sum the `id`
    # column, which forces decoding every value of a column across all 50M rows —
    # a real scan, comparable to a columnar read.
    print("\n=== scan: sum(id) full column scan over the Parquet file ===", flush=True)
    t0 = time.perf_counter()
    scan_res = q("SELECT sum(id) AS s, count(*) AS n FROM {src}".format(src=s3_src))
    scan_s = time.perf_counter() - t0
    rows_scanned = int(json.loads(str(scan_res))["data"][0][1])
    emit("scan_s", "{:.4f}".format(scan_s))
    emit("rows_scanned", rows_scanned)
    print("scanned {} rows in {:.4f}s".format(rows_scanned, scan_s), flush=True)

    # --- QUERY: repeated group-by aggregation (p50/p95 over wall times) --------
    # Same query as the DuckDB spike: per-city count / avg / max.
    query_sql = """
        SELECT city, count(*) AS n, avg(amount) AS avg_amount, max(amount) AS max_amount
        FROM {src}
        GROUP BY city ORDER BY n DESC
    """.format(src=s3_src)
    print("\n=== query: 7x group-by for p50/p95 ===", flush=True)
    for i in range(7):
        t0 = time.perf_counter()
        q(query_sql)
        dt = time.perf_counter() - t0
        emit("query_s", "{:.6f}".format(dt))
        print("  query rep {} : {:.6f}s".format(i + 1, dt), flush=True)

    emit("done", 1)
    print("\nbench complete.", flush=True)


if __name__ == "__main__":
    try:
        main()
    except Exception as exc:  # surface the error in the Job log for run.sh to see
        print("BENCH ERROR: {}".format(exc), file=sys.stderr, flush=True)
        raise
