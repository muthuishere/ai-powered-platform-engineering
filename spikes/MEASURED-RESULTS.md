# Measured Results — source of truth for the book

Every number here was **measured** on a real bare-metal Talos cluster. Chapters may
cite ONLY these. Experiments listed as "authored, not yet run" have NO numbers —
reference them as runnable spikes, never invent figures.

## The lab (state this honestly wherever numbers appear)
- **Cherry Servers `E3-1240v5`** — real bare metal (4 cores, 32 GB, `systemd-detect-virt: none`, real `/dev/kvm`).
- Talos control-plane + worker run as **KVM VMs on that bare-metal host** (so one box = a multi-node cluster). Recipe in Appendix A.
- Therefore a **KubeVirt VM is nested once** (host KVM → Talos VM → KubeVirt VM). Label its figures *nested*, not bare-metal-absolute.
- One small box → treat **comparisons** as the signal, absolute numbers as lab-scale.

## MEASURED (cite these)

### Reliability — `exp-pdb-eviction` (→ Ch3)
PodDisruptionBudget (`minAvailable:3`) vs none, during a real Eviction-API storm, same 4-replica app:
| | with PDB | without PDB |
|---|---|---|
| availability | **100.00%** | 81.44% |
| failed requests | 0 | 36 |
| longest outage | 0.00s | **26.29s** |
| min ready replicas | 3 | 0 (≈25s at zero) |
| evictions blocked (HTTP 429) | 84 | 0 |
The API server refused 84 evictions to honour the budget; the no-PDB service collapsed to 0 ready for ~25s.

### Elasticity — `exp-hpa-scaling` (→ Ch7)
HPA (50% CPU target, min1/max6) under synthetic CPU load:
- scale-up latency (load → new replica Ready): **25 s**
- time to stabilize: **88 s** · peak replicas: **6** (HPA max) · peak observed CPU: **341%**
- scale-down (load stop → back to 1): **141 s**
- Gotcha found: a saturated pod goes NotReady → HPA drops it from the metric set → never scales. Fix = no CPU limit + yielding burn loop + lenient readiness.

### Data engines / formats — (→ Ch8, already added in §8.8)
Same 50M-row Parquet on MinIO, same box, same query:
| engine/format | on-disk | compression | query p95 | scan rows/s |
|---|---|---|---|---|
| DuckDB (Parquet) | 93 MB | 7.6× | **237 ms** | (footer bug) |
| chDB (Parquet) | 322 MB | 2.08× | 2,531 ms | 52.9 M/s |
| Iceberg (DuckDB) | — | — | **6.75 ms** | 17.1 M/s |
| Arrow/Feather | 17 MiB | — | 161 ms | **34.8 M/s** |
| Vortex | ~22 MiB | **~10×** | — | 30.6 M/s |
**Like-for-like:** chDB vs DuckDB (same 50M dataset) — DuckDB wins decisively. Cross-format **sizes** are directional (spikes used different row counts).

### Postgres SS-vs-KubeVirt — `exp-pg-ss-vs-kubevirt` (→ Ch8 §8.8)
Runs on the same box (CNPG StatefulSet vs KubeVirt VM, identical PG version + storage class held constant; KubeVirt nested once). **[numbers pending the run; slot TPS/p50/p95/failover when it completes — do NOT invent]**.

## AUTHORED, NOT YET RUN (no numbers — reference as runnable spikes only)
`exp-pg-statefulset`, `exp-fearless-upgrade`, `exp-cilium-ebpf`, `exp-spiffe-spire`,
`exp-resource-waste`, `exp-probe-failure`, `exp-kubespan-multidc`,
`exp-mochallama-minio-operator`, `exp-duckdb-parquet` scan-rate + `exp-duckdb-iceberg`
on-disk-bytes have known parsing quirks. For any of these: say "the companion repo
includes a runnable spike — run it on the bare-metal lab for numbers," never fabricate.

## Style guardrails (the book's voice)
Honest / no-hype. Leanpub `I>` (insight), `W>` (warning), `T>` (tip) asides. Evidence-first.
Findings shape `{id, severity, summary, evidence, proposed_fix}`. Cluster names dev/staging/prod/ops.
Every chapter opens with its promise (who it's for + what you'll be able to do). The agent is a
careful teammate, not an autopilot. NEVER invent a number; un-measured stays qualitative or null.
