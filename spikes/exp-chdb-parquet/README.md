# exp-chdb-parquet — chDB (in-process ClickHouse) over Parquet on MinIO

**The idea:** the sibling `exp-duckdb-parquet` spike measures DuckDB scanning a
Parquet file on MinIO. This spike runs the **same workload, same dataset shape,
same object store** through a *different* analytical engine — **chDB**, which is
ClickHouse compiled as an in-process SQL engine (`pip install chdb`, no server).
Putting both engines on identical Parquet-on-S3 lets the `exp-harness` aggregator
compare them apples-to-apples: ingest time, scan throughput, query p50/p95,
on-disk size, and compression ratio.

chDB is the ClickHouse analogue of DuckDB: an embedded OLAP engine you call from a
process, querying object storage directly via the `s3()` table function. No
catalog, no cluster, no local durable state — the only durable artifact is the
Parquet file on MinIO. Kill the pod, the data survives on the bucket.

## What it does

`run.sh` (targets the **current** kube context — it never switches contexts):

1. Applies the namespace + a single-node **MinIO** StatefulSet (S3-compatible
   object store) and a one-time bucket-creation Job.
2. Runs the **chdb-bench** Job: a `python:3.12-slim` pod that `pip install chdb`,
   then runs `bench.py`, which:
   - **ingest** — generates 50M synthetic rows with ClickHouse `numbers()` and
     writes them as Parquet (ZSTD, 1M row groups) to MinIO via
     `INSERT INTO FUNCTION s3(...)`. Dataset columns are identical to the DuckDB
     spike: `id`, `city` (one of 5), `amount = (id*2654435761 % 100000)/100.0`,
     `ts = 2026-06-01 + (id % 86400)s`.
   - **on-disk size** — reads the object size off MinIO (compressed bytes) and the
     file-level `total_uncompressed_size` from ClickHouse's `ParquetMetadata`
     format (logical bytes) → `compression_ratio = uncompressed / compressed`.
   - **scan** — `sum(id)` over all 50M rows. This forces decoding a full column
     (a real scan); `count(*)` is deliberately avoided because ClickHouse answers
     it from the Parquet footer without touching column data.
   - **query** — the per-city `count / avg / max` group-by, run **7×**; the wall
     times feed p50/p95.
3. Scrapes the Job log's `@@METRIC key=value@@` lines into `results.json` (the spec
   contract) + `RESULTS.md`. Every number is **measured in-pod**, never fabricated;
   anything unmeasured stays `null` with a reason in `notes`.

## Run it

```bash
# from a shell whose kube context is THIS spike's cluster (admin@cherry-bench):
./run.sh

# inspect
cat results.json
cat RESULTS.md

# tear down the whole namespace when done
./run.sh --teardown
```

## Files

```
k8s/00-namespace.yaml    namespace (baseline PodSecurity is sufficient)
k8s/10-minio.yaml        MinIO StatefulSet + Service + creds Secret (8Gi PVC)
k8s/20-bucket-job.yaml   one-time `mc mb bench/bench`
k8s/30-bench-job.yaml    the chDB bench: ConfigMap(bench.py) + Job(python:3.12-slim)
demo/bench.py            the chDB driver, kept in sync with the ConfigMap copy
run.sh                   apply + wait + bench + scrape results.json/RESULTS.md
results.json / RESULTS.md  emitted after a run (the contract metrics)
.last-bench.log          raw Job log from the most recent run
```

`demo/bench.py` and the inline copy inside `k8s/30-bench-job.yaml` must stay in
sync. Regenerate the ConfigMap from the demo file with:

```bash
kubectl -n exp-chdb-parquet create configmap chdb-bench-py \
  --from-file=bench.py=demo/bench.py --dry-run=client -o yaml
```

## Notes / caveats

- **No-egress clusters:** the Job `pip install chdb` at startup, so the pod needs
  outbound access to PyPI. If the cluster has no egress, pre-bake an image
  (`FROM python:3.12-slim; RUN pip install chdb==3.6.0`) and swap it into the Job.
- **PodSecurity:** the Job draws a `restricted` warning (it doesn't set the full
  hardened securityContext) but runs fine under the cluster's **baseline** default.
  The namespace is intentionally left at the cluster default — this spike does not
  relabel it.
- **MinIO** community edition went maintenance-mode in 2025 (pinned tag below);
  Garage is the live drop-in S3 alternative. The chDB pattern is identical against
  any S3 endpoint.
- Modest bare-metal box → the **comparison** to DuckDB is the value, not the
  absolute numbers. See `RESULTS.md` for the measured figures and the harness for
  the cross-engine matrix.
