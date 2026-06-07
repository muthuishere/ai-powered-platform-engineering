# exp-pdb-eviction — does a PodDisruptionBudget keep a service up during a drain?

**Lane:** workload reliability & recovery.

A 4-replica "highly available" service can still serve **zero traffic** for a
window during a node drain / upgrade / autoscaler scale-down — if every pod is
evicted at once and the replacements aren't `Ready` yet. The textbook fix is a
**PodDisruptionBudget**. This spike measures what it actually buys you, with real
numbers, on a real Talos bare-metal cluster.

## Idea

Deploy the **same** app twice, 4 replicas each, behind two Services:

| variant | protection |
|---|---|
| `app-with-pdb` (A) | `PodDisruptionBudget(minAvailable: 3)` |
| `app-without-pdb` (B) | none |

The only independent variable is the PDB. The app takes a few seconds after start
to become `Ready` (`READY_DELAY_S`), modelling a real app — so a replacement can't
instantly cover for an evicted pod.

We drive steady in-cluster traffic to both, then run an **eviction storm**: repeated
`POST .../pods/<pod>/eviction` calls — byte-for-byte what `kubectl drain` issues.
The API server enforces the PDB on exactly this call, returning **HTTP 429** for any
eviction that would drop below `minAvailable`. That 429 throttling is the whole
mechanism, and it's why the experiment is **non-destructive**: we never drain the
(single, shared) node — we only evict this namespace's own pods.

## Measured

- availability % (OK / total requests) after the storm, per variant
- failed requests, longest consecutive-failure gap (worst client-visible outage)
- min ready replicas observed (sampled from EndpointSlices)
- evictions allowed vs blocked-by-PDB (429 count)

## Run

```bash
./run.sh              # deploy -> traffic -> eviction storm -> measure -> results.json + RESULTS.md
./run.sh --teardown   # delete the namespace
```

Uses the current kube context; writes only to namespace `exp-pdb-eviction`.

Ties to the book's `reliability.py`, which flags workloads that have **no
PodDisruptionBudget** as a reliability finding — this spike is the measured
"why it matters".
