# exp-harness — auto-grade aggregator

This directory turns the raw output of every experiment spike into one
comparison the book can quote. It reads each spike's `results.json`, validates
it against the contract in [`../EXPERIMENTS-SPEC.md`](../EXPERIMENTS-SPEC.md),
and writes a merged JSON + a Markdown report.

## What's here

| file | role |
|------|------|
| `aggregate.py` | scans `../exp-*/results.json`, validates, emits `comparison.json` + `COMPARISON.md`. stdlib-only python3. |
| `run-all.sh` | drives each spike's `run.sh` (resiliently), then calls `aggregate.py`. |
| `comparison.json` | generated — every spike merged, with status + measured metrics. |
| `COMPARISON.md` | generated — the book-facing report. |
| `README.md` | this file. |

## The contract each spike emits

Every spike writes `spikes/<spike>/results.json`:

```json
{ "spike": "exp-duckdb-parquet", "cluster": "cherry-bench",
  "metrics": { "ingest_s": 0.0, "scan_rows_per_s": 0, "query_p50_ms": 0,
               "query_p95_ms": 0, "on_disk_bytes": 0, "compression_ratio": 0.0 },
  "notes": "", "ran_at": "<stamped after run>" }
```

The Postgres and model spikes carry their own metric keys (`tps`,
`failover_s`, `model_pull_s`, `completion_ms`, …). The aggregator pulls only
the keys it knows per spike family; anything else is preserved verbatim in
`comparison.json`.

**Measured, never fabricated.** A metric that was not measured stays `null` (or
is absent). The harness treats absent / empty / malformed / all-null
`results.json` as **not-run** and says so explicitly — it never invents a
number to fill a cell.

## How the auto-grade works

`aggregate.py` knows the canonical list of all 8 spikes. For each:

1. Look for `../<spike>/results.json`.
2. If missing / empty / not valid JSON / no `metrics` object / all-null
   metrics -> record **not-run** with a reason.
3. Otherwise -> record the measured metrics.

It then emits:

- **`comparison.json`** — `{ generated_at, spike_count, ran, not_run, spikes }`.
  `spikes[<name>]` carries `status`, `reason`, `cluster`, `ran_at`, `notes`,
  and the raw `metrics`.
- **`COMPARISON.md`** — the report (below).

Run it any time, even before any spike has run — the normal pre-run state
produces a report that is entirely "not-run", which is correct and intended:

```bash
python3 aggregate.py
```

## How to read COMPARISON.md

Four sections:

1. **Data-format matrix** — one row per format (Parquet, Iceberg, DuckLake,
   Vortex, Arrow/Feather). Columns: on-disk bytes, compression ratio,
   `ingest_s`, `scan_rows_per_s`, `query_p95_ms`. Rows are sorted by on-disk
   size (smallest first); the winner in each column is flagged **(best)**
   (smallest size / latency, highest compression / scan rate). `—` = not
   measured; `_not run_` = that spike hasn't run.
2. **Postgres: StatefulSet vs KubeVirt** — `tps`, `query_p95_ms`,
   `failover_s`, plus the **nesting caveat** (the KubeVirt VM is one nesting
   layer deep, so its numbers are directionally valid, not absolute).
3. **mochallama from MinIO** — `model_pull_s`, `model_load_s`,
   `completion_ms` for booting a model from object storage.
4. **Missing / not-yet-run** — every spike without measured results, with the
   reason. This is the honesty section: absent spikes are shown, not hidden.

## Running everything

`run-all.sh` invokes each spike's `run.sh` and then aggregates.

```bash
# Sequential, against the current KUBECONFIG (one cluster, one spike at a time):
./run-all.sh

# Per-spike clusters: one kubeconfig per spike under a directory,
# named <spike>.kubeconfig (or <spike>.yaml / <spike>):
./run-all.sh --kubeconfig-dir ~/talos-kubeconfigs

# Subset:
./run-all.sh --only exp-vortex,exp-ducklake
./run-all.sh --skip exp-pg-ss-vs-kubevirt

# See the plan without executing:
./run-all.sh --dry-run
```

**Resilience:** a spike whose `run.sh` exits non-zero (or is missing) is
recorded as failed and the run continues to the next spike. The aggregator
still runs at the end. Use `--strict` to make the script exit non-zero when any
spike failed (default exit is 0 so partial runs still grade cleanly).

## Validation

```bash
python3 -m py_compile aggregate.py
bash -n run-all.sh
```
