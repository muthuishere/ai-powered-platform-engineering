# DuckDB as a query runner over pure Parquet on MinIO

> **Self-contained experiment (spike #3).** Keep your data as **Parquet on object
> storage** and use **DuckDB as a disposable query runner** over it — no catalog DB,
> no table format, no DuckLake, no Iceberg. Just files you own and an engine you can
> kill and restart. This spike stands up MinIO, writes a 50M-row Parquet file to it,
> scans it back, times a few aggregations, and emits `results.json` + `RESULTS.md`
> per the [experiments spec](../EXPERIMENTS-SPEC.md). It is the **baseline** the
> format spikes (Iceberg, DuckLake, Vortex) are measured against.

## The pattern: DuckDB is the engine, not the database

The old instinct is "pick a database and load the data into it." The lakehouse
instinct is the opposite: **the data is files you own** — here, one Parquet object on
an S3-compatible bucket — and the **engine is disposable**. DuckDB is an in-process
analytics database that reads and writes Parquet directly and holds **no state of its
own**. Kill the DuckDB pod, start another, point it at the same bucket, and it reads
exactly the same data. The compute scales and fails independently of the storage.

This is the simplest, most honest form of the query-runner pattern: **pure Parquet,
no metadata layer at all**. Every other data spike in this repo adds something on top
(a SQL catalog in DuckLake, manifest files in Iceberg, a different columnar encoding
in Vortex) — and is worth it only if it beats *this* baseline on size, ingest, scan,
or query latency. So this spike's numbers are the denominator for the whole table.

## What "pure Parquet" buys you (and what it doesn't)

What you get for free with just Parquet on S3:

- **Columnar + compressed.** Parquet is column-oriented with per-column encodings
  (dictionary, RLE, delta) and block compression (ZSTD here). Analytic scans read
  only the columns they touch; the low-cardinality `city` column dictionary-compresses
  hard, the `amount` double does not — a realistic mix.
- **Predicate/row-group pruning.** Parquet stores per-row-group min/max statistics, so
  DuckDB can skip whole row groups a filter can't match without reading them. We write
  with `ROW_GROUP_SIZE 1000000` to give that pruning something to work with.
- **Zero lock-in.** Any engine (Spark, Trino, pandas, Polars, DuckDB) reads the same
  file. The file *is* the interface.

What you **don't** get — and this is the whole reason the other spikes exist:

- **No transactions / no atomic multi-file commit.** Overwriting `data.parquet` is not
  atomic against concurrent readers. Two writers racing on the same prefix can corrupt
  each other. Pure Parquet is fine for *append-as-new-file* and *read-mostly*; it is
  not a substitute for a table format when you need ACID.
- **No snapshots / no time travel.** There is no history. Yesterday's file is gone the
  moment you overwrite it. (DuckLake/Iceberg add exactly this — at the cost of a
  catalog or a tree of manifest files.)
- **No schema evolution semantics.** Adding a column means rewriting files and agreeing
  out-of-band on what the schema "is." A table format records that for you.

The honest framing for the book: **reach for pure Parquet first.** Add a table format
only when a concrete requirement (ACID, time travel, multi-writer, schema evolution)
forces it — and measure whether it earns its keep against this baseline.

## Object storage: MinIO, and the 2026 caveat

This spike uses **MinIO** because the experiment plan asked for it explicitly, and its
S3 API is the most ubiquitous one to learn against. Be honest about its state:

- **MinIO community edition went maintenance-mode and stopped publishing fresh
  container images in 2025** (the last community server tag is
  `RELEASE.2025-09-07T16-13-09Z`, which the manifest pins; the GitHub repo was
  archived ~Feb 2026). It still runs and is everywhere in existing deployments, **but
  don't start new self-hosted work on it.**
- **Garage** (`dxflrs/garage`, Rust, by Deuxfleurs) is the live, S3-compatible
  alternative — the sibling [`talos-data/`](../talos-data/) spike runs on it. Because
  the DuckDB side only ever talks S3, **swapping MinIO → Garage is just changing the
  endpoint and key**; not a line of `bench.sql` changes. That swappability is the
  point of the pattern.

## DuckDB S3 + Parquet syntax (verified June 2026)

The three calls that matter, exactly as `demo/bench.sql` uses them:

```sql
INSTALL httpfs; LOAD httpfs;          -- s3:// support
CREATE OR REPLACE SECRET minio (
    TYPE s3, KEY_ID '...', SECRET '...',
    ENDPOINT 'minio:9000',
    URL_STYLE 'path',                 -- REQUIRED for MinIO/Garage (AWS defaults to vhost)
    USE_SSL false                     -- plaintext in-cluster demo endpoint
);
-- ingest: generate a synthetic dataset and write Parquet straight to S3
COPY (SELECT range AS id, ... FROM range(50_000_000))
  TO 's3://bench/data.parquet' (FORMAT parquet, COMPRESSION zstd, ROW_GROUP_SIZE 1000000);
-- scan + size, all over the same s3:// object
SELECT count(*) FROM read_parquet('s3://bench/data.parquet');
SELECT sum(total_compressed_size), sum(total_uncompressed_size)
  FROM parquet_metadata('s3://bench/data.parquet');
```

`URL_STYLE 'path'` is the one non-obvious knob: non-AWS S3 endpoints use path-style
addressing (`endpoint/bucket/key`), not virtual-host style (`bucket.endpoint/key`).
Forget it and you get DNS/SSL errors against MinIO.

## What's in here

```
exp-duckdb-parquet/
├── README.md                  # this file
├── run.sh                     # apply + wait + bench + scrape -> results.json/RESULTS.md; --teardown
├── demo/
│   └── bench.sql              # the benchmark: install/load, secret, COPY 50M rows, scan, aggregate
└── k8s/
    ├── 00-namespace.yaml
    ├── 10-minio.yaml          # MinIO StatefulSet + Service + creds Secret (plaintext demo)
    ├── 20-bucket-job.yaml     # one-time: `mc mb bench/bench`
    └── 30-bench-job.yaml      # DuckDB Job: renders bench.sql (init container) then runs it
```

### Why a distroless DuckDB image needs an init container

The official `duckdb/duckdb:1.5.3` CLI image is **distroless** — no shell, no `sed`.
So `bench.sql`'s `@TOKEN@` placeholders can't be rendered inside the DuckDB container.
The bench Job uses a tiny **busybox init container** to `sed` the tokens (endpoint,
key, bucket, row count) into a shared `emptyDir`, then the distroless DuckDB container
runs the rendered file with `duckdb :memory: ".read /work/bench.sql"` — which executes
the script and exits non-interactively. (A final SQL/dot-command argument runs and
exits; verified against the DuckDB CLI docs.)

## Run it

`run.sh` targets the **current kube context** (the spike's own cluster) — it never
switches contexts; read the context line it prints first. It is idempotent:
re-applying is a no-op where unchanged, and the bench Job is deleted-then-recreated so
it actually re-executes.

```bash
./run.sh              # apply MinIO, make the bucket, run the bench, scrape metrics
./run.sh --teardown   # delete the whole namespace
```

After a run you get:

- **`results.json`** — the spec metrics contract (`ingest_s`, `scan_rows_per_s`,
  `query_p50_ms`, `query_p95_ms`, `on_disk_bytes`, `compression_ratio`), all
  **measured** from the bench Job's `.timer on` output. Any metric the log didn't
  yield stays `null` with a reason in `notes` — **numbers are never fabricated.**
- **`RESULTS.md`** — the same metrics in a readable table plus the raw per-query
  Run Times used for the percentiles.
- **`.last-bench.log`** — the full bench Job log it scraped (for debugging).

### Metrics — how each is measured (not guessed)

| metric | source |
|---|---|
| `ingest_s` | `Run Time` of the `COPY ... TO 's3://...'` statement |
| `scan_rows_per_s` | `ROW_COUNT / Run Time` of the full `count(*)` scan |
| `query_p50_ms` / `query_p95_ms` | nearest-rank percentiles over the **repeated** group-by aggregation Run Times |
| `on_disk_bytes` | `sum(total_compressed_size)` from `parquet_metadata()` (compressed Parquet) |
| `compression_ratio` | `uncompressed / compressed` from `parquet_metadata()` |

`run.sh` walks the log, attributing each statement's `Run Time` to the nearest
`@@BENCH_TAG@@` marker that precedes it, and taking the **last** Run Time before the
next marker (the marker `SELECT` itself also prints a tiny Run Time, which is skipped).

## What runs in the lab vs needs more

- **Runs as-is:** single-node MinIO, one bucket, the DuckDB bench Job. Fine for the
  baseline numbers and the chapter's point.
- **Needs more for anything real:**
  - **MinIO durability:** single node, single PVC = no redundancy; one disk loss is
    data loss. Real deployments run MinIO in distributed/erasure-coded mode (or move to
    Garage with `replication_factor = 3` across zones).
  - **Secrets:** the root user/password is a plaintext demo Secret and doubles as the
    S3 key. Use SealedSecrets / SOPS / an external store and a *scoped* key, not root.
  - **TLS:** the S3 endpoint is plaintext (`USE_SSL false`). Front it with TLS and flip
    the secret to `USE_SSL true`.
  - **Concurrency:** pure Parquet has no atomic multi-writer story (see above). If you
    need that, this baseline is where you graduate to a table format — and the
    Iceberg / DuckLake spikes are the next stops.

## How the `platform-sre` agent reviews this layer

This is a **stateful** component, so a reliability/security review looks for different
things than a stateless Deployment. The `platform-sre` skill would flag:

- **Bucket durability is a config value, not a vibe.** Single-node MinIO on one PVC is
  the storage-layer equivalent of `replicas: 1` with no PDB — a **data-loss finding**.
  The reviewer should read the deployment mode (standalone vs erasure-coded), not
  assume "object storage = safe."
- **No backup of the bucket = no recovery.** Unlike DuckLake there's no catalog to lose
  here, but the Parquet *is* the only copy. The review must verify the bucket is backed
  up (mirror/replication) with a tested restore.
- **Least privilege on the S3 key.** The demo uses the MinIO root user as the data key;
  a real setup scopes a key to just the `bench` bucket. Plaintext creds in a manifest
  are a security-drift finding.
- **Liveness/readiness on the data plane.** MinIO exposes `/minio/health/{live,ready}`;
  the manifest wires both. A stateful pod with no health probes is a reliability finding.

Same agent, same commands, new dimension: for the storage layer "healthy" means
**durable and restorable**, not just "the pod is Running."

---

### Sources verified against current docs (June 2026)

- DuckDB `CREATE SECRET (TYPE s3, ENDPOINT, URL_STYLE 'path', USE_SSL)`,
  `COPY ... TO 's3://...' (FORMAT parquet, COMPRESSION zstd, ROW_GROUP_SIZE ...)`,
  `read_parquet`, `parquet_metadata`, `range()` — DuckDB httpfs/parquet docs
  (`duckdb.org/docs/.../httpfs/s3api`, `.../data/parquet/overview`).
- DuckDB CLI non-interactive run (`duckdb :memory: ".read file.sql"`) and `.timer on`
  "Run Time (s): real ..." output — DuckDB CLI docs (`duckdb.org/docs/.../clients/cli`).
- Official `duckdb/duckdb` image is **distroless** (`gcr.io/distroless/cc-debian12`,
  `CMD ["/duckdb"]`, no shell); current tag **1.5.3** — `hub.docker.com/r/duckdb/duckdb`,
  `github.com/duckdb/duckdb-docker`. (Note: `davidgasquez/duckdb`, suggested in the
  plan, was last pushed ~2 years ago at DuckDB v0.10.3 — too old; we use the official
  image instead.)
- MinIO community images stopped publishing in 2025; last server tag
  `RELEASE.2025-09-07T16-13-09Z`; repo archived ~Feb 2026 — `hub.docker.com/r/minio/minio/tags`,
  Chainguard "secure-and-free-minio" writeup, and the experiments spec's own note.
- `mc alias set` / `mc mb --ignore-existing` — MinIO `mc` reference; image
  `minio/mc:RELEASE.2025-05-21T01-59-54Z`.
