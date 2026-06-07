#!/usr/bin/env python3
"""create_table.py — build an Apache Iceberg table on MinIO with pyiceberg.

WHY pyiceberg and not DuckDB for the write?
  DuckDB's `iceberg` extension is a strong READER (iceberg_scan / iceberg_snapshots /
  iceberg_metadata). DuckDB *can* now write Iceberg too (write support landed in the
  1.4 LTS line, expanded through 1.5.x in 2026) — but its write path is built around
  attaching a **REST catalog** (Polaris / Nessie / S3 Tables). For a self-contained
  lab we don't want to stand up a REST catalog server, so we CREATE the table with
  pyiceberg against a **SQLite catalog**, write Parquet + the Iceberg metadata tree to
  MinIO, and then let DuckDB READ it by pointing iceberg_scan straight at the
  metadata.json this script reports. That is the combination that "just works" today
  with the fewest moving parts.

What this writes to s3://$ICEBERG_BUCKET/:
  - the Parquet data files (one per append)
  - the Iceberg metadata tree: vN.metadata.json + manifest lists + manifest files
  - the SQLite catalog DB itself is LOCAL (sqlite:///...) — it only stores a pointer to
    the current root metadata.json. (Contrast DuckLake, where ALL metadata is in SQL.)

Two appends => two snapshots, so the reader can demonstrate time-travel.

Outputs (stdout, one per line, consumed by run.sh):
  ICEBERG_INGEST_S=<float>          wall time for the two appends
  ICEBERG_ROWS=<int>                total rows written
  ICEBERG_METADATA_LOCATION=<s3://...metadata.json>   current root metadata
  ICEBERG_SNAPSHOT_FIRST=<id>       first snapshot id (after append #1)
  ICEBERG_SNAPSHOT_LAST=<id>        latest snapshot id (after append #2)

Env (all have lab defaults):
  S3_ENDPOINT, S3_ACCESS_KEY, S3_SECRET_KEY, ICEBERG_BUCKET,
  ICEBERG_NAMESPACE, ICEBERG_TABLE, CATALOG_URI, N_ROWS
"""
import os
import time

import pyarrow as pa
from pyiceberg.catalog.sql import SqlCatalog

S3_ENDPOINT = os.environ.get("S3_ENDPOINT", "http://minio:9000")
S3_ACCESS_KEY = os.environ.get("S3_ACCESS_KEY", "minioadmin")
S3_SECRET_KEY = os.environ.get("S3_SECRET_KEY", "minioadmin123")
BUCKET = os.environ.get("ICEBERG_BUCKET", "warehouse")
NAMESPACE = os.environ.get("ICEBERG_NAMESPACE", "lake")
TABLE = os.environ.get("ICEBERG_TABLE", "trips")
# SQLite catalog DB. Local file: it only holds a pointer to the current metadata.json
# on S3. Kept on an emptyDir in-cluster; the durable lake state is the S3 tree.
CATALOG_URI = os.environ.get("CATALOG_URI", "sqlite:////tmp/iceberg/catalog.db")
N_ROWS = int(os.environ.get("N_ROWS", "200000"))

# Ensure the local dir for the SQLite catalog exists.
if CATALOG_URI.startswith("sqlite:////"):
    os.makedirs(os.path.dirname(CATALOG_URI[len("sqlite:///"):]), exist_ok=True)

# A SQL catalog backed by SQLite, data + metadata on MinIO. path-style-access is
# REQUIRED for MinIO/Garage-style endpoints (AWS defaults to vhost addressing).
catalog = SqlCatalog(
    "lab",
    **{
        "uri": CATALOG_URI,
        "warehouse": f"s3://{BUCKET}/",
        "s3.endpoint": S3_ENDPOINT,
        "s3.access-key-id": S3_ACCESS_KEY,
        "s3.secret-access-key": S3_SECRET_KEY,
        "s3.path-style-access": "true",
        "s3.region": "us-east-1",
    },
)

# Idempotent: drop a prior run so re-running run.sh is clean and snapshot ids are fresh.
try:
    catalog.drop_table(f"{NAMESPACE}.{TABLE}")
except Exception:
    pass
try:
    catalog.create_namespace(NAMESPACE)
except Exception:
    pass  # already exists

# Build the data once (two halves -> two appends -> two snapshots).
half = N_ROWS // 2
cities = ["chennai", "bengaluru", "mumbai", "delhi", "pune"]


def batch(start, n, day):
    ids = list(range(start, start + n))
    return pa.table(
        {
            "id": pa.array(ids, type=pa.int64()),
            "city": pa.array([cities[i % len(cities)] for i in ids], type=pa.string()),
            "fare": pa.array([100.0 + (i % 400) for i in ids], type=pa.float64()),
            "booked_at": pa.array(
                [pa.scalar(0, type=pa.int64()).as_py() for _ in ids], type=pa.int64()
            ),
            "day": pa.array([day] * n, type=pa.int32()),
        }
    )


b1 = batch(0, half, 1)
b2 = batch(half, N_ROWS - half, 2)

# Create the table from the arrow schema, then two separate appends.
table = catalog.create_table(f"{NAMESPACE}.{TABLE}", schema=b1.schema)

t0 = time.perf_counter()
table.append(b1)  # snapshot #1
snap_first = table.current_snapshot().snapshot_id
table.append(b2)  # snapshot #2
ingest_s = time.perf_counter() - t0
snap_last = table.current_snapshot().snapshot_id

metadata_location = table.metadata_location  # s3://.../metadata/vN.metadata.json

print(f"ICEBERG_INGEST_S={ingest_s:.4f}")
print(f"ICEBERG_ROWS={N_ROWS}")
print(f"ICEBERG_METADATA_LOCATION={metadata_location}")
print(f"ICEBERG_SNAPSHOT_FIRST={snap_first}")
print(f"ICEBERG_SNAPSHOT_LAST={snap_last}")

# Human-readable trailer (ignored by run.sh's grep parser).
print("---", flush=True)
print(f"wrote {N_ROWS} rows in 2 snapshots to s3://{BUCKET}/{NAMESPACE}.db/{TABLE}/")
print(f"snapshots: first={snap_first} last={snap_last}")
print(f"root metadata: {metadata_location}")
