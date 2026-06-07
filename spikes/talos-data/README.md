# DuckLake on self-hosted object storage — the query-runner lakehouse

> **Runnable demo + honest brief.** This directory backs **Chapter 8**: keep your
> data as **Parquet on object storage**, and use **DuckDB as the query runner** over
> it. The catalog (table metadata, snapshots, schema history) lives in **Postgres**;
> the data lives in an **S3-compatible bucket** served by **Garage**. The
> `demo/` script runs against any Postgres + S3 endpoint; the `k8s/` manifests stand
> the whole thing up in the OrbStack lab. Where something needs more than the lab can
> give, it says so.

## The pattern: DuckDB is the engine, not the database

The old instinct is "pick a database and put the data inside it." The lakehouse
instinct is the opposite: **the data is files you own** (Parquet on object storage),
and the **engine is disposable**. DuckDB is that engine here — an in-process
analytics database that reads/writes Parquet directly and holds **no state of its
own**. Kill the DuckDB pod, start another, point it at the same catalog + bucket,
and it sees exactly the same tables.

What turns a pile of Parquet files into *tables* (with schema evolution, ACID
commits, and snapshots) is a **table format**. This lab uses **DuckLake**.

## DuckLake ≠ Iceberg — the precise difference

Both DuckLake and Apache Iceberg solve the same problem: give a bunch of Parquet
files transactional table semantics. They differ in **where the metadata lives**.

| | **Apache Iceberg** | **DuckLake** |
|---|---|---|
| Data | Parquet on object storage | Parquet on object storage |
| Table metadata | **Metadata files** on object storage: a tree of `metadata.json` + **manifest lists** + **manifest files**, plus a **catalog** (REST/Glue/Nessie/JDBC) that points at the current root metadata file | **Rows in a SQL database** (Postgres / SQLite / DuckDB) — snapshots, schema, file lists are all just tables you can `SELECT` from |
| A commit is… | write new data files, write new manifest + manifest-list + metadata.json on S3, then atomically swap the catalog pointer | a transaction in the catalog DB inserting new snapshot/file rows |
| Listing snapshots | read & walk JSON manifest files on object storage | `SELECT * FROM ducklake_snapshots(...)` |
| Small writes | each commit writes several new metadata objects to S3 (object churn) | a cheap row insert; DuckLake can even **inline** tiny writes into the catalog |

The DuckLake thesis: object storage is a poor database. Walking a tree of immutable
JSON manifest files for every metadata operation is slow and write-amplifying, when
a transactional SQL database already does catalog operations well. So DuckLake keeps
**only the bulk columnar data on S3** and puts **all the metadata in a SQL DB**.

That is the entire idea — and it's also the tradeoff: DuckLake makes the **catalog DB
a hard dependency** (it must be available and backed up), whereas an Iceberg table's
metadata is self-contained on object storage.

## Maturity — be honest

- **DuckLake hit 1.0 in April 2026 (MIT-licensed, from DuckDB Labs)** with a
  backward-compatibility guarantee — it is a production release, not a preview.
- **But its multi-engine ecosystem is younger than Iceberg's.** DuckLake 1.0 ships
  clients beyond DuckDB (DataFusion, Spark, Trino, pandas), but Iceberg has years of
  battle-tested integrations across Spark/Flink/Trino/Snowflake/BigQuery and a deep
  bench of catalog implementations. **For multi-engine estates, vendor-neutral
  interop, or compliance-heavy environments, Iceberg is the safer default today.**
  Reach for DuckLake when DuckDB is your primary engine and you want the operational
  simplicity of "metadata is just Postgres."
- **Benchmarks: don't trust the headline.** DuckDB Labs published a figure of roughly
  **"926× faster"** for certain metadata-heavy operations vs file-based formats. That
  is a **vendor-published** number on a metadata-bound microbenchmark — directionally
  plausible (a SQL row insert beating a multi-object S3 write is unsurprising) but
  **not a general throughput claim**, and not independently reproduced here. Treat it
  as marketing until you measure your own workload.

## Object storage: the S3 alternative

You need an S3-compatible bucket to hold the Parquet. The self-hosted landscape
shifted in 2025–2026:

- **MinIO** — historically the default. The **community edition went maintenance-mode
  and the GitHub repo was archived (~Feb 2026, locked again Apr 2026)**: no new
  features, the admin console was stripped from CE, prebuilt CE binaries/images
  stopped, and the project steers users to its proprietary AIStor. Still
  **ubiquitous** in existing deployments and its S3 API is everywhere, **but it is no
  longer actively open-source** — don't start new self-hosted work on it.
