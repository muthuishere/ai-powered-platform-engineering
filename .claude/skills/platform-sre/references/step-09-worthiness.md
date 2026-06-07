# Step 09: Kubernetes-worthiness advisory

Use when the user asks "do we even need Kubernetes here", whether a cluster is
overkill, or about Fargate/Cloud Run alternatives.

## Show the command, then run

```bash
python3 .claude/skills/platform-sre/scripts/worthiness.py --cluster {cluster} [--threshold 15]
```

Read-only. Counts user workloads, services, HPAs, and max replicas, then gives an
**advisory verdict**: below ~15–20 services with no autoscaling and no scale-variability,
the k8s overhead is questionable — consider ECS Fargate / Cloud Run / Azure Container
Apps. Above that, or with real autoscaling/scale, k8s is justified.

## Summarize

- Present it as a **heuristic, not a law** (the script says so) — isolation,
  multi-tenancy, or portability can still justify k8s at small scale.
- Tie it to the evidence: CAST AI telemetry shows clusters routinely run at ~8% CPU /
  ~20% memory; k8s is overhead you pay for scale you may not have.
- `--json` emits the verdict for pipelines/dashboards.
