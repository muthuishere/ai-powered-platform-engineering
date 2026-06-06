# Agent Build Brief — K8s/Talos SRE Agent Skill

Self-contained brief for the coding agent building the companion code + skill for the book
**_Generative AI for Platform Engineering — K8s, Talos Linux, GitOps & Agent Skills_**.

---

## 1. Context

Two repos:

- **Manuscript:** `aipoweredkubernetesplatformengineering` (Leanpub, Markua) — the book.
- **This repo (code):** `ai-powered-platform-engineering` — companion code + skill.
  - `chapters/` — code that mirrors the 5 book chapters **1:1**. The book pulls *tested* snippets from here; never hand-copy code into the manuscript.
  - `skills/` — the SRE agent skill (below).
  - `spikes/` — throwaway experiments.

The book teaches the reader to build the skill incrementally, one capability per chapter, against a local Talos lab. The book is **enterprise-framed**: governance, safety, auditability, and operating from one cluster up to a fleet.

## 2. What to build

A **K8s/Talos SRE agent skill** at `skills/<name>/`, cloning the structure and conventions of the already-shipped reference skill:

> **Reference to copy:** `~/muthu/gitworkspace/reqsume-workspace/reqsume/infra/skills/reqsume-sre`
> Read it first. It is the canonical house pattern. This skill is its K8s/Talos twin — same skeleton, different substrate (`kubectl` + `talosctl` instead of Taskfile + Postgres).

### Folder skeleton (mirror reqsume-sre exactly)

```
skills/<name>/
├── SKILL.md                       # frontmatter description + trigger words
├── README.md                      # install + scenarios table
├── workflow.md                    # variables, core rules, process order
├── references/
│   ├── activation-routing.xml     # route a request to the right step
│   ├── schema.md                  # k8s resource + Talos API reference
│   └── presets/                   # *.yaml / promql diagnostic checks
│       ├── unhealthy-nodes.yaml
│       ├── missing-probes.yaml
│       ├── expiring-certs.yaml
│       └── privileged-pods.yaml
├── steps/
│   ├── step-00-preflight.md       # cluster guard, binary check, context check
│   ├── step-01-cluster-health.md  # nodes / etcd / control-plane
│   ├── step-02-reliability.md     # probes / replicas / PDBs
│   ├── step-03-security-drift.md  # privileged / runAsRoot / NetworkPolicies
│   ├── step-04-certs.md           # expiry -> outage prediction
│   └── step-05-preset.md          # pick from references/presets/
└── scripts/
    ├── prerequisites.py           # binary + context checks
    ├── env_loader.py              # kubeconfig / talosconfig resolution
    ├── kube_runner.py             # read-only kubectl wrapper, refuses mutating verbs
    └── talos_runner.py            # read-only talosctl wrapper
```

### reqsume-sre → this skill (mapping)

| reqsume-sre | this skill |
|---|---|
| repo guard (`/reqsume` remote) | cluster guard (valid kube/talos context) |
| ask env: `dev`/`production` | ask cluster: `dev`/`staging`/`prod` |
| `step-01-logs` (Taskfile logs) | `step-01-cluster-health` (talosctl + kubectl) |
| `step-02-sql` (read-only Postgres) | `step-02-reliability` (probes/replicas/PDBs) |
| `step-03-preset` (`presets/*.sql`) | `step-03-security-drift` + `step-04-certs` + `step-05-preset` |
| `scripts/sql_runner.py` (read-only guard) | `scripts/kube_runner.py` / `talos_runner.py` |
| `schema.md` (table reference) | `schema.md` (k8s resource + Talos API reference) |
| v2: write-with-audit (`ops_audit`) | v2: **GitOps PR remediation** (detect -> PR -> ArgoCD) |

## 3. Non-negotiable guardrails (same discipline as reqsume-sre)

- **Read-only by default.** `kube_runner`/`talos_runner` refuse mutating verbs (`apply`, `delete`, `edit`, `patch`, `scale`, `drain`, `cordon`, `upgrade`, `reset`, `reboot`, …). No working around the check.
- **Ask which cluster first** — `dev` / `staging` / `prod`; default to `dev` when unspecified.
- **Show every command before running it.** Wait for confirmation, especially against prod.
- **Cluster guard** — refuse to run without a valid, expected kube/talos context.
- **Auditable path** — any change (v2) goes through an explicit, logged, reviewable step (a PR), never a direct mutation.
- **Fail fast** — missing binary, missing context, missing preset → stop and report; don't try to recover.

## 4. The reasoning layer (what makes it more than a kubectl wrapper)

Scripts gather **grounded evidence**; the LLM reasons only over what the scripts return; **every finding cites its evidence** (the manifest line, the cert date, the failing probe). Output of a full run = a **platform maturity report**: scored dimensions (e.g. Security / Reliability / Cost / Operations) + ranked, evidence-cited findings + recommended fixes. No ungrounded guessing.

## 5. Lab

Must be runnable on **local Docker Talos clusters** (`talosctl cluster create`). Every step needs something to run against with zero cloud cost.

## 6. Chapter ↔ capability map (build order)

| Book ch | Code / skill capability |
|---|---|
| 1 — GenAI for Platform Engineering & the Talos Lab | lab setup; first read-only call |
| 2 — Anatomy of a Safe SRE Agent Skill | the scaffold + `step-00-preflight` + guardrails + auditable path |
| 3 — Cluster Health & Reliability Review | `step-01-cluster-health` + `step-02-reliability` |
| 4 — Security, Certs & the Platform Maturity Report | `step-03-security-drift` + `step-04-certs` + the maturity report |
| 5 — GitOps & Autonomous Remediation | v2: detect -> PR -> ArgoCD; extend to staging/prod/fleet |

## 7. Decide and report back

1. Final **skill name** (`platform-sre` / `talos-sre` / other — single-word, action-oriented).
2. **Model provider** for the reasoning layer.
3. Whether **v2 GitOps PR remediation** is in scope now or deferred (reqsume-sre deferred its write path; mirroring that is fine).
4. A short note on **what was actually built vs. stubbed**, per step.
