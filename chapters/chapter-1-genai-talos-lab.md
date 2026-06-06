# Chapter 1 — GenAI for Platform Engineering & the Talos Lab

> **Audit posture:** read-only · blast radius = **zero**. The agent's first move is
> a shown, read-only call. Trust is established before any capability exists.

> **Thesis:** an AI agent should reason over a *platform* (its real API state),
> not over dashboards. To do that safely you first need a disposable, immutable,
> API-driven platform to point it at. This chapter stands up that lab and proves
> the agent's very first move: a **read-only** call.

## What you build

1. A local fleet of **4 Talos Kubernetes clusters** via the Docker provisioner —
   `ops` (the future GitOps hub) + `dev/staging/prod`. Each is 1 control-plane + 1
   worker (right-sized for a laptop).
2. The agent's first capability: **inventory + a read-only "hello, cluster"** —
   list the clusters and run one guarded read against each.

## Why it matters (enterprise / audit / agentic)

- **Talos is the right substrate for an AI SRE:** immutable, API-driven, **no SSH**.
  There is no shell for an agent (or a human) to do something unaudited — every
  action is an API call. That property is what makes "autonomous but safe" credible.
- **Disposable lab = safe learning.** The same patterns you build here carry
  unchanged to staging, production, and a fleet — but you rehearse them where a
  mistake costs nothing.
- **The first agentic principle lands immediately:** the agent's first call is
  read-only and shows the command. Trust is established before any capability.

## What to start (prerequisites)

- Docker engine via **OrbStack** (macOS arm64 assumed), `talosctl` ≥ v1.13,
  `kubectl`. Verify: `talosctl version --client`, `docker info`.
- This repo checked out for the lab; the skill itself works against ANY kube
  context (its **cluster guard** only requires the context to exist).

## How to do it

```bash
# from spikes/talos-gitops/
./scripts/01-create-clusters.sh        # builds ops + dev/staging/prod
```

`01-create-clusters.sh` is idempotent and reproducible. The key design points the
chapter must explain:

- **Topology + addressing** live in `scripts/lib.sh` (`CLUSTERS`, per-cluster /24
  subnets, `WORKERS_PER_CLUSTER=1`). The Docker provisioner auto-publishes each
  API on a random high host port and writes it into kubeconfig as `admin@<name>`
  — there is no port wiring to manage.
- **The one hard-won fix** (worth a full sidebar): Talos-in-Docker on OrbStack
  comes up with an **empty `dnsServers` list**, so the node can't resolve
  `registry.k8s.io` to pull the etcd image → etcd wedges in "Waiting" forever and
  the cluster never bootstraps. The script pins nameservers via
  `--config-patch scripts/patches/dns.yaml`. This is the difference between a lab
  that boots and one that hangs; teach it explicitly.
- **Footprint reality:** 12 nodes (2 workers × 4) wedged the Docker engine on a
  laptop. The lab runs at **1 worker/cluster = 8 nodes**. If `docker ps` ever
  hangs, restart OrbStack (`osascript -e 'quit app "OrbStack"'` → `open -a OrbStack`).

Then prove the first read-only call (the agent's entry point):

```bash
python3 ../../.claude/skills/platform-sre/scripts/prerequisites.py   # inventory
# → lists admin@ops, admin@dev/staging/prod after passing cluster + binary guards
```

## What is what (artifact map)

| Path | Role |
|---|---|
| `spikes/talos-gitops/scripts/lib.sh` | shared topology + helpers (clusters, subnets, contexts) |
| `spikes/talos-gitops/scripts/01-create-clusters.sh` | create the 4 clusters (idempotent) |
| `spikes/talos-gitops/scripts/patches/dns.yaml` | the nameserver config-patch (the etcd-wedge fix) |
| `.claude/skills/platform-sre/scripts/prerequisites.py` | guards + cluster inventory = the first read-only capability |

## Verify

```bash
for c in admin@ops admin@dev admin@staging admin@prod; do
  kubectl --context "$c" get nodes
done
```

All nodes `Ready`, Kubernetes v1.36.1, 8 containers total.

## Status (built vs stubbed)

- **Built & verified live:** all 4 clusters up (8 nodes Ready); DNS fix baked in;
  `prerequisites.py` lists the fleet after passing the cluster/binary guards.
