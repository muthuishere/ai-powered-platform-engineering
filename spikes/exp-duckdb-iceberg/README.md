# exp-duckdb-iceberg — DuckDB querying Apache Iceberg on MinIO

> **Self-contained experiment.** Stands up MinIO in its own namespace, creates an
> **Apache Iceberg** table with **pyiceberg**, reads it back with **DuckDB**, and
> writes **measured** metrics to `results.json` + `RESULTS.md`. One command up, one
> command down. Numbers are real, never fabricated.

This is spike #4 in `EXPERIMENTS-SPEC.md`: *DuckDB + Apache Iceberg on MinIO — scan
throughput, query latency, file size, and the cost of snapshot / time-travel.* Its
sibling `exp-duckdb-parquet` measures the same engine over bare Parquet; `exp-ducklake`
measures the same idea with metadata-in-SQL. The point is the **format-vs-format**
comparison the harness aggregates.

## The pattern: DuckDB is the query runner; Iceberg is the table format

The data is **files you own** (Parquet on object storage) and the engine is
**disposable** (DuckDB holds no state). What turns a pile of Parquet into a *table*
with schema, ACID commits, and snapshots is a **table format**. Here that format is
**Apache Iceberg**.

```
exp-duckdb-iceberg/
├── README.md                  # this file
├── run.sh                     # deploy -> create table -> bench -> results.json/RESULTS.md; --teardown
├── demo/
│   ├── create_table.py        # pyiceberg: write Parquet + Iceberg metadata to MinIO (2 snapshots)
│   ├── bench.py               # duckdb: read back, time scan/query/time-travel, emit M_* metrics
│   └── scan.sql               # the equivalent read in pure DuckDB SQL (iceberg_scan/_snapshots/_metadata)
└── k8s/
    ├── 00-namespace.yaml
    ├── 10-minio.yaml          # MinIO StatefulSet + Service + Secret (S3 data plane)
    ├── 20-bucket-job.yaml     # one-time: `mc mb warehouse`
    └── 30-bench-job.yaml      # the bench Job: pyiceberg write -> DuckDB read (scripts via ConfigMap)
```

## Why pyiceberg writes and DuckDB reads — the honest 2026 status

DuckDB's `iceberg` extension started as a **reader** and is excellent at it
(`iceberg_scan`, `iceberg_snapshots`, `iceberg_metadata`, time-travel by
`snapshot_from_id` / `snapshot_from_timestamp`). **DuckDB can now write Iceberg too** —
write support landed in the **1.4 LTS** line (Sept 2025), with DELETE/UPDATE in 1.4.2
and `MERGE INTO` / `ALTER TABLE` / partition transforms / Iceberg V3 in **1.5.x**
(2026). **But the DuckDB write path is built around attaching a REST catalog**
(Apache Polaris / Nessie / Amazon S3 Tables): you `ATTACH` the catalog and `INSERT`,
and the catalog mediates the atomic metadata swap.

For a **self-contained lab** we don't want to run a REST catalog server. The path with
the fewest moving parts that **actually works today** is:

1. **pyiceberg** with a **SQLite SQL catalog** creates the table and does two appends,
   writing Parquet **and** the Iceberg metadata tree to MinIO. pyiceberg reports the
   current root `metadata.json` location and the snapshot ids.
2. **DuckDB** reads it by pointing `iceberg_scan` **straight at that `metadata.json`**.
   (We pass the explicit metadata path rather than relying on DuckDB's filename
   "version guessing" — pyiceberg uses random metadata filenames, so guessing is
   unreliable; an explicit path is the robust read.)

So: **write = pyiceberg (SQLite catalog), read = DuckDB**. Documented here because the
"can DuckDB write Iceberg?" answer changed in 2025–2026 and the nuance (yes, but via a
REST catalog) is the whole reason this lab splits the roles.

## What Iceberg actually is — metadata files + manifests + a catalog

This is the headline learning, and the precise contrast with **DuckLake** (`exp-ducklake`).

An Iceberg table is **not** a database. It's a layout on object storage:

```
s3://warehouse/lake.db/trips/
├── data/                       # the Parquet data files (one per append here)
│   ├── 00000-...-.parquet
│   └── 00001-...-.parquet
└── metadata/
    ├── v1.metadata.json        # table schema, partition spec, snapshot LIST, current ptr
    ├── v2.metadata.json        # ... a new one per commit
    ├── snap-<id>-...-.avro     # a MANIFEST LIST per snapshot (points at manifests)
    └── <uuid>-m0.avro          # MANIFEST FILES (point at data files + stats)
```

A **commit** in Iceberg is: write new data files, write new manifest + manifest-list +
`metadata.json`, then **atomically swap the catalog's pointer** to the new root
`metadata.json`. The **catalog** (REST / Glue / Nessie / JDBC / — here a **SQLite**
SQL catalog) does exactly one critical job: hold the pointer to *which* `metadata.json`
is current, and swap it atomically. Everything else — schema, snapshot history, the
file map — is **self-contained on object storage** as those JSON + Avro files.

Listing snapshots means **walking that metadata tree on S3** (which is what
`iceberg_snapshots` / `iceberg_metadata` do). Time-travel means reading an **older**
`metadata.json` / snapshot id and resolving its manifests.

### Iceberg vs DuckLake — where the metadata lives

