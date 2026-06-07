# Metrics — Prometheus + a Postgres exporter

A benchmark you can't see inside is just a number. To explain *why* one arm wins
(checkpoint stalls? WAL pressure? connection saturation?) you need **DB-internal**
metrics, scraped during the pgbench run.

## Important: kube-state-metrics alone is NOT enough

The lab already runs `kube-state-metrics` (see
`../../talos-gitops/gitops/apps/04-kube-prometheus-stack.yaml`). That gives you
pod/PVC/restart counts and resource usage — useful, but it has **zero visibility
into Postgres**: no TPS, no `xact_commit`, no buffers, no replication lag, no
checkpoint timing. Those live *inside* the database and need a Postgres exporter.

## Arm A — CloudNativePG exposes metrics natively

CNPG runs a built-in metrics endpoint on **port 9187** of each instance pod —
you do **not** install a separate `postgres_exporter` sidecar. Point Prometheus
at it with a PodMonitor (the kube-prometheus-stack operator picks it up):

```yaml
apiVersion: monitoring.coreos.com/v1
kind: PodMonitor
metadata:
  name: cnpg-pg
  namespace: pgbench-ss
spec:
  selector:
    matchLabels:
      cnpg.io/cluster: pg
  podMetricsEndpoints:
    - port: metrics          # CNPG names the 9187 port "metrics"
```

Then watch `cnpg_backends_total`, `cnpg_pg_stat_*`, `cnpg_pg_replication_lag`,
and checkpoint counters during the run.

> CNPG's metrics ship as a default + user-defined queries ConfigMap. To add
> custom queries, see https://cloudnative-pg.io/documentation/current/monitoring/

## Arm B — KubeVirt VM needs a real postgres_exporter

The VM is opaque to Kubernetes (KubeVirt only reports VM-level metrics via
`virt-handler`). For DB-internal metrics you must run
[`prometheus-community/postgres_exporter`](https://github.com/prometheus-community/postgres_exporter)
**inside or beside the VM**, pointed at the VM's Postgres, and scrape it. To keep
the comparison fair, use the **same exporter query set** as CNPG so you're
comparing like metrics. There is no native exporter here — that's part of the VM
arm's operational cost, and worth noting in the results.

## Wiring it to the lab's Prometheus

The lab's kube-prometheus-stack has `serviceMonitorSelectorNilUsesHelmValues:
false`, so it picks up ServiceMonitors/PodMonitors cluster-wide. Apply the
PodMonitor above (Arm A) / a ServiceMonitor for the exporter (Arm B) into the
arm's namespace and the existing Prometheus will scrape them — no extra
Prometheus to stand up.

> This directory is intentionally docs + a manifest snippet, not a full stack:
> the lab already provides Prometheus/Grafana via GitOps. Reuse it.
