# exp-vortex — Vortex columnar format vs Parquet, on MinIO

> **Runnable benchmark + honest brief.** This spike measures what you actually get
> by swapping Parquet for **Vortex** as the on-object-storage file format: how much
> smaller the file is, how fast it writes, and how fast it scans back. Both formats
> hold the **same synthetic dataset** and are round-tripped through the **same MinIO
> bucket**, so the comparison is apples-to-apples. Output: `results.json` +
> `RESULTS.md`.

## What Vortex is

**Vortex** is a columnar file format and compression framework — think "a faster,
more random-access-friendly Parquet." It started at **SpiralDB** and is now an
**LF AI & Data (Linux Foundation) incubation project** under `vortex-data`. Its
pitch, verified against the project's own docs (June 2026):

- **Logical types vs physical layout are separated.** A column's *type* (the schema)
  is decoupled from its *encoding* (how the bytes are laid out). That lets Vortex pick
  and **nest** encodings per column — FastLanes bit-packing, FSST for strings, ALP for
  floats, RLE/dictionary — and even stack them.
- **Operate on compressed data.** Because the reader knows the encoding, it can
  evaluate filter expressions *inside* compressed segments without fully
  decompressing — the headline reason scans can be much faster than Parquet.
- **Random access is a first-class goal.** Vortex advertises ~**100× faster random
  single-row reads** vs Parquet (vendor figure — directional, not reproduced here),
  because you can address a row without scanning a whole row-group. This is the thing
  Parquet is genuinely bad at.
- **Zero-copy Arrow.** Vortex arrays convert to/from Arrow with no copy, so it slots
  into the Arrow/DataFusion/DuckDB/Polars world cleanly.

## Why it's interesting

Parquet is 13 years old and its row-group/page model makes **point lookups** and
**wide-schema** workloads expensive — you pay row-group-sized I/O to read one row.
Vortex targets exactly those gaps (random access + better, nestable compression)
while staying Arrow-native and object-storage-first. If it holds up, it's a
**drop-in replacement for Parquet** in a lakehouse where you own the files.

## Maturity — be honest (June 2026)

- **The format is stable.** Since release **0.36.0**, Vortex guarantees backwards
  compatibility — files written by any version ≥ 0.36 stay readable. The Python
  package `vortex-data` is at **0.74.0** (June 2026) with manylinux2014 wheels for
  x86_64 **and** aarch64, Python ≥ 3.11.
- **DuckDB has a *core* Vortex extension** (announced Jan 2026): `INSTALL vortex; LOAD
  vortex;` then `SELECT * FROM read_vortex('f.vortex')` and `COPY (...) TO 'f.vortex'
  (FORMAT vortex)`. So you can query Vortex from DuckDB today, not just Python/Rust.
- **But the ecosystem is younger than Parquet's by a decade.** Parquet is everywhere —
  every engine, every cloud, every governance tool. Vortex has Arrow/DataFusion/DuckDB/
  Spark/Polars bindings but nothing like Parquet's universal reach. **Treat Vortex as
  the high-performance option you reach for when you control the readers**, not yet the
  safe interchange default. The vendor "100×/10–20×" figures are real claims on
  specific microbenchmarks — believe the *direction*, measure your *own* workload.
  That's what this spike does.

## What this spike measures

A Python Job ([`k8s/30-bench-job.yaml`](k8s/30-bench-job.yaml)) generates one
deterministic 5M-row analytics table (low-cardinality strings, a near-sorted id, a
float, a timestamp — the shape where columnar compression earns its keep), then for
**each** format:

1. writes it locally (timed → **ingest_s**),
2. uploads to MinIO and reads the stored object size (→ **on_disk_bytes**,
   **compression_ratio** = raw Arrow bytes ÷ on-disk bytes),
3. downloads and scans the whole file back to Arrow (timed → **scan_rows_per_s**).

Parquet uses `pyarrow` with **zstd** (a fair, strong baseline — not the weak default).
Vortex uses `vortex-data`'s default encoding cascade.

### The Vortex Python API used (verified against docs.vortex.dev)

```python
import vortex as vx
arr = vx.array(arrow_table)                       # Arrow -> Vortex (compresses)
vx.io.write(arr, "data.vortex")                    # encode + persist
tbl = vx.open("data.vortex").scan().read_all().to_arrow_table()   # read back
```

(`vx.open()` can also read `s3://` URLs directly via a `store=` arg; we round-trip
through MinIO with `boto3` instead so the *on-disk size we report is exactly what the
object store holds* for each format — the number that matters for a lakehouse bill.)

## Layout

```
exp-vortex/
├── README.md                    # this file
├── run.sh                       # deploy -> run -> results.json + RESULTS.md; --teardown
├── results.json                 # written by run.sh (measured)
├── RESULTS.md                   # written by run.sh (Vortex vs Parquet table)
└── k8s/
    ├── 00-namespace.yaml
    ├── 10-minio.yaml            # MinIO StatefulSet + Service + creds Secret
    ├── 20-minio-bootstrap-job.yaml  # one-time: create the `bench` bucket
    └── 30-bench-job.yaml        # ConfigMap(bench.py) + the Python benchmark Job
```

## Run it

```bash
./run.sh             # deploy MinIO, run the bench, emit results.json + RESULTS.md
./run.sh --teardown  # delete the namespace (all pods, PVCs, secrets)
```

Idempotent — re-running re-applies the manifests and re-runs the Job. `results.json`
is lifted out of the Job's pod logs (sentinel-delimited), so no shared volume is
needed.

## Honesty / graceful degradation

- **No fabricated numbers.** Everything in `results.json` is measured. The Parquet
  baseline always runs. If the `vortex-data` wheel can't install or run on the node
  (unusual arch, air-gapped pull), the Job still records Parquet and sets the Vortex
  metrics to `null` **with a reason** in `notes` — never a guess.
- **MinIO caveat.** MinIO Community Edition went maintenance-mode and the repo was
  archived (~Feb 2026). The spec asks for MinIO, so we pin a known-good pre-archive
  CE image. The manifest is S3-API-only, so **Garage** (the live FOSS alternative,
  used by the neighbouring `talos-data` spike) is a drop-in swap.
- **Nesting/scale.** Small bare-metal boxes → modest absolute numbers; the *ratio*
  (Vortex vs Parquet on the identical dataset and store) is the value, not the wall
  clock.

### Sources verified against current docs (June 2026)

- `vortex-data` package, version, wheels, Python support — PyPI `vortex-data` (0.74.0).
- Python API (`vx.array`, `vx.io.write`, `vx.open(...).scan().read_all().to_arrow_table()`,
  S3/object-store `store=` support) — `docs.vortex.dev` Python API + I/O pages.
- Format stability since 0.36.0, encodings (FastLanes/FSST/ALP), operate-on-compressed —
  `docs.vortex.dev`, `vortex.dev`, GitHub `vortex-data/vortex`.
- DuckDB **core** Vortex extension (`read_vortex`, `COPY ... (FORMAT vortex)`) —
  `duckdb.org/2026/01/23/duckdb-vortex-extension`, `duckdb.org/docs/.../vortex`.
- MinIO CE maintenance-mode/archive timeline — carried from the `talos-data` spike brief.
```