| | **Apache Iceberg** (this spike) | **DuckLake** (`exp-ducklake`) |
|---|---|---|
| Data | Parquet on object storage | Parquet on object storage |
| Table metadata | **Files on object storage**: `metadata.json` + manifest lists + manifest files, plus a **catalog** pointer (REST/Glue/Nessie/JDBC/SQLite) | **Rows in a SQL DB** (Postgres/SQLite): snapshots, schema, file lists are SQL tables |
| A commit is… | write new data + manifest + manifest-list + metadata.json on S3, then atomically swap the catalog pointer | a transaction in the catalog DB inserting snapshot/file rows |
| List snapshots | walk JSON/Avro metadata on S3 (`iceberg_snapshots`) | `SELECT * FROM ducklake_snapshots(...)` |
| Small writes | each commit writes several new metadata objects to S3 (object churn) | a cheap row insert (can inline tiny writes into the catalog) |
| Hard dependency | the catalog only holds a *pointer* — the metadata is self-contained on S3 | the catalog DB **is** the metadata — lose it and the Parquet is orphaned |

The DuckLake thesis is "object storage is a poor database — don't walk a tree of
immutable JSON/Avro files for every metadata op; put metadata in a SQL DB." Iceberg's
counter-strength is that its metadata is **self-describing on object storage**: the
catalog is a thin pointer, and Iceberg has years of battle-tested multi-engine
integrations (Spark/Flink/Trino/Snowflake/BigQuery) that DuckLake's younger ecosystem
is still building out. For multi-engine, vendor-neutral, or compliance-heavy estates,
**Iceberg is the safer default today**; reach for DuckLake when DuckDB is your primary
engine and you want "metadata is just SQL."

## Run it

```bash
./run.sh             # deploy MinIO + bucket, run the bench, write results.json + RESULTS.md
./run.sh --teardown  # delete the namespace
```

Uses the **current kube context** — check it first (`kubectl config current-context`).
The bench Job pins `pyiceberg[sql-sqlite,pyarrow,s3fs]==0.9.1` and `duckdb==1.5.3` and
installs them at start (so the lab needs no custom image build).

### Run the read locally (optional)

`demo/scan.sql` is the read in pure DuckDB SQL. Port-forward MinIO, export the
`ICEBERG_METADATA_LOCATION` + `ICEBERG_SNAPSHOT_FIRST` that `create_table.py` printed,
and render the tokens with `envsubst` before piping into `duckdb`:

```bash
kubectl -n exp-duckdb-iceberg port-forward svc/minio 9000:9000 &
export S3_ENDPOINT_HOSTPORT=127.0.0.1:9000 S3_USE_SSL=false
export S3_ACCESS_KEY=minioadmin S3_SECRET_KEY=minioadmin123
export METADATA_LOCATION='s3://warehouse/lake.db/trips/metadata/<vN>.metadata.json'
export SNAPSHOT_FIRST=<id-from-create_table.py>
envsubst < demo/scan.sql | duckdb :memory:
```

## What runs in the lab vs needs more

- **Runs as-is:** single-node MinIO (one PVC), a SQLite catalog (single writer), and
  the bench Job. Fine for learning and the chapter's purpose.
- **Needs more for anything real:**
  - **MinIO durability:** one node, one PVC — disk loss is data loss. Real Iceberg
    runs on durable object storage (erasure-coded MinIO / S3 / Ceph). MinIO CE is also
    maintenance-mode (repo archived ~Feb 2026) — Garage is the live OSS swap.
  - **Catalog:** SQLite is single-writer and "dev only" per pyiceberg docs. Production
    Iceberg uses a real catalog (REST/Polaris/Nessie/Glue) — which is also what unlocks
    DuckDB-native writes.
  - **Secrets / TLS:** root creds are plaintext demo values over a plaintext endpoint.
    Use sealed secrets + TLS for anything real.

## How `platform-sre` reviews this layer

Iceberg shifts the crown jewels vs DuckLake. The metadata is **self-contained on S3**,
so the bucket itself must be durable and backed up — losing the data/metadata tree
loses the table even if the catalog survives. The catalog only holds a pointer, but a
**lost or corrupted pointer** still orphans a healthy tree, so the catalog needs backup
too (lighter than DuckLake, where the catalog *is* the metadata). The reviewer checks:
object-store durability/replication (not "object storage = safe"), that snapshot
expiry / orphan-file cleanup is configured so old metadata + data don't accumulate
unbounded, and least-privilege scoping of the S3 key to the one bucket. Same agent,
same commands — for a table-format layer "healthy" means the **bucket is durable and
the catalog pointer is recoverable**.

---

### Sources verified against current docs (June 2026)

- DuckDB Iceberg reader (`iceberg_scan`, `iceberg_snapshots`, `iceberg_metadata`,
  `snapshot_from_id` / `snapshot_from_timestamp`, `unsafe_enable_version_guessing`) —
  DuckDB Iceberg extension docs (`duckdb.org/docs/.../iceberg/overview`) and the S3
  Iceberg import guide.
- DuckDB Iceberg **write** support timeline (1.4 LTS writes via REST catalog; 1.4.2
  delete/update; 1.5.x MERGE/ALTER/V3) — `duckdb.org/2025/11/28/iceberg-writes-in-duckdb`,
  `duckdb.org/2026/05/29/new-iceberg-features`.
- pyiceberg `SqlCatalog` with SQLite + MinIO (`uri` sqlite, `warehouse` s3://,
  `s3.endpoint`, `s3.access-key-id`, `s3.secret-access-key`, `s3.path-style-access`),
  `create_namespace` / `create_table(schema=...)` / `table.append()` /
  `table.metadata_location` / `table.snapshots()` — pyiceberg docs (`py.iceberg.apache.org`
  configuration + SQL catalog reference) and the Dremio "Intro to PyIceberg" walkthrough.
- Iceberg table layout (metadata.json + manifest list + manifest files + catalog
  pointer) and the Iceberg-vs-DuckLake metadata-location contrast — Apache Iceberg spec
  + the sibling `talos-data` DuckLake brief in this repo.
- MinIO CE maintenance-mode/archived timeline (~Feb 2026) — carried from the repo's
  existing `talos-data` README sourcing.
