#!/usr/bin/env python3
"""bench.py — measured DuckDB-over-Iceberg metrics. NO fabricated numbers.

Runs entirely in-process with the duckdb python module (so it shares the same pod /
env as create_table.py and needs no separate CLI image). It:

  1. reads the metadata.json location + first snapshot id from env (exported by the
     create step),
  2. configures the MinIO S3 secret + loads httpfs/iceberg,
  3. times a full scan (count) -> scan_rows_per_s,
  4. runs a representative aggregation query N times -> query_p50_ms / query_p95_ms,
  5. times a time-travel scan against the first snapshot -> time_travel_ms,
  6. measures on-disk bytes of the Iceberg tree on S3 (data + metadata) via the
     duckdb httpfs glob,
  7. prints metric lines that run.sh greps into results.json.

Emitted metric lines:
  M_SCAN_ROWS_PER_S=<int>
  M_QUERY_P50_MS=<float>
  M_QUERY_P95_MS=<float>
  M_TIME_TRAVEL_MS=<float>
  M_ON_DISK_BYTES=<int>
  M_SCAN_ROWS=<int>
"""
import os
import time

import duckdb

ENDPOINT_HOSTPORT = os.environ["S3_ENDPOINT_HOSTPORT"]   # host:port, no scheme
ACCESS_KEY = os.environ["S3_ACCESS_KEY"]
SECRET_KEY = os.environ["S3_SECRET_KEY"]
USE_SSL = os.environ.get("S3_USE_SSL", "false")
METADATA = os.environ["ICEBERG_METADATA_LOCATION"]       # s3://.../vN.metadata.json
SNAPSHOT_FIRST = os.environ["ICEBERG_SNAPSHOT_FIRST"]
BUCKET = os.environ.get("ICEBERG_BUCKET", "warehouse")
NAMESPACE = os.environ.get("ICEBERG_NAMESPACE", "lake")
TABLE = os.environ.get("ICEBERG_TABLE", "trips")
N_QUERIES = int(os.environ.get("N_QUERIES", "50"))

con = duckdb.connect()
con.execute("INSTALL httpfs; INSTALL iceberg; LOAD httpfs; LOAD iceberg;")
con.execute(
    f"""
    CREATE OR REPLACE SECRET minio (
        TYPE s3, KEY_ID '{ACCESS_KEY}', SECRET '{SECRET_KEY}',
        ENDPOINT '{ENDPOINT_HOSTPORT}', URL_STYLE 'path', USE_SSL {USE_SSL}
    );
    """
)


def pct(values, p):
    s = sorted(values)
    k = (len(s) - 1) * (p / 100.0)
    lo = int(k)
    hi = min(lo + 1, len(s) - 1)
    return s[lo] + (s[hi] - s[lo]) * (k - lo)


# --- scan throughput: time a full count over the latest snapshot ---
t0 = time.perf_counter()
scan_rows = con.execute(
    f"SELECT count(*) FROM iceberg_scan('{METADATA}')"
).fetchone()[0]
scan_s = time.perf_counter() - t0
scan_rows_per_s = int(scan_rows / scan_s) if scan_s > 0 else 0

# --- query latency: a representative group-by aggregation, run hot N times ---
q = (
    f"SELECT city, count(*), sum(fare) FROM iceberg_scan('{METADATA}') "
    f"GROUP BY city"
)
durations_ms = []
for _ in range(N_QUERIES):
    s = time.perf_counter()
    con.execute(q).fetchall()
    durations_ms.append((time.perf_counter() - s) * 1000.0)
p50 = pct(durations_ms, 50)
p95 = pct(durations_ms, 95)

# --- time travel: scan the FIRST snapshot (older state), time it ---
s = time.perf_counter()
tt_rows = con.execute(
    f"SELECT count(*) FROM iceberg_scan('{METADATA}', "
    f"snapshot_from_id = {SNAPSHOT_FIRST})"
).fetchone()[0]
time_travel_ms = (time.perf_counter() - s) * 1000.0

# --- on-disk bytes: sum every object under the table prefix on S3 (data + metadata) ---
# pyiceberg lays the table out at s3://<bucket>/<namespace>.db/<table>/.
glob = f"s3://{BUCKET}/{NAMESPACE}.db/{TABLE}/**"
try:
    on_disk_bytes = con.execute(
        f"SELECT coalesce(sum(size), 0) FROM glob('{glob}')"
    ).fetchone()[0]
except Exception:
    on_disk_bytes = 0

print(f"M_SCAN_ROWS_PER_S={scan_rows_per_s}")
print(f"M_QUERY_P50_MS={p50:.3f}")
print(f"M_QUERY_P95_MS={p95:.3f}")
print(f"M_TIME_TRAVEL_MS={time_travel_ms:.3f}")
print(f"M_ON_DISK_BYTES={int(on_disk_bytes)}")
print(f"M_SCAN_ROWS={int(scan_rows)}")

print("---", flush=True)
print(f"scanned {scan_rows} rows in {scan_s:.3f}s ({scan_rows_per_s} rows/s)")
print(f"query p50={p50:.2f}ms p95={p95:.2f}ms over {N_QUERIES} runs")
print(f"time-travel (first snapshot) -> {tt_rows} rows in {time_travel_ms:.2f}ms")
print(f"on-disk (Iceberg tree on S3): {int(on_disk_bytes)} bytes")
