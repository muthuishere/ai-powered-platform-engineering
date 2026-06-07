# Results — exp-pdb-eviction (does a PDB keep you up during a drain?)

**App:** one stateless HTTP server, deployed twice (`python:3.12-slim`, code from a ConfigMap), 4 replicas each.
**Only variable:** Variant A has a `PodDisruptionBudget(minAvailable: 3)`; Variant B has none.
**Failure mode:** a real **Eviction-API storm** (identical to `kubectl drain`) — the node is never touched.
**Context:** `admin@cherry-bench` · **Ran:** 2026-06-07T10:22:19Z
**Window:** 25s storm + 20s recovery · app Ready-delay 8s baseline first.

## What we did
1. Drove steady in-cluster traffic to both Services, logging OK/FAIL per request with timestamps.
2. Storm-evicted every pod of each variant repeatedly via the Eviction subresource (what a drain does).
3. Sampled ready-endpoint counts throughout, then measured client-visible availability per variant.

## Metrics
| metric | with PDB (A) | without PDB (B) |
|---|---|---|
| availability after storm (%) | 100.00 | 81.44 |
| failed requests | 0 | 36 |
| longest outage gap (s) | 0.00 | 26.29 |
| min ready replicas observed | 3 | 0 |
| evictions allowed | 74 | 247 |
| evictions blocked by PDB (HTTP 429) | 84 | 0 |

## The learning
- **With the PDB:** the API server rejected (`429`) every eviction that would have dropped the
  service below 3 ready pods. The drain is forced to proceed one-at-a-time, waiting for a
  replacement to become Ready before the next pod can go — so the Service kept serving
  (`min ready replicas` stayed ≥ 3) and clients saw near-100% availability.
- **Without a PDB:** nothing throttled the storm. Pods were evicted faster than replacements
  could become Ready (each needs its ready-delay), the Service hit a low — sometimes **zero** —
  ready-endpoint count, and a window of client requests **failed outright**.

## Honest caveats
- Numbers are modest absolute values on a small bare-metal cluster; the **A-vs-B contrast** is the point.
- We evict via the Eviction API directly instead of draining the (single) node — same code path the
  API server runs the PDB check on, but non-destructive to the shared cluster.
- The app's Ready-delay is what makes the no-PDB case actually drop traffic; a truly instant-Ready
  app would hide the gap. Real apps are rarely instant-Ready, which is why PDBs matter.
- Any `null` above means that metric could not be measured this run (see console log).

Raw per-request log: `traffic.log`; ready-endpoint samples: `ready-samples.log`.
