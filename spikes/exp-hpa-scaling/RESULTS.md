# Results — exp-hpa-scaling (HPA scale-up latency, measured)

How fast does Kubernetes' HorizontalPodAutoscaler actually react to real
CPU load — from load arriving to a NEW replica serving, and back again?

- **Cluster (kube context):** `admin@cherry-bench`
- **Namespace:** exp-hpa-scaling
- **Target:** cpu-burner Deployment (150m CPU request, `/burn` busy-loop), Service in front
- **HPA:** autoscaling/v2, 50% CPU target, min 1 / max 6, scaleUp stabilization 0s
- **Load:** generator pod, 8 concurrent continuous `/burn?ms=100` loops
- **metrics-server:** v0.8.0 (Talos `--kubelet-insecure-tls`)
- **Ran at (UTC):** 2026-06-07T10:31:39Z

## Metrics (contract)

| metric | value |
|---|---|
| scale_up_latency_s | 25.0 |
| time_to_stabilize_s | 88.0 |
| peak_ready_replicas | 6 |
| peak_cpu_utilization_pct | 341 |
| scale_down_latency_s | 141.0 |

## The learning

Autoscaling latency is the sum of several pipeline stages: metrics-server
scrape interval (15s here), the HPA controller sync period (~15s default),
the scheduler placing the new pod, the image already being cached, and the
readiness probe passing. `scale_up_latency_s` is the end-to-end wall clock
of all of that. `time_to_stabilize_s` shows how long until the replica
count settles at the level that holds CPU near the 50% target.
Scale-down is deliberately slower (60s stabilization window) to avoid
flapping — a real production default is 300s.

## Honest caveats

- Small bare-metal cluster (1 worker, 4 vCPU); the image is pre-cached after
  the first pull, so cold-image pull time is largely excluded from scale-up.
- HPA reads AVERAGE CPU across replicas, so observed CPU% can sit near the
  target once load spreads; `peak_cpu_utilization_pct` is the max seen.
- Any `null` means that metric could not be measured this run (see series.log).

Raw poll series: `series.log` (epoch, readyReplicas, HPA cpu%).
