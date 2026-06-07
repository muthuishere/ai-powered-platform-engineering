# exp-hpa-scaling — HPA scale-up latency under synthetic CPU load

**Lane:** elasticity & performance.

**Question this spike answers:** "Elastic" is a marketing word. The SRE
question is *how fast*. From the instant real CPU load arrives, how long until
Kubernetes:

1. notices (metrics-server scrapes CPU),
2. decides (the HPA controller computes desired replicas), and
3. *serves* — a brand-new replica is scheduled, started, and passes its
   readiness probe?

And once the load goes away, how long to scale back in?

This spike **measures** those wall-clock latencies on a real Talos bare-metal
cluster, rather than quoting the docs.

## What it deploys (own namespace `exp-hpa-scaling`)

- **metrics-server** v0.8.0, pinned, with the Talos-correct `--kubelet-insecure-tls`
  flag (the kubelet on Talos serves a self-signed cert the cluster CA doesn't
  sign). Installed **only if not already present** — another spike
  (`exp-resource-waste`) may have installed it; teardown only removes it if
  *this* spike installed it (marker file `.installed-metrics-server`).
- **cpu-burner** Deployment: a ~40-line stdlib Python HTTP server (from a
  ConfigMap, image `python:3.12-slim`) with a `/burn?ms=N` endpoint that spins a
  CPU busy-loop for N ms. CPU request 150m, limit 500m. 1 replica to start.
- A **Service** in front of it.
- An **autoscaling/v2 HPA**: target 50% CPU, `minReplicas: 1`, `maxReplicas: 6`,
  with a snappy `scaleUp` behavior (`stabilizationWindowSeconds: 0`) so we
  measure raw reaction speed, and a 60s `scaleDown` window so scale-down is
  observable within a bounded run.
- A **load-generator** pod (`curlimages/curl`) that fires 8 concurrent,
  continuous `GET /burn?ms=100` loops at the Service. (Tuned so the workload
  crosses the 50% target hard enough to scale to max, but does not saturate a
  single replica so badly that its readiness probe is starved — which would flip
  the pod NotReady and stall the HPA with "did not receive metrics for targeted
  pods".)

## How it measures

`run.sh` records a timestamped series (`series.log`: epoch, readyReplicas, HPA
cpu%) while polling every few seconds, and derives:

| metric | definition |
|---|---|
| `scale_up_latency_s` | (first time `readyReplicas > 1`) − T0(load start) |
| `time_to_stabilize_s` | (replica count unchanged for 30s, while > 1) − T0 |
| `peak_ready_replicas` | max Ready replicas observed |
| `peak_cpu_utilization_pct` | max HPA-observed CPU% (how hard we drove it) |
| `scale_down_latency_s` | (back to `minReplicas`) − Tn(load stop), or null |

No number is fabricated: anything not observed stays `null` with a reason in
`notes`.

## Run it

```bash
./run.sh            # deploy -> load -> measure -> results.json + RESULTS.md
./run.sh --teardown # delete the namespace (and metrics-server if this spike installed it)
```

Tunable via env: `POLL_S`, `LOAD_CAP_S`, `STABLE_S`, `SCALEDOWN_CAP_S`,
`SETTLE_S`.

## Guardrails honored

Own namespace only; each pod ≤ 0.5 CPU / 128Mi; the HPA caps total replicas at 6
small pods so the 4-vCPU worker is never exhausted; non-destructive (no node /
control-plane / etcd interference, no cluster-wide policy or default SC changes).

## How it ties to the book

This is the *positive* counterpart to `exp-resource-waste` (which shows clusters
run far below what they reserve): here we show the lever that lets you reserve
*less* and let Kubernetes add capacity on demand — and we put a real number on
how quickly that lever responds, so an SRE can reason about whether HPA alone is
fast enough or whether they need pre-provisioned headroom / predictive scaling.
