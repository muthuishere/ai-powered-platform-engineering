# Build briefs — *Zero to Autonomous AI-SRE on Talos*

These are the **per-chapter build guides for the coding agent**. Each chapter
folder says *what to start, how to do it, and what is what*, and maps 1:1 to a
book chapter. The book pulls tested snippets from the real artifacts referenced
here — nothing is hand-copied.

Read this index first, then build chapters in order.

| Ch | Build guide | Lab artifact | Skill capability |
|----|-------------|--------------|------------------|
| 1 | [chapter-1-genai-talos-lab.md](chapter-1-genai-talos-lab.md) | 4 Docker Talos clusters | first read-only call / inventory |
| 2 | [chapter-2-safe-sre-skill-scaffold.md](chapter-2-safe-sre-skill-scaffold.md) | — | the skill scaffold + guardrails (preflight) |
| 3 | [chapter-3-health-reliability.md](chapter-3-health-reliability.md) | fault workloads | `health.py` + `reliability.py` |
| 4 | [chapter-4-security-certs-maturity.md](chapter-4-security-certs-maturity.md) | drift workloads | `security_drift.py` + `certs.py` + `report.py` |
| 5 | [chapter-5-gitops-remediation.md](chapter-5-gitops-remediation.md) | ArgoCD + Gitea hub | `remediate.py` (detect → PR → ArgoCD) |

## The four principles every chapter must honour

This is an **enterprise** AI-SRE: a careful, evidence-grounded teammate, not an
AI that "runs your cluster." Every artifact in every chapter enforces:

1. **Read-only by default.** Capability scripts physically allow-list read verbs
   (`kubectl get/describe…`, `talosctl health/etcd…`). A mutating verb is a hard
   error. The *only* state-changing path is Chapter 5, and it changes **git**
   (a pull request), never the cluster directly.
2. **Ask which cluster first.** No default, no guessing — an explicit, validated
   context (`admin@ops`, `admin@workload-1`…) is required, or the run is refused.
3. **Show every command before running it.** Each `kubectl`/`talosctl` call is
   echoed to stderr before execution. Nothing happens off-screen.
4. **An auditable path before any change reaches the platform.** Remediation flows
   detect → manifest → **PR** → human review → ArgoCD sync. Git is the audit log;
   merge is the human gate.

**Evidence-grounded agentic loop:** scripts gather grounded evidence (raw API
reads); the LLM only *reasons over what the scripts return* and every finding
cites its evidence. The model never free-hands a cluster command — it routes
through the guarded scripts. A `prerequisites.enforce()` guard (binaries + repo
guard + cluster guard) runs first in every script; fail-fast, no silent recovery.

## Build-agent decisions (answered)

The original brief asked the coding agent to decide and report. Decisions taken:

1. **Skill name → `talos-sre`.** The lab is Talos-specific (immutable, API-driven,
   no SSH), and the name states the platform plainly. `platform-sre` was rejected
   as over-broad for what the lab actually exercises.
2. **Reasoning-layer model → Claude (Anthropic), provider-agnostic by design.**
   This is a Claude Code *skill*: the reasoning layer is whichever agent loads
   `SKILL.md`. The scripts embed **no** LLM call and return plain evidence, so
   there is no provider lock-in. Default and tested with Claude (latest Opus/Sonnet).
3. **v2 GitOps remediation → in scope now (MVP).** `remediate.py` is built:
   detect → generate fix manifest → open PR to Gitea → ArgoCD syncs on merge.
   Dry-run by default; `--apply` required to push. MVP fix set = `missing-pdb`;
   probe/securityContext patches are the documented v2 extension point.
4. **Built vs stubbed → see each chapter's "Status" section.** Summary: lab (4
   clusters + ArgoCD/Gitea hub) built & verified live; health/reliability/security
   capabilities verified against real injected faults; certs/report/remediate
   implemented (remediate `--apply` requires the Gitea port-forward running).

## Where the real artifacts live

- **Lab:** `spikes/talos-gitops/` — numbered scripts `01`→`04`, GitOps manifests
  under `gitops/`, fault workloads under `lab/`.
- **Skill:** `.claude/skills/talos-sre/` — `SKILL.md`, `references/` (workflow,
  activation-routing, steps, cheatsheet), `scripts/*.py`.

Conventions for both follow the house skill style documented in the global
`~/.claude/CLAUDE.md` (mirrors `reqsume-sre` and `huddle`).
