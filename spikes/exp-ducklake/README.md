# exp-ducklake — DuckLake: metadata-in-SQL, data on MinIO

> **Self-contained experiment.** Spike #5 in `spikes/EXPERIMENTS-SPEC.md`. It stands
> up its own **MinIO** (object store) + **Postgres** (catalog) in namespace
> `exp-ducklake`, runs a **DuckDB + DuckLake** benchmark Job, and writes measured
> metrics to `results.json` + `RESULTS.md`. No cross-spike sharing — it carries its
> own MinIO/Postgres so runs don't contend. (The `talos-data` chapter spike uses
> **Garage** for the same role; this one uses **MinIO** — the lakehouse layer is
> identical, only the S3 server differs.)

## The pattern: DuckDB is the engine, not the database

The lakehouse instinct: **the data is files you own** (Parquet on object storage) and
the **engine is disposable**. DuckDB is an in-process analytics engine that reads and
writes Parquet directly and holds **no state of its own**. Kill the DuckDB pod, start
another, point it at the same catalog + bucket — it sees exactly the same tables.

What turns a pile of Parquet files into *tables* (schema evolution, ACID commits,
snapshots) is a **table format**. This spike uses **DuckLake**.

## DuckLake ≠ Iceberg — where the metadata lives (the whole point)

Both DuckLake and Apache Iceberg give a pile of Parquet files transactional table
semantics. They differ in **where the table metadata lives**.

| | **Apache Iceberg** (`exp-duckdb-iceberg`) | **DuckLake** (this spike) |
|---|---|---|
| Data | Parquet on object storage | Parquet on object storage |
| Table metadata | **Metadata files** on object storage: a tree of `metadata.json` + **manifest lists** + **manifest files**, plus a **catalog** (REST/Glue/Nessie/JDBC) pointing at the current root metadata file | **Rows in a SQL database** (Postgres here) — snapshots, schema, the file list are all tables you can `SELECT` from |
| A commit is… | write new data files, write a new manifest + manifest-list + `metadata.json` on S3, then atomically swap the catalog pointer | a transaction in the catalog DB inserting new snapshot/file rows |
| Listing snapshots | read & walk JSON manifest files on object storage | `SELECT * FROM ducklake_snapshots('lake')` |
| Small writes | each commit writes several new metadata **objects** to S3 (object churn) | a cheap row insert; DuckLake can even **inline** tiny writes into the catalog |

The DuckLake thesis, in their words:

> **"DuckLake … stores all metadata in a SQL database, instead of file-based
> metadata. This makes catalog operations faster and more scalable."**
> — DuckLake docs / DuckDB Labs

Restated: object storage is a poor database. Walking a tree of immutable JSON
manifest files for *every* metadata operation is slow and write-amplifying, when a
transactional SQL database already does catalog operations well. So DuckLake keeps
**only the bulk columnar data on S3** and puts **all the metadata in SQL**.

That is the idea — and the tradeoff: DuckLake makes the **catalog DB a hard
dependency** (it must be available and backed up), whereas an Iceberg table's
metadata is self-contained on object storage.

### How this spike *demonstrates* the difference (not just asserts it)

`demo/lake.sql` (and the in-cluster `40-ducklake-bench-job.yaml`) makes the
distinction observable:

- **Snapshot history is a SQL query:** `FROM ducklake_snapshots('lake')` returns the
  full lineage straight from Postgres — no manifest tree to walk.
- **The file list is a SQL query:** `ducklake_list_files('lake','events')` returns
  every Parquet object (path + size) as **rows**. In Iceberg the equivalent means
  reading manifest files off S3.
- **Time travel is a predicate, not a file lookup:** `AT (VERSION => 2)` and
  `AT (TIMESTAMP => now())` resolve against catalog rows.
- `results.json` records `metadata_in_sql: true` and the catalog file-row count, so
  the `exp-harness` aggregator can put DuckLake's metadata model next to Iceberg's.

