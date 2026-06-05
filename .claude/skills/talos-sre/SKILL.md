---
name: talos-sre
description: >-
  Autonomous-but-safe SRE for Talos Kubernetes clusters. Trigger when the user
  wants to review cluster health, run a reliability review, scan for security
  drift, check certificate expiry / predict a cert outage, produce a platform
  maturity report (scored), or remediate a finding via GitOps (open a PR that
  ArgoCD syncs). Phrases: "check the cluster", "is ops healthy", "health of
  workload-1", "reliability review", "security review", "any privileged pods",
  "are any certs expiring", "maturity report", "score the platform", "fix the
  missing probes / PDB", "remediate this", "open a PR for the drift". Always asks
  which cluster first (no default). Read-only except remediation, which changes
  git (a PR), never the cluster. Refuses to run outside the
  ai-powered-platform-engineering lab checkout.
allowed-tools: Bash(kubectl:*) Bash(talosctl:*) Bash(python3:*) Bash(git:*) Bash(gh:*)
---

# talos-sre

Evidence-grounded SRE for the Talos-on-Docker lab (`spikes/talos-gitops/`:
`ops` hub + `workload-1/2/3`). It **reads** clusters to find real problems,
**scores** platform maturity, and (only when asked) **remediates through
GitOps** — never by touching a cluster directly. Running deliverable of the book
*Zero to Autonomous AI-SRE on Talos*; each chapter adds one capability.

## Core Rules

- **Ask which cluster first.** Pass an explicit kube context (`admin@ops`,
  `admin@workload-1`, …). There is no default — ambiguity is refused, not guessed.
  Skip the prompt only if the user already named one.
- **Read-only by default.** Every capability uses the `kube.py` wrappers, which
  allow-list read verbs. The only state-changing path is `remediate.py`, and it
  changes **git** (opens a PR); ArgoCD reconciles after a human merges.
- **Show every command before running it.** The scripts echo each
  `kubectl`/`talosctl` invocation to stderr. Summarize findings from what they print.
- **Repo guard.** `prerequisites.enforce()` refuses to run outside a
  `/ai-powered-platform-engineering`-suffixed checkout (forks pass).
- **Steps run in order, fail fast.** Always run preflight; stop and report on
  failure — don't try to recover.

## Capabilities (one per chapter)

| Ch | Script | Purpose |
|----|--------|---------|
| 1–2 | `prerequisites.py` | guards + lab inventory; the safe entry point |
| 3 | `health.py` | nodes / etcd / control-plane health |
| 3 | `reliability.py` | probes, replicas, PDBs |
| 4 | `security_drift.py` | privileged, runAsRoot, hostPath, NetworkPolicy |
| 4 | `certs.py` | cert expiry → outage prediction |
| 4 | `report.py` | scored platform maturity report |
| 5 | `remediate.py` | detect → open GitOps PR → ArgoCD syncs on merge |

Follow the instructions in `references/workflow.md`.
