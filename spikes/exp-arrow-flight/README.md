# Apache Arrow + Arrow Flight — zero-copy columnar transport

> **Self-contained experiment.** Spike #7 of the data series. It stands up an
> **Arrow Flight server** that holds a synthetic columnar dataset *in memory* and
> serves it to a **client Job** over Flight `DoGet`, measuring how fast columnar
> data moves when the **wire format and the in-memory format are the same thing**.
> It also writes that table both as **Feather (Arrow IPC)** and as **Parquet** to
> compare on-disk size. Namespace: `exp-arrow-flight`.

## The one idea: Arrow is a memory layout, not a file

Most data formats you know (CSV, JSON, Parquet, ORC) describe **bytes on disk**.
**Apache Arrow** is different: it specifies how columnar data is laid out **in RAM**
— contiguous, typed column buffers with a known null bitmap, padded for SIMD. The
point of standardizing the *in-memory* layout is interchange **without
serialization**: if two processes both speak Arrow, one can hand the other a buffer
and the receiver uses it **as-is**, no parse, no copy, no per-row object churn.

That is the whole value proposition, and it's why Arrow underpins so much of the
modern data stack — pandas 2.x, Polars, DuckDB, Spark's vectorized paths, and the
DuckLake/Iceberg readers in the sibling spikes all move data *as Arrow* internally.

## Where each piece fits

| Layer | Format | Lives | Optimized for |
|---|---|---|---|
| **At rest** | **Parquet** | object storage / disk | small footprint, column pruning, predicate pushdown over cold data |
| **At rest (Arrow-native)** | **Feather / Arrow IPC** | disk | fast load (memory-map straight into Arrow), no decode step |
| **In memory** | **Arrow** | RAM | zero-copy compute, SIMD, language interchange |
| **On the wire** | **Arrow Flight** | gRPC stream | moving Arrow between machines without re-serializing |

The mental model: **Parquet is how you store columns cheaply; Arrow is how you
hold and compute on them; Flight is how you ship them across the network.** They are
complementary, not competitors — Parquet-at-rest is decoded into Arrow once, then
everything downstream stays Arrow.

## Arrow Flight — what it actually is

Flight is a **gRPC-based protocol** for bulk transfer of Arrow record batches. The
key trick: the payload on the wire is the **Arrow IPC** encoding, which is the same
columnar buffers you already have in memory. So a `DoGet` is closer to a streamed
`memcpy` than to "serialize → send → deserialize". Compared with shipping the same
data as JSON or row-by-row over ODBC/JDBC, Flight skips the row-materialization and
re-parse tax entirely, and it parallelizes naturally (a query can return multiple
endpoints, each a separate stream you fetch concurrently).

Core verbs (this spike uses the first two):

- **`DoGet(ticket)`** — server streams record batches to the client. *(measured here)*
- **`GetFlightInfo(descriptor)`** — metadata: schema, row count, byte size, endpoints.
- `DoPut` — client streams batches up to the server.
- `ListFlights` / `DoAction` / `DoExchange` — discovery, custom RPCs, bidirectional.

### The current pyarrow API (2026)

Server: subclass `pyarrow.flight.FlightServerBase`, override `get_flight_info`,
`list_flights`, and `do_get`. For an already-in-memory table, return a
`RecordBatchStream(table)` — once constructed, the transfer runs **entirely in C++**
with no per-batch Python on the hot path. (For data that doesn't fit in RAM you'd
return a `GeneratorStream(schema, iter_batches)` instead and stream lazily.)

Client: `client = flight.connect("grpc://host:8815")`,
`info = client.get_flight_info(descriptor)`, then
`reader = client.do_get(info.endpoints[0].ticket)` and `reader.read_all()`.

See `k8s/10-flight-server.yaml` (`server.py`) and `k8s/20-flight-client-job.yaml`
(`client.py`) for the exact, runnable code.

## What's in here

```
exp-arrow-flight/
├── README.md                       # this file
├── run.sh                          # deploy -> benchmark -> results.json + RESULTS.md ; --teardown
└── k8s/
    ├── 00-namespace.yaml
    ├── 10-flight-server.yaml       # Deployment+Service: pyarrow.flight server, in-mem dataset (ConfigMap server.py)
    └── 20-flight-client-job.yaml   # Job: timed DoGet fetches + Feather-vs-Parquet size (ConfigMap client.py)
```

Both pods are stock `python:3.12-slim` that `pip install pyarrow` at boot and run the
ConfigMap-mounted script — so the directory is hermetic (no custom image to build or
push). There is no official pyarrow image; vendoring the script is the trade.

## Run it

```bash
./run.sh             # uses the CURRENT kube context; deploys, benchmarks, writes results
./run.sh --teardown  # delete the exp-arrow-flight namespace
```

