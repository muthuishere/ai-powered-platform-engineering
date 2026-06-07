# Chapter 8 — Stateful, Storage & Data on Talos

> **Audit posture:** the labs deploy real workloads; the agent's review of them is
> read-only · blast radius = **zero**. The benchmark fabricates nothing — it
> measures, with a results template.

> **Who it's for:** teams told "don't run databases/data on Kubernetes." **What you
> learn:** answer that fear with *measured evidence*, not dogma.

|  | **Arm A — CloudNativePG** (StatefulSet) | **Arm B — KubeVirt VM** |
|---|---|---|
| Failover | app-level promotion (automatic) | storage HA + live migration; **no** auto app failover |
| Measured with | `pgbench` — TPS, p50/p95/p99, failover time | `pgbench` — same |

Both arms are held to the same `pgbench` measurement (percentiles and failover
time, not averages). The DuckDB → DuckLake lakehouse demo (catalog in Postgres,
Parquet on Garage S3) is a separate track under `spikes/talos-data/`.

## What you build
- **Postgres-as-StatefulSet vs Postgres-on-KubeVirt benchmark** — `spikes/talos-stateful/`:
  CloudNativePG (StatefulSet) vs a KubeVirt VM, measured with **pgbench** (TPS +
  p50/p95/p99) and **failover timing**, metrics via CNPG/postgres_exporter.
- **DuckDB + DuckLake lakehouse demo** — `spikes/talos-data/`: DuckDB as a stateless
  query runner over a **DuckLake** catalog (metadata in Postgres) with Parquet on
  self-hosted **Garage** S3.

## Why it matters (enterprise / evidence-first)
- The statefulset fear is answered by holding variables constant and **reporting
  percentiles + failover time**, not averages — so the trade-off is a measurement,
  not an opinion. KubeVirt HA = storage-layer (RWX CSI) + live migration, **not**
  automatic app failover; CloudNativePG does app-level promotion. State both honestly.
- **DuckLake ≠ Iceberg:** DuckLake (1.0, Apr 2026, MIT) keeps table metadata in a SQL
  catalog DB; Iceberg keeps it as metadata files + manifests + a catalog. DuckLake's
  ecosystem is younger; Iceberg is safer for multi-engine/compliance.
- **Object storage ≠ DB I/O.** MinIO's community edition is archived/maintenance-mode
  (Feb 2026) → use **Garage** (or SeaweedFS / Ceph RGW); don't treat object volumes
  like an OLTP DB.

## What is what (artifact map)
| Path | Role |
|---|---|
| `spikes/talos-stateful/01-cloudnativepg/` | CNPG operator + 3-instance Cluster (Arm A) |
| `spikes/talos-stateful/02-kubevirt-postgres/` | KubeVirt VM Postgres (Arm B — needs a KubeVirt cluster) |
| `spikes/talos-stateful/bench/` | pgbench + failover scripts; `RESULTS-TEMPLATE.md` |
| `spikes/talos-data/demo/lake.sql` + `run-demo.sh` | DuckDB + DuckLake attach/query/time-travel |
| `spikes/talos-data/k8s/` | Garage + catalog Postgres + demo Job (GitOps-friendly) |

## Verify / Status
- **Arm A (CNPG StatefulSet)** runs in the OrbStack lab against `admin@dev`; **Arm B
  (KubeVirt)** needs nested-KVM + RWX CSI (not OrbStack) — honest illustrative manifests.
- DuckLake demo validated for syntax/render (`kubectl apply --dry-run`, current docs);
  pin image tags before a real run. No fabricated numbers anywhere.
