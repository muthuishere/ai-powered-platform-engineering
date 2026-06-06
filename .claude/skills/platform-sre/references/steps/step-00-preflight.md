# Step 00: Pre-flight

Run this before anything else. If any check fails, stop immediately and surface
the failure — do not try to recover.

## 1. Confirm the cluster

Ask the user:

> Which cluster — **dev**, **staging**, or **prod**? (or any context you own)

Skip the prompt only if the user already named one (e.g. "is staging healthy?").
If the user gives nothing, the skill **defaults to `dev`** — never the current
kube context. Call the chosen value `{cluster}` (a name like `dev`, or a literal
context like `admin@dev`).

## 2. Binaries + cluster guard (one command)

```bash
python3 .claude/skills/platform-sre/scripts/prerequisites.py --cluster {cluster}
```

This enforces, and stops on failure:

- **binaries**: `kubectl`, `talosctl`, `python3` on PATH (install hints printed).
- **cluster guard**: `{cluster}` must resolve to an existing kube context
  (`dev` → `dev` or `admin@dev`). An unknown name is refused with the list of
  real contexts. There is **no repo guard** — the skill runs against any cluster,
  from anywhere.

Run with no `--cluster` to just print the lab inventory (use when the user hasn't
chosen yet):

```bash
python3 .claude/skills/platform-sre/scripts/prerequisites.py
```

## 3. If the lab isn't up

If no `admin@…` contexts exist, the lab isn't running. Offer to bring it up:

```bash
spikes/talos-gitops/scripts/01-create-clusters.sh    # 4 clusters, 1 cp + 1 worker each
spikes/talos-gitops/scripts/02-connect-networks.sh   # hub↔spoke wiring
spikes/talos-gitops/scripts/03-bootstrap-hub.sh      # ArgoCD + Gitea on ops
spikes/talos-gitops/scripts/04-register-clusters.sh  # register workloads in ArgoCD
```

## 4. Success

On success the script prints `platform-sre prerequisites OK`. Proceed to the routed step.
