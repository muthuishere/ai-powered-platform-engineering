# Arm B — Postgres in a KubeVirt VM (ILLUSTRATIVE)

> **These manifests will almost certainly NOT come up on the OrbStack lab.** They
> are provided as a correct, illustrative second arm. Run them on a cluster that
> has KubeVirt + CDI + an RWX CSI installed (see prerequisites). When you can't,
> leave the Arm B row in `RESULTS-TEMPLATE.md` blank with a note — do **not**
> fabricate numbers.

## Why a VM at all?

The chapter's question is: *should a database go in a StatefulSet, or in a VM on
the cluster?* Teams reach for VMs when they want a "normal" Postgres install they
can `apt install` and `systemctl` like a classic box, while still scheduling it
on Kubernetes. KubeVirt makes that possible. This arm runs the **same Postgres
version + config** as Arm A so the comparison is the runtime model, not the DB.

## Prerequisites (why it won't run in OrbStack)

| Requirement | What | Lab status |
|---|---|---|
| **Nested virtualization (KVM)** | KubeVirt runs real VMs via `/dev/kvm`. Without it you must enable `useEmulation` (software, slow). | Talos-in-Docker under OrbStack does not pass through `/dev/kvm` to nodes → no hardware virt. |
| **KubeVirt operator + CR** | The `kubevirt` operator and a `KubeVirt` CR that's `Available`. | not installed |
| **CDI (Containerized Data Importer)** | Imports a base OS disk image into a PVC (`DataVolume`). | not installed |
| **RWX CSI** | For HA (live migration / reschedule), the VM disk PVC needs **ReadWriteMany**. With RWO the VM is pinned to one node and cannot live-migrate. | lab has no RWX CSI |

Install order on a capable cluster (versions are examples — pin them):

```bash
# KubeVirt operator + CR
kubectl apply -f https://github.com/kubevirt/kubevirt/releases/download/v1.4.0/kubevirt-operator.yaml
kubectl apply -f https://github.com/kubevirt/kubevirt/releases/download/v1.4.0/kubevirt-cr.yaml
kubectl -n kubevirt wait kv kubevirt --for=condition=Available --timeout=600s
# If no hardware virt: kubectl -n kubevirt patch kv kubevirt --type merge \
#   -p '{"spec":{"configuration":{"developerConfiguration":{"useEmulation":true}}}}'

# CDI (for the OS disk DataVolume)
kubectl apply -f https://github.com/kubevirt/containerized-data-importer/releases/download/v1.60.3/cdi-operator.yaml
kubectl apply -f https://github.com/kubevirt/containerized-data-importer/releases/download/v1.60.3/cdi-cr.yaml

# virtctl plugin (console / migrate)
kubectl krew install virt
```

## Apply

```bash
kubectl --context <kubevirt-cluster> apply -f 02-kubevirt-postgres/
# Watch the VM boot + Postgres install via cloud-init:
kubectl --context <kubevirt-cluster> -n pgbench-vm get vmi -w
# Console (cloud-init log): virtctl console pg-vm -n pgbench-vm
```

## Holding the comparison fair

`10-postgres-config.yaml` carries a `postgresql.conf` whose values are the
**exact same** `shared_buffers`, `max_connections`, `fsync`,
`synchronous_commit`, `wal_level`, etc. as Arm A's `postgresql.parameters`.
`20-virtualmachine.yaml` pins the **same 1 vCPU / 1Gi** and a PVC on the **same
storageClass**. Keep them in lockstep with `01-cloudnativepg/10-cluster.yaml`.

## HA reality check

There is **one** Postgres here. KubeVirt's HA story is:

- **Live migration** (`virtctl migrate pg-vm`) moves the *running* VM to another
  node — needs RWX storage. It does not restart or replicate Postgres.
- **Node death** → the VM can be rescheduled onto a healthy node **only if the
  disk is RWX**; Postgres then crash-recovers on boot. Minutes, single copy.

So `bench/failover-test.sh --arm vm` measures **reschedule + crash recovery**,
not promotion. To match Arm A's HA you would run several Postgres VMs with
streaming replication and a failover controller — i.e. reimplement CloudNativePG.
That tradeoff is the point of the chapter.
