# Step 06: Autonomous remediation (GitOps PR)

Use when the user says "fix it", "open a PR", "remediate", "add a PDB". This is the
**only** state-changing path — and it changes **git**, not the cluster.

## Safety model

- The cluster is never modified directly. The script writes a fix manifest, pushes
  a branch to the Gitea `platform` repo, and opens a PR. ArgoCD reconciles the fix
  **only after a human merges**.
- **Dry-run by default.** Without `--apply` it prints the manifest and the exact
  git/PR commands and stops. Require explicit user confirmation before `--apply`.

## 1. Open the Gitea tunnel (shown first)

```bash
kubectl --context admin@ops -n gitea port-forward svc/gitea-http 3000:3000
```

Leave it running in another shell; `remediate.py` clones/pushes via `localhost:3000`.

## 2. Preview the fix

```bash
python3 .claude/skills/talos-sre/scripts/remediate.py \
  --cluster {cluster} --fix missing-pdb --namespace {ns} --workload {name}
```

Shows the generated `PodDisruptionBudget` and the planned git actions. Review with
the user.

## 3. Apply (opens the PR)

```bash
python3 .claude/skills/talos-sre/scripts/remediate.py \
  --cluster {cluster} --fix missing-pdb --namespace {ns} --workload {name} --apply
```

Pushes branch `remediate/missing-pdb-{ns}-{name}` and opens a PR to `main`. Give the
user the PR URL and tell them ArgoCD syncs on merge.

## Supported fixes (MVP)

| `--fix` | What it generates |
|---|---|
| `missing-pdb` | a `PodDisruptionBudget` (minAvailable=1) for a single-replica workload |

Extend by adding a generator to `FIXES` in `scripts/remediate.py`. Probe/securityContext
patches are the natural next fixes (v2).

## Failure modes

- clone fails → the port-forward (step 1) isn't running.
- PR creation 4xx → branch already exists, or the `platform` repo/user differs from
  `scripts/remediate.py` constants.