## Compared with the `exp-duckdb-iceberg` spike

`exp-duckdb-iceberg` runs the **same DuckDB engine over the same Parquet-on-MinIO
data**, but with **Iceberg** as the table format — so its metadata is `metadata.json`
+ manifest files on the bucket, fronted by an Iceberg catalog, instead of rows in
Postgres. Run both, then look at `exp-harness/`:

- **Snapshot / time-travel cost:** DuckLake commits should be cheaper for small,
  frequent writes (one catalog row-insert vs several new S3 metadata objects). Both
  spikes time the snapshot + time-travel path so the harness can compare.
- **Operational shape:** Iceberg's metadata is self-contained on S3 (back up one
  store); DuckLake splits durability across **two** stores that must be backed up as
  a **consistent pair** (catalog + bucket). That is a real reliability tradeoff, not
  a performance one.
- **Don't trust the headline.** DuckDB Labs published a figure of roughly **"~926×
  faster"** for certain metadata-heavy operations vs file-based formats. That is a
  **vendor** number on a metadata-bound microbenchmark — directionally plausible (a
  SQL row insert beating a multi-object S3 write is unsurprising) but **not** a
  general throughput claim, and **not reproduced here**. This spike measures *its own*
  ingest/scan/query latency and on-disk size; treat any cross-format speedup as
  "measure your own workload."

## Object storage: MinIO (and the honest footnote)

This spike serves S3 with **MinIO**. Per `EXPERIMENTS-SPEC.md`'s caveat: MinIO's
**community edition went maintenance-mode and the GitHub repo was archived (~Feb
2026)** — no new CE features, console stripped from CE, prebuilt CE images stopped.
It is still **ubiquitous** and its S3 API is everywhere, so we pin a known-good
**pre-archive release tag**. The point of the S3-compatible interface is that the
lakehouse doesn't care: swap MinIO for **Garage** (the live OSS alternative, used in
`talos-data`), **SeaweedFS**, or **Ceph RGW** and the DuckLake/DuckDB layer is byte-
for-byte the same. One MinIO convenience used here: its **root user doubles as a
valid S3 access key id/secret**, so there is no key to mint or paste — the bucket
Job and the benchmark Job reuse the same creds (a real deployment would mint a
**scoped, bucket-limited** key instead).

## What's in here

```
exp-ducklake/
├── README.md                       # this file
├── run.sh                          # deploy -> bench -> results.json + RESULTS.md; --teardown
├── results.json                    # METRICS (written by run.sh — measured, never faked)
├── RESULTS.md                      # human-readable run report (written by run.sh)
├── demo/
│   ├── lake.sql                    # the DuckLake benchmark: attach, ingest, scan, time-travel
│   └── run-demo.sh                 # run lake.sql via the local duckdb CLI (env-driven)
└── k8s/
    ├── 00-namespace.yaml
    ├── 10-minio.yaml               # MinIO StatefulSet + Service + Secret (S3 data plane)
    ├── 20-postgres.yaml            # the DuckLake catalog (Postgres) StatefulSet
    ├── 30-minio-bucket-job.yaml    # one-time: mc creates the 'ducklake' bucket
    └── 40-ducklake-bench-job.yaml  # DuckDB Job: ingest/scan/query + snapshots/time-travel
```

## Run it — one command (in-cluster)

```bash
./run.sh                 # deploy MinIO+PG, make the bucket, run the bench, write metrics
./run.sh --teardown      # delete the exp-ducklake namespace
ROW_COUNT=5000000 ./run.sh   # scale the synthetic dataset
```

`run.sh` is **idempotent** and uses the **current kube context**. It applies the
manifests, waits for MinIO + Postgres, runs the bucket Job, runs the benchmark Job,
then parses the DuckDB `.timer` lines and the emitted `ON_DISK_BYTES=` /
`CATALOG_FILE_ROWS=` markers out of the Job log into `results.json` (the metrics
contract) and `RESULTS.md`. Anything it cannot honestly measure (e.g.
`compression_ratio`, which needs an uncompressed baseline) stays `null` with a
reason rather than being fabricated.