- **Garage** *(used in this lab)* — S3-compatible object store in **Rust** by the
  Deuxfleurs non-profit. Lightweight, easy to operate, designed for small
  geo-distributed/self-hosted clusters; resilient with `replication_factor = 3`
  across zones. Good fit for a learn-the-primitives lab and modest self-hosted prod.
- **SeaweedFS** — Go, very fast for huge numbers of small objects (Haystack-style);
  S3 gateway available. A strong alternative when object *count* dominates.
- **Ceph RGW (RADOS Gateway)** — the heavyweight: full Ceph cluster with an S3
  gateway. Most operationally demanding, most capable at scale; what you graduate to
  for serious multi-PB durability.

This lab uses **Garage** because it's the simplest honest S3 you can stand up in a
single StatefulSet and still explain end-to-end.

## What's in here

```
talos-data/
├── README.md                       # this file
├── demo/
│   ├── lake.sql                    # the DuckLake demo: attach, write, query, time-travel
│   └── run-demo.sh                 # runs lake.sql via the duckdb CLI (env-driven)
└── k8s/
    ├── 00-namespace.yaml
    ├── 10-garage.yaml              # Garage StatefulSet + Service + config/secrets
    ├── 20-postgres.yaml            # the DuckLake catalog (Postgres) StatefulSet
    ├── 30-garage-bootstrap-job.yaml# one-time: layout + key + bucket
    ├── 40-ducklake-s3-secret.yaml  # S3 creds for the demo (placeholders)
    └── 50-ducklake-demo-job.yaml   # DuckDB Job: runs lake.sql in-cluster
```

## Run it — local CLI (fastest)

You need the **DuckDB CLI** (a version on the 2026 line that ships DuckLake 1.0;
check with `duckdb --version`) and **`envsubst`** (from gettext;
`brew install gettext` / `apt-get install gettext-base`), plus a reachable Postgres
and Garage/S3 endpoint. `run-demo.sh` renders the `${...}` tokens in `lake.sql` with
`envsubst` before piping it into DuckDB, because DuckDB's `ATTACH` / `CREATE SECRET`
take string **literals**, not expressions. The easiest path is to stand up `k8s/`
(below) and port-forward:

```bash
kubectl -n talos-data port-forward svc/ducklake-pg 5432:5432 &
kubectl -n talos-data port-forward svc/garage      3900:3900 &

export PG_HOST=127.0.0.1 PG_PORT=5432 PG_DB=ducklake PG_USER=ducklake PG_PASSWORD=ducklake
export S3_ENDPOINT=127.0.0.1:3900 S3_BUCKET=ducklake S3_USE_SSL=false
export S3_KEY_ID=...      # from the garage-bootstrap Job output
export S3_SECRET=...      # from the garage-bootstrap Job output

./demo/run-demo.sh
```

`lake.sql` will: install/load the `ducklake`, `httpfs`, `postgres` extensions; create
an S3 secret for Garage (`URL_STYLE 'path'` — required for non-AWS endpoints); attach
the lake with the Postgres catalog and `DATA_PATH 's3://ducklake/lake/'`; create a
`trips` table; do two separate inserts (= two snapshots); query current state; print
the snapshot history straight out of the SQL catalog; **time-travel** to an earlier
version; and list the actual Parquet files on S3.

The core DuckLake call, verbatim:

```sql
INSTALL ducklake; LOAD ducklake;
CREATE SECRET garage (TYPE s3, KEY_ID '...', SECRET '...',
    ENDPOINT '127.0.0.1:3900', URL_STYLE 'path', USE_SSL false);
ATTACH 'ducklake:postgres:host=... dbname=ducklake user=ducklake password=...'
    AS lake (DATA_PATH 's3://ducklake/lake/');
USE lake;
-- ... create / insert / query ...
SELECT * FROM trips AT (VERSION => 2);      -- time travel
FROM ducklake_snapshots('lake');            -- history is a SQL table
```

## Run it — in-cluster (OrbStack lab)

