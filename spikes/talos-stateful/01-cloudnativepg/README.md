# Arm A — Postgres as a StatefulSet (CloudNativePG)

[CloudNativePG](https://cloudnative-pg.io/) (CNPG) is a Kubernetes operator that
runs Postgres as a set of pods with operator-managed streaming replication,
automatic failover, and a `-rw` / `-ro` Service split. Under the hood the
instances are pods with one PVC each — the StatefulSet pattern, managed for you.

**This arm runs in the OrbStack lab.**

## Install the operator

`00-operator.yaml` is the upstream CNPG operator manifest reference. Apply it:

```bash
kubectl --context admin@dev apply -f 00-operator.yaml
kubectl --context admin@dev -n cnpg-system rollout status deploy/cnpg-controller-manager
```

> The pinned version is in `00-operator.yaml`. To bump it, replace the URL with a
> newer release tag from https://github.com/cloudnative-pg/cloudnative-pg/releases
> — keep the version pinned so the lab is reproducible.

## The `cnpg` kubectl plugin

CNPG ships a kubectl plugin that makes day-2 ops (status, failover, psql,
pgbench) one-liners. Install via krew:

```bash
kubectl krew install cnpg
```

Useful commands (used by `bench/`):

```bash
kubectl cnpg status pg -n pgbench-ss            # cluster topology + health
kubectl cnpg psql pg -n pgbench-ss              # psql into the primary
kubectl cnpg pgbench pg -n pgbench-ss -- ...    # run pgbench as a Job in-cluster
kubectl cnpg promote pg <replica> -n pgbench-ss # manual failover (the failover test kills instead)
```

## The Cluster

`10-cluster.yaml` defines a 3-instance Cluster (1 primary + 2 replicas).

**Everything that must match Arm B is pinned here** — change it in both arms or
the benchmark is meaningless:

| Knob | Value (edit to match your run) | Mirror in Arm B |
|---|---|---|
| Postgres version | `imageName: ...postgresql:17.x` | VM installs the same 17.x |
| storageClass | `storageClassName` (set to your lab's class) | VM PVC uses the same class |
| CPU | `resources.requests/limits.cpu` | VM `domain.cpu` |
| RAM | `resources.requests/limits.memory` | VM `domain.memory` |
| `shared_buffers`, `max_connections`, `fsync`, `synchronous_commit`, `wal_level` | `postgresql.parameters` | VM `postgresql.conf` (cloud-init) |

> **storageClass note**: leave `storageClassName` set to the class you actually
> have. On the OrbStack lab, `kubectl get storageclass` shows the default; CNPG
> will use the cluster default if you comment the field out. **Whatever you pick,
> use the identical class for the KubeVirt PVC** so storage isn't the hidden
> variable.
