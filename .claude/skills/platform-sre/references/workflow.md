---
name: platform-sre-workflow
---

# platform-sre Workflow

Read-only SRE diagnostics + GitOps remediation for the Talos lab. Wraps the
numbered lab under `spikes/talos-gitops/` and a set of Python capability scripts.

## Variables

- `{project-root}` = the user's working dir (must be inside a
  `/ai-powered-platform-engineering`-suffixed git checkout).
- `{skill-root}` = installed folder of this skill (`.claude/skills/platform-sre/`).
- `{cluster}` = a kube context: `admin@ops`, `admin@workload-1`,
  `admin@workload-2`, `admin@workload-3`. Always ask if not given. No default.
- `{PYTHON_BIN}` = python3 binary detected in preflight — never hardcode.

## Core Rules

- Run every command from `{project-root}`.
- **Ask which cluster first.** No default; refuse anything that isn't a known context.
- Show every command before running it; the scripts already echo each `kubectl`/
  `talosctl` call — surface them to the user.
- Read-only except `remediate.py` (which opens a PR — git only, never the cluster).
- Refuse to proceed outside the lab repo (the scripts enforce this via
  `prerequisites.enforce()`).
- Fail fast on missing binaries / unreachable cluster / wrong repo.

## Process

1. Read `references/steps/step-00-preflight.md` — repo guard, binaries, list
   clusters, pick `{cluster}`.
2. Read `references/activation-routing.xml` — choose the route + goal.
3. Run the matched step:
   - `step-01-health.md` — nodes / etcd / control-plane
   - `step-02-reliability.md` — probes / replicas / PDBs
   - `step-03-security.md` — privileged / root / hostPath / NetworkPolicy
   - `step-04-certs.md` — expiry → outage prediction
   - `step-05-report.md` — scored maturity report
   - `step-06-remediate.md` — detect → GitOps PR → ArgoCD
4. Summarize findings compactly with evidence (the shown commands). Propose fixes;
   apply only via `step-06-remediate.md` (a PR).

## Lab lifecycle (when the cluster isn't up)

Bring the lab up / down with the numbered scripts under
`spikes/talos-gitops/scripts/`:
`01-create-clusters.sh` → `02-connect-networks.sh` → `03-bootstrap-hub.sh`
→ `04-register-clusters.sh`. Topology: 4 clusters × (1 control-plane + 1 worker).
Fault-injection workloads for the read-only capabilities live in
`spikes/talos-gitops/lab/`.
