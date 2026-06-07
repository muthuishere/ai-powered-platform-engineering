# exp-fearless-upgrade — Talos "fearless upgrades"

**The Talos differentiator** (Hari's #1 admin pain): on a traditional distro an
in-place upgrade is a one-way, half-mutable mess — `apt upgrade`, hope it boots,
no clean revert. Talos turns the upgrade into an **atomic image swap on an A/B
boot scheme** with a **deprecation preflight built into the upgrade path** and
**boot-time auto-rollback**. This spike runs a real upgrade on a real Talos
cluster and **measures** what an always-on workload sees while it happens.

## The learning (what the book takes from this)

### 1. Two coupled commands — OS vs Kubernetes
Talos splits the upgrade into two commands, joined by a compatibility matrix.
Don't conflate them:

| concern | command | what it swaps |
|---|---|---|
| **Talos OS** (kernel + rootfs) | `talosctl upgrade --image <installer:vX>` | the node's A/B OS slot |
| **Kubernetes** (control-plane + kubelet) | `talosctl upgrade-k8s --to <vX>` | the k8s component images, node-by-node |

You usually bump the OS first (it carries a supported k8s range), then
`upgrade-k8s` within that range.

### 2. The deprecation preflight is built IN
Before anything mutates, `talosctl upgrade-k8s --to <next> --dry-run` runs the
**removed-API / removed-flag preflight** — it checks for API resource versions and
component flags removed in the target release and reports them. No external
`pluto`/`kubent` step required (those still work; this is just in the box). The
spike captures this to `dry-run-preflight.txt` and counts the warnings.

```
talosctl --nodes <cp> upgrade-k8s --to v1.34.0 --dry-run
# → "checking for removed Kubernetes API resource versions"
# → "checking for removed Kubernetes component flags"
```

### 3. Atomic A/B — no half-upgraded node
Each Talos node keeps **two boot slots**. An upgrade writes the new image to the
**inactive** slot and flips the bootloader reference; the running slot is
untouched until reboot. There is no partially-patched filesystem to recover from —
the node is either fully on the old image or fully on the new one.

`--stage` writes the new slot but defers the reboot to the next maintenance
window. (Note: the standalone `--stage`/`--preserve`/`--force` flags are
**deprecated and slated for removal in Talos 1.18**; `--reboot-mode` /
`--progress` / `--namespace` are the v1.13 way.)

### 4. Boot-time auto-rollback + on-demand rollback
If the **new** image fails to boot, the bootloader falls back to the **previous**
slot automatically — the node comes back on the known-good image without a human.
And you can revert on demand:

```
talosctl --nodes <node> rollback   # flip the boot reference to the prior slot + reboot
```

The spike (in `MODE=os`) does a real OS A/B upgrade on the worker, then
`talosctl rollback`, measuring the probe's downtime across **both** transitions.

## What `run.sh` does

1. Deploys an always-on **target** (`Deployment` + `Service`) and an in-cluster
   **probe** that curls the Service every 0.25s, logging `OK`/`FAIL` with epoch
   timestamps. The probe is pinned to a **control-plane** node so it survives the
   **worker** reboot (otherwise we'd measure the probe's own outage).
2. Captures the `upgrade-k8s --dry-run` deprecation preflight → `dry-run-preflight.txt`.
3. Runs the real upgrade and measures the probe's downtime window:
   - `MODE=k8s` (default): `talosctl upgrade-k8s --to <next>` (rolling).
   - `MODE=os`: `talosctl upgrade --nodes <worker> --image <installer> --wait`,
     then `talosctl rollback` — measured separately.
4. Writes `results.json` + `RESULTS.md`; `--teardown` removes everything.

## Run it

On the Talos cluster host (talosconfig at `/root/.talos/config`, kubeconfig
pointing at the cluster):

```bash
./run.sh                  # k8s rolling upgrade + dry-run preflight, measured
MODE=os ./run.sh          # OS A/B upgrade on the worker + rollback, measured
TO_K8S=v1.34.1 ./run.sh   # pin the target k8s version (else next-minor is derived)
TO_TALOS_IMAGE=ghcr.io/siderolabs/installer:v1.13.4 MODE=os ./run.sh   # bump the OS
./run.sh --teardown
```

Uses the **current** kube context and the **current** talosconfig — it never
switches them.

## Metrics (`results.json`)

| field | meaning |
|---|---|
| `upgrade_downtime_s` | longest contiguous FAIL run the probe saw across the upgrade (0.25s granularity) |
| `failed_requests` | count of failed probe requests during the upgrade window |
| `dry_run_warnings_count` | removed/deprecated/WARNING lines from the dry-run preflight |
| `rollback_downtime_s` | same downtime measure across `talosctl rollback` (MODE=os) |
| `from_version` / `to_version` | k8s versions (MODE=k8s) or Talos versions (MODE=os) |

## Honest caveat (read before quoting a number)

On this **single-worker QEMU lab**, the only worker reboots during an OS upgrade,
so `upgrade_downtime_s` is **non-zero by construction** — that is the *truthful*
result, not a bug. The spike still proves the three things that actually matter:
the **built-in deprecation preflight**, the **atomic A/B swap** (no half-upgraded
state), and **rollback**. On a **multi-worker** cluster with a PodDisruptionBudget
and a topology spread, a replica keeps serving while one node drains/reboots and
the same workload would show ~0s downtime. The lab measures the mechanics; the
production story is "add a second worker."

Flags verified against the Talos **v1.13** upgrade docs
(`docs.siderolabs.com/talos/v1.13/.../upgrading-talos` and the Kubernetes upgrade
guide); host `talosctl version` reports `v1.13.3`.
