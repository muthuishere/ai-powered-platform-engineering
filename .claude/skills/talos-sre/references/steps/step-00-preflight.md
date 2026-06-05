# Step 00: Pre-flight

Run this before anything else. If any check fails, stop immediately and surface
the failure — do not try to recover.

## 1. Confirm the cluster

Ask the user:

> Which cluster — **ops**, **workload-1**, **workload-2**, or **workload-3**?

Skip the prompt only if the user already named one (e.g. "is ops healthy?").
There is **no default**; refuse anything that isn't a known kube context.

Translate the name to a kube context: `ops` → `admin@ops`. Call it `{cluster}`.

## 2. Repo + binaries + cluster guard (one command)

```bash
python3 .claude/skills/talos-sre/scripts/prerequisites.py --cluster {cluster}
```

This enforces, and stops on failure:

- **binaries**: `git`, `kubectl`, `talosctl`, `python3` on PATH (install hints printed).
- **repo guard**: `origin` remote must end with `/ai-powered-platform-engineering`
  (suffix match, so forks pass). Else: `wrong repo: …`.
- **cluster guard**: `{cluster}` must be an existing kube context. If it isn't, the
  script lists the lab contexts it found.

Run with no `--cluster` to just print the lab inventory (use when the user hasn't
chosen yet):

```bash
python3 .claude/skills/talos-sre/scripts/prerequisites.py
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

On success the script prints `talos-sre prerequisites OK`. Proceed to the routed step.
