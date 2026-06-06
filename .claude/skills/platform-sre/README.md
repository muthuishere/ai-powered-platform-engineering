# platform-sre

Safe, autonomous SRE skill for the Talos-on-Docker lab in this repo. Read-only
diagnostics + scored maturity report + GitOps remediation (opens a PR; ArgoCD
syncs on merge). The running deliverable of the book *Zero to Autonomous AI-SRE
on Talos*.

## Install

```bash
./.claude/skills/platform-sre/install.sh
```

Symlinks the skill into `~/.claude/skills/platform-sre`. Restart your agent session so
it discovers the new `SKILL.md`. (It also works in-repo without installing — the
scripts are plain `python3`.)

## Scenarios

| Route | Script | Example prompt |
|---|---|---|
| health | `health.py` | "is ops healthy?" |
| reliability | `reliability.py` | "reliability review on dev" |
| security | `security_drift.py` | "any privileged pods on dev?" |
| certs | `certs.py` | "are any certs about to expire on ops?" |
| report | `report.py` | "give me a maturity report for dev" |
| remediate | `remediate.py` | "open a PR to add the missing PDB" |

Always asks which cluster first (`dev` / `staging` / `prod`, or any context);
defaults to `dev`, never the current context.

## Guardrails

1. **Read-only by default** — `kube.py` allow-lists read verbs; mutations are refused.
2. **Ask which cluster** — default `dev`, never the current context; no guessing.
3. **Cluster guard** — refuses an unknown context (must exist in kubeconfig). No
   repo guard: the skill targets clusters, so it runs against any org's clusters.
4. **Show every command** — scripts echo each `kubectl`/`talosctl` call.
5. The only state-changing path, `remediate.py`, changes **git** (a PR), never the
   cluster. Dry-run unless `--apply`.

## Lab

4 clusters via the Talos Docker provisioner (`spikes/talos-gitops/`): `ops` hub
(ArgoCD + Gitea) + `dev/staging/prod`, each 1 control-plane + 1 worker. Bring it up
with the numbered scripts under `spikes/talos-gitops/scripts/`. Intentional faults
for the read-only capabilities live in `spikes/talos-gitops/lab/`.

## MVP scope / deferred to v2

- Remediation supports `--fix missing-pdb` only; probe/securityContext patches are v2.
- Cert remediation (rotate/recreate) is manual for now.
- Multi-cluster fan-out (one report across the whole fleet) is v2.

## Failure modes

- `unknown cluster '…'` — the name doesn't resolve to a kube context; the error
  lists the real contexts. Pick one (or bring the lab up).
- no kube contexts at all — the lab isn't up; run `spikes/talos-gitops/scripts/01-…`.
- `Refused: non-read kubectl verb …` — a capability tried to mutate; that's the
  read-only guard working. Don't work around it.
- remediate clone fails — start the Gitea port-forward first (see step-06).