`run.sh` applies the namespace + server, waits for the server to be ready (the first
boot does a `pip install` + builds the in-memory table, so allow ~1 min), runs the
client Job, then parses the single `RESULTS_JSON=...` line out of the Job logs and
writes:

- **`results.json`** — the metrics contract envelope:
  `scan_rows_per_s`, `query_p50_ms`, `query_p95_ms`, plus `query_min_ms`,
  `query_mean_ms`, `in_memory_bytes`, `feather_bytes`, `parquet_bytes`,
  `on_disk_bytes` (= Feather), `rows`, `iters`.
- **`RESULTS.md`** — a human table including the Feather/Parquet size ratio.

If the server never goes ready or the client errors, metrics are written as `null`
with a reason — **no fabricated numbers** (per the experiments spec).

### What we measure and why

- **`scan_rows_per_s` (best iteration)** — steady-state Flight throughput in rows/s.
  We take the best of N iterations to report the warm-cache, fully-paged number;
  cold-start effects are excluded via an uncounted warmup fetch.
- **`query_p50_ms` / `query_p95_ms`** — end-to-end `DoGet` latency distribution over
  N iterations (open stream → read all batches into a Table). p95 exposes tail jitter
  from gRPC flow control and GC.
- **Feather vs Parquet on-disk bytes** — the *same* table written with zstd both
  ways. Expect **Parquet ≤ Feather** in most cases: Parquet's encodings
  (dictionary, RLE, delta) plus per-column compression usually beat Feather/IPC,
  which prioritizes fast zero-decode load over minimal size. The ratio is the
  point — it quantifies the "fast to load vs small to store" trade.

## Tuning knobs

| Env (on the Deployment / Job) | Default | Effect |
|---|---|---|
| `FLIGHT_ROWS` (server) | `5000000` | dataset size; raise for bigger throughput numbers (watch memory limit) |
| `FLIGHT_BATCH_ROWS` (server) | `65536` | record-batch granularity |
| `FLIGHT_ITERS` (client) | `20` | number of timed fetches |
| `PYARROW_VERSION` (both) | `18.1.0` | pin; must match server & client |

## Honest caveats

- **One server, one client, in-cluster.** This measures Flight on the *pod network*
  on a small bare-metal box — modest absolute numbers. The **comparisons**
  (Flight rows/s, Feather-vs-Parquet ratio) are the takeaway, not the raw MB/s.
- **`pip install` at boot** keeps the spike hermetic but adds ~30–60 s to first
  start and pulls from PyPI at run time. For a locked-down or repeatable bench you'd
  bake a pinned image. Server and client **must** run the same pyarrow version (the
  IPC format is forward/backward compatible across recent releases, but matching
  removes a variable).
- **No TLS / no auth on Flight.** The demo server is `grpc://` plaintext with no
  `FlightServerMiddleware`. Real Flight deployments use `grpc+tls://` and a token/mTLS
  middleware — out of scope for a throughput spike.
- **`RecordBatchStream` holds the whole table in RAM.** Correct here (the dataset is
  synthetic and bounded); for unbounded/large data use `GeneratorStream` so the
  server streams without materializing everything.

## How the `platform-sre` agent would review this

- **Liveness/readiness:** the server exposes a TCP socket on 8815; the manifest sets
  readiness + liveness probes (a reviewer flags their absence). The Service selects
  the Deployment by label — a missing/typo'd selector is a classic "Service routes to
  nothing" finding.
- **Resource limits:** the in-memory table is bounded by `FLIGHT_ROWS`; the
  Deployment sets a memory **limit** so a too-large `FLIGHT_ROWS` OOM-kills the pod
  rather than the node. The reviewer should confirm requests/limits exist (they do).
- **Stateless by design:** the server holds derived, regenerable data only (built at
  boot) — nothing to back up. That is the opposite of the DuckLake spike's "the
  catalog is the crown jewel" posture, and worth contrasting in the book: Arrow Flight
  is a **transport**, not a system of record.
- **Supply chain:** `pip install` at boot pulls unpinned-hash wheels from PyPI; a
  hardened review would pin a baked image with hash-locked deps.

---

### Sources verified against current docs (June 2026)

- `pyarrow.flight` server/client API (`FlightServerBase`, `do_get`,
  `RecordBatchStream` / `GeneratorStream`, `get_flight_info`, `FlightDescriptor`,
  `FlightEndpoint`, `client.do_get(ticket).read_all()`) — Apache Arrow Python
  Cookbook "Arrow Flight" and `pyarrow.flight.FlightServerBase` API reference
  (Arrow v22+/v24 line).
- Arrow as an in-memory columnar standard + Flight as gRPC/Arrow-IPC transport —
  Apache Arrow Flight overview; Voltron Data "Data Transfer at the Speed of Flight".
- Feather (Arrow IPC) `write_feather(..., compression="zstd")` vs Parquet — Apache
  Arrow "Feather File Format" + `pyarrow.feather.write_feather` API reference.