```bash
kubectl apply -f k8s/00-namespace.yaml
kubectl apply -f k8s/10-garage.yaml -f k8s/20-postgres.yaml
kubectl -n talos-data rollout status statefulset/garage
kubectl -n talos-data rollout status statefulset/ducklake-pg

# One-time: lay out Garage, make a key + bucket. Copy the printed key into the Secret.
kubectl apply -f k8s/30-garage-bootstrap-job.yaml
kubectl -n talos-data logs job/garage-bootstrap -f     # grab KEY_ID + SECRET here
$EDITOR k8s/40-ducklake-s3-secret.yaml                 # paste them in
kubectl apply -f k8s/40-ducklake-s3-secret.yaml

# Run the query-runner Job.
kubectl apply -f k8s/50-ducklake-demo-job.yaml
kubectl -n talos-data logs job/ducklake-demo -f
```

### What runs in the OrbStack lab vs needs more

- **Runs in the lab as-is:** single-node Garage (`replication_factor = 1`),
  single-node Postgres catalog, and the DuckDB demo Job. Fine for learning and for
  the chapter's purpose.
- **Needs more for anything real:**
  - **Garage durability:** `replication_factor = 1` means *no* redundancy — one disk
    loss is data loss. Real deployments run **≥ 3 nodes across zones, factor 3**.
  - **Catalog HA + backup:** the demo Postgres is one pod with one PVC. Production
    wants a managed/HA Postgres (e.g. CloudNativePG) with PITR backups.
  - **Secrets:** the `rpc_secret`, admin token, Postgres password, and S3 key are
    plaintext demo values. Use SealedSecrets / SOPS / an external secrets store.
  - **TLS:** the demo S3 endpoint is plaintext (`USE_SSL false`). Front Garage with
    TLS and flip the secret.
  - **GitOps note:** everything here is declarative and ArgoCD-friendly *except* the
    Garage layout/key bootstrap, which is imperative one-time state. In a real GitOps
    flow you'd bootstrap once and commit the resulting key as a sealed secret rather
    than run the Job on every sync.

## How the `platform-sre` agent reviews this layer

This is the lab's first **stateful** component, so it changes what a reliability/
security review must look for. The data layer fails differently from stateless
workloads, and the `platform-sre` skill (`reliability.py`, `security_drift.py`,
`report.py`) would flag:

- **The catalog DB is the crown jewel — back it up.** DuckLake metadata lives only in
  Postgres. **Lose Postgres and every Parquet object on S3 becomes an orphan** with
  no schema, no snapshot map, no table. The review must verify the catalog has
  **automated backups with tested restore** (PITR ideally) and is **not** a single
  pod on a single PVC. A healthy bucket with a dead catalog is *not* a recoverable
  lake.
- **Bucket durability is a real config value, not a vibe.** The reviewer should read
  `replication_factor` and the node/zone spread, not assume "object storage = safe."
  `replication_factor = 1` is a **data-loss finding**, the storage-layer equivalent of
  a Deployment with `replicas: 1` and no PDB.
- **Consistency between the two stores.** Catalog and data can drift — orphaned
  Parquet files (committed to S3, never recorded) or dangling references (recorded,
  object missing). The review notes that `ducklake_cleanup_old_files` /
  `ducklake_expire_snapshots` exist for the orphan side and that **catalog and bucket
  must be backed up as a consistent pair**, not independently.
- **Blast radius / least privilege.** The S3 key should be scoped to just the lake
  bucket; the Postgres role should own only the catalog DB. Secrets in plaintext
  manifests are a security-drift finding.

Same agent, same commands, new dimension: for stateful workloads "healthy" means
**backed up and restorable**, not just "pods are Running."

---

### Sources verified against current docs (June 2026)

- DuckLake 1.0 / catalog-in-SQL / time-travel syntax — DuckLake & DuckDB docs:
  `ducklake.select/docs`, `duckdb.org/2026/04/13/ducklake-10`,
  InfoQ "DuckLake 1.0".
- `ATTACH 'ducklake:postgres:...' (DATA_PATH 's3://...')`, `AT (VERSION => n)` /
  `AT (TIMESTAMP => ...)`, `ducklake_snapshots`, `ducklake_list_files` — DuckLake
  usage docs.
- DuckDB `CREATE SECRET (TYPE s3, ENDPOINT, URL_STYLE 'path', USE_SSL)` — DuckDB
  httpfs docs.
- MinIO CE maintenance-mode/archived timeline — InfoQ, Hacker News, itsfoss
  (Dec 2025 maintenance-mode commit; repo archived ~Feb 2026, re-locked Apr 2026).
- Garage config + bootstrap CLI + ports + k8s — `garagehq.deuxfleurs.fr`,
  `deuxfleurs-org/garage`.
