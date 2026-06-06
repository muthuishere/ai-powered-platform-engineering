---
name: platform-sre
description: >-
  Read-only SRE / diagnostics for Kubernetes clusters on Talos Linux. Trigger
  when the user wants to review cluster health, run a reliability review, scan
  for security drift, check certificate expiry / predict a cert outage, review
  vulnerabilities (CVE / image scan / Talos+Kubernetes version currency / supply
  chain), produce a platform maturity report (scored), or remediate a finding via
  GitOps (open a PR that ArgoCD syncs). Phrases: "check the cluster", "is dev
  healthy", "health of staging", "reliability review", "security review", "any
  privileged pods", "are any certs expiring", "any CVEs / scan the images", "are
  we behind on Talos", "maturity report", "score the platform", "fix the missing
  probes / PDB", "remediate this", "open a PR for the drift". Always asks
  which cluster first (dev / staging / prod); defaults to dev and never the
  current kube context. Refuses any mutating command — read-only except
  remediation, which changes git (a PR), never the cluster.
allowed-tools: Bash(kubectl:*) Bash(talosctl:*) Bash(python3:*) Bash(git:*) Bash(gh:*)
---

# platform-sre

Evidence-grounded SRE for Kubernetes on Talos. It runs against **any** cluster a
team owns — the book's local Docker lab (`spikes/talos-gitops/`: `ops` hub +
`dev` / `staging` / `prod` spokes) or a real organisation's clusters. It
**reads** clusters to find real problems, **scores** platform maturity, and (only
when asked) **remediates through GitOps** — never by touching a cluster directly.
Running deliverable of the book *Zero to Autonomous AI-SRE on Talos*; each chapter
adds one capability.

## Core Rules

- **Ask which cluster first.** Resolve a named cluster (`dev` / `staging` /
  `prod`, or any kube context). If none is named, **default to `dev` — never the
  current kube context**. Skip the prompt only if the user already named one.
- **Read-only by default.** Every capability uses the `kube.py` wrappers, which
  allow-list read verbs. The only state-changing path is `remediate.py`, and it
  changes **git** (opens a PR); ArgoCD reconciles after a human merges.
- **Show every command before running it.** The scripts echo each
  `kubectl`/`talosctl` invocation to stderr. Summarize findings from what they print.
- **Cluster guard.** `prerequisites.enforce()` refuses an unknown context — the
  cluster must exist in kubeconfig. (No repo guard: the skill targets clusters,
  not one checkout, so it works for any org.)
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
| 6 | `vuln.py` | Talos/k8s version currency, image supply-chain, CVE scan (trivy/grype) |
| 7 | — | the same skill runs unchanged against bare-metal clusters (just the kube/talos API) |

Follow the instructions in `references/workflow.md`.
