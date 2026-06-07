# exp-resource-waste — "k8s runs at ~8% CPU / ~20% memory", measured

A self-contained experiment that **measures** the gap between what Kubernetes
workloads *reserve* (requests) and what they *actually use* — on this real Talos
cluster. It is the empirical backing for Hari's sizing/overhead point and the
book's `worthiness.py` heuristic.

## The thesis

You size a Kubernetes deployment by setting `resources.requests`. The scheduler
**reserves** that much CPU/memory on a node for the pod whether or not the pod
uses it. In practice teams guess high — they copy a number from a sizing guide,
or pad "to be safe" — so clusters end up reserving multiples of what they run.

CAST AI's Kubernetes cost-benchmark report (which analyzes thousands of real
clusters) puts the typical cluster at roughly:

- **~8% CPU utilization** (used vs requested)
- **~20% memory utilization** (used vs requested)

i.e. ~90% of reserved CPU and ~80% of reserved memory is paid-for-but-idle.
That gap is the *overhead you pay for scale you may not have*. Kubernetes earns
that overhead when you genuinely need elastic, multi-service scale; below it,
the same workloads run cheaper on ECS Fargate / Cloud Run / Azure Container Apps.
This experiment measures the gap so the book can compare an industry figure to a
number from *this* cluster, not a slide.

## What it deploys

| workload | requests | what it does | role |
|---|---|---|---|
| `over-requester-a` | 1 CPU / 1Gi | sleeps (idle busybox) | over-provisioned |
| `over-requester-b` | 1 CPU / 1Gi | sleeps (idle busybox) | over-provisioned |
| `right-sized` | 50m / 64Mi | sleeps (idle busybox) | control |

Plus a pinned **metrics-server** so `kubectl top` can report actual usage.

The over-requesters reserve **2 full CPUs and 2Gi** between them while idling at a
few milli-cores and a few MiB — that delta is the whole point. The right-sized
control reserves an order of magnitude less for the *same* work.

## metrics-server on Talos — the flag that matters

Talos's kubelet serves its Summary API with a **self-signed serving certificate**
not signed by the cluster CA. Stock metrics-server verifies that cert and so gets
no metrics on Talos (`kubectl top` returns nothing). The Talos guide gives two
fixes; this spike takes the first:

- **(used here) `--kubelet-insecure-tls`** on the metrics-server container — skip
  kubelet cert verification. Self-contained, no machineconfig change. Correct for a
  throwaway bench cluster. This is the one deviation from upstream `components.yaml`,
  flagged in `k8s/10-metrics-server.yaml`.
- **(durable alternative)** enable kubelet server-cert rotation in machineconfig
  (`machine.kubelet.extraArgs: rotate-server-certificates: true`) and run the
  kubelet-serving-cert-approver so metrics-server can validate real certs. Prefer
  this on a long-lived cluster. (Note: the kubelet must restart at least yearly —
  any node reboot/upgrade — for rotation to take effect.)

Pinned to **metrics-server v0.8.0** (supports Kubernetes 1.31+; this cluster is
1.36), image `registry.k8s.io/metrics-server/metrics-server:v0.8.0`.

Source: Talos "Deploy the Metrics Server" guide —
https://www.talos.dev/v1.4/kubernetes-guides/configuration/deploy-metrics-server/

## Run it

```bash
./run.sh              # install metrics-server + workloads, settle, measure, write results
./run.sh --teardown   # delete the namespace AND the metrics-server this spike installed
```

Targets the **current kube context** — it prints the context before applying and
never switches. Outputs:

- `results.json` — the metrics contract (see below)
- `RESULTS.md` — human-readable summary + per-pod `top` + industry comparison
- `.last-top.txt` — raw `kubectl top pods` rows the metrics were parsed from

## Metrics contract (`results.json`)

```json
{
  "spike": "exp-resource-waste",
  "cluster": "<kube context>",
  "metrics": {
    "cpu_requested_cores": 0.0,
    "cpu_used_cores": 0.0,
    "cpu_utilization_pct": 0.0,
    "mem_requested_bytes": 0,
    "mem_used_bytes": 0,
    "mem_utilization_pct": 0.0,
    "overprovision_gap_pct": 0.0
  },
  "notes": "...",
  "ran_at": "<stamped after run>"
}
```

- `cpu_utilization_pct` / `mem_utilization_pct` = `used / requested * 100`,
  summed over the namespace's running pods.
- `overprovision_gap_pct` = `100 - cpu_utilization_pct` (CPU dimension; the memory
  gap is `100 - mem_utilization_pct`).
- **Usage is measured by metrics-server — never fabricated.** If the metrics API
  can't serve pod metrics in the settle window, the usage-derived fields are left
  as literal `null` with the reason in `notes`; requests are still reported from
  the pod specs (they don't depend on metrics-server).

## Ties to `worthiness.py`

This is the measured half of the book's `worthiness.py` advisory (Chapter 7,
`.claude/skills/platform-sre/scripts/worthiness.py`). That tool counts signals —
service count, autoscaling, replica scale — and asks "is this even a Kubernetes
workload?" using the same sourced **~15-20 services** heuristic and the same CAST
AI ~8% / ~20% figure. `worthiness.py` answers *should you be on k8s*; this spike
answers *how much of your k8s is idle reservation*. Low utilization **plus** few
services is the strongest case that the cluster is overhead bought ahead of need.

## Honest caveats

- Idle busybox workloads make the over-provisioning **deliberate and obvious** —
  this measures the *mechanism* (requested >> used), not a production traffic mix.
  Real workloads sit somewhere between the over-requesters and the control.
- The number is for **this experiment's namespace**, not the whole cluster; it is
  meant to be compared to the CAST AI industry figure, not to replace it.
- A near-idle cluster will show very low `cpu_utilization_pct`; that is the thesis,
  not a measurement error.