## Run it — local DuckDB CLI (fastest iteration)

Needs the **DuckDB CLI** (a 2026-line build that ships DuckLake 1.0; `duckdb
--version`) and **`envsubst`** (gettext). Port-forward the two services, then:

```bash
kubectl -n exp-ducklake port-forward svc/ducklake-pg 5432:5432 &
kubectl -n exp-ducklake port-forward svc/minio       9000:9000 &

export PG_HOST=127.0.0.1 PG_PORT=5432 PG_DB=ducklake PG_USER=ducklake PG_PASSWORD=ducklake
export S3_ENDPOINT=127.0.0.1:9000 S3_BUCKET=ducklake S3_USE_SSL=false
export S3_KEY_ID=minioadmin S3_SECRET=minioadmin123   # MinIO root = S3 key (demo only)
export ROW_COUNT=2000000

./demo/run-demo.sh
```

The core DuckLake calls, verbatim:

```sql
INSTALL ducklake; LOAD ducklake;
CREATE SECRET minio (TYPE s3, KEY_ID '...', SECRET '...',
    ENDPOINT '127.0.0.1:9000', URL_STYLE 'path', USE_SSL false);
ATTACH 'ducklake:postgres:host=... dbname=ducklake user=ducklake password=...'
    AS lake (DATA_PATH 's3://ducklake/lake/');
USE lake;
-- ... create / bulk-insert / scan / aggregate ...
SELECT * FROM events AT (VERSION => 2);     -- time travel by snapshot
FROM ducklake_snapshots('lake');            -- history is a SQL table
```

## What runs in the lab vs needs more

- **Runs as-is:** single-node MinIO, single-pod Postgres catalog, the DuckDB bench
  Job. Fine for learning and for the chapter's metrics.
- **Needs more for anything real:**
  - **Catalog HA + backup:** the demo Postgres is one pod, one PVC. DuckLake metadata
    lives **only** here — lose it and every Parquet object on MinIO is an orphan.
    Production wants an HA/managed Postgres (e.g. CloudNativePG) with PITR.
  - **Bucket durability:** single-node MinIO is no redundancy. Real MinIO runs
    distributed (≥ 4 drives, erasure coding) across nodes.
  - **Consistent-pair backup:** catalog and bucket can drift (orphaned Parquet, or
    dangling references). Back them up **together**, not independently;
    `ducklake_expire_snapshots` / cleanup handle the orphan side.
  - **Least privilege & secrets:** the demo uses MinIO **root** creds as the S3 key
    and plaintext Secrets. Use a **scoped** bucket key and SealedSecrets/SOPS.
  - **TLS:** the S3 endpoint is plaintext (`USE_SSL false`); front MinIO with TLS and
    flip the secret.

---

### Sources verified against current docs (June 2026)

- DuckLake 1.0 (April 2026, MIT) · `ATTACH 'ducklake:postgres:...' (DATA_PATH
  's3://...')` · `AT (VERSION => n)` / `AT (TIMESTAMP => ...)` · `ducklake_snapshots`
  / `ducklake_list_files` — DuckLake docs (`ducklake.select`), DuckDB Labs
  "DuckLake 1.0" release.
- DuckDB `CREATE SECRET (TYPE s3, ENDPOINT, URL_STYLE 'path', USE_SSL)` for MinIO —
  DuckDB httpfs docs, MinIO "DuckDB and MinIO" blog (`s3_url_style='path'`).
- MinIO StatefulSet (ports 9000 API / 9001 console, `MINIO_ROOT_USER` /
  `MINIO_ROOT_PASSWORD`, `/minio/health/ready`) — MinIO k8s docs.
- MinIO CE maintenance-mode / repo-archived timeline (~Feb 2026) — InfoQ / Hacker
  News / itsfoss, echoed in `EXPERIMENTS-SPEC.md`.
```
