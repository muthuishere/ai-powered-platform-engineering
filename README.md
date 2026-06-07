# Generative AI for Platform Engineering — Companion Code & Exercises

Runnable code and experiments for the book
**_Generative AI for Platform Engineering — K8s, Talos Linux, GitOps & Agent Skills_**
by **Muthukumaran Navaneethakrishnan** and **Hari Balaji M K** — published on
[Leanpub](https://leanpub.com/).

The book builds one concrete thing: a **safe, governed AI SRE agent skill** that reviews
Kubernetes platforms running on **Talos Linux** — read-only by default, asks which cluster it is
operating against, shows every command before it runs, and is grounded in evidence rather than
guesswork. This repository is where you *run* it. Every chapter pairs prose in the book with a
lab build and a skill capability here, plus a set of experiments measured on a real, hourly
bare-metal Talos cluster.

> **These are the exercises for the book.** Clone it, run it, break it, measure it. Nothing here
> fabricates a number — where the book quotes a result it was measured, and every experiment is
> self-contained so you can reproduce it on your own cluster.

## What's inside

| Path | What it is |
|------|------------|
| `.claude/skills/platform-sre/` | The agent skill the book builds — read-only capabilities (health, reliability, security drift, certs, vulnerabilities, upgrade readiness, k8s-worthiness, a scored maturity report) + GitOps remediation (detect → PR → ArgoCD). |
| `spikes/talos-gitops/` | The local Docker-Talos lab — an `ops` hub (ArgoCD + Gitea) plus `dev` / `staging` / `prod` clusters. |
| `spikes/talos-baremetal/` | Bare-metal / on-prem brief + TCO worksheet + **`cherry-qemu-setup.sh`** (Appendix A as runnable code). |
| `spikes/talos-stateful/` | Ch8 — Postgres StatefulSet (CloudNativePG) vs KubeVirt benchmark. |
| `spikes/talos-data/` | Ch8 — DuckDB as a query runner over a DuckLake lakehouse on object storage. |
| `spikes/talos-ai-operator/` | Ch9 — the embedded, air-gapped AI-operator plugin (mochallama + baked model + the read-only tools). |
| `spikes/exp-*/` | 15+ self-contained experiments — each deploys, benchmarks, writes `results.json`, and tears itself down. |
| `spikes/exp-harness/` | Auto-grades every experiment into `COMPARISON.md`. |
| `spikes/MEASURED-RESULTS.md` | The measured numbers that appear in the book (source of truth). |
| `chapters/` | An agent-facing build brief for each chapter. |

## Chapter → code map

| Ch | Lab build | Skill capability / experiments |
|----|-----------|--------------------------------|
| 1 | Local Docker Talos clusters (immutable, API-driven, no SSH) | first read-only call / preflight |
| 2 | — | the safe SRE skill scaffold + guardrails |
| 3 | health/reliability targets | `health.py`, `reliability.py` · `exp-pdb-eviction`, `exp-probe-failure` |
| 4 | security/cert drift | `security_drift.py`, `certs.py`, scored `report.py` |
| 5 | ArgoCD/Helm GitOps | `remediate.py` (detect → PR → ArgoCD) |
| 6 | deliberately-old image | `vuln.py`, `upgrade.py` · `exp-fearless-upgrade` |
| 7 | bare-metal brief + TCO | `worthiness.py` · `exp-hpa-scaling`, `exp-resource-waste`, `exp-cilium-ebpf`, `exp-spiffe-spire`, `exp-kubespan-multidc` |
| 8 | stateful / storage / data | `talos-stateful`, `talos-data` · `exp-duckdb-*`, `exp-ducklake`, `exp-vortex`, `exp-arrow-flight`, `exp-chdb-parquet` |
| 9 | sovereign on-prem AI operator | `talos-ai-operator` · `exp-mochallama-minio-operator` |
| App. A | bare-metal Talos on Cherry Servers | `spikes/talos-baremetal/cherry-qemu-setup.sh` |

## Quick start (the lab)

```bash
# 1. Stand up the local Docker-Talos lab (ops + dev/staging/prod)
cd spikes/talos-gitops && ./01-*.sh   # numbered scripts bring up clusters + GitOps

# 2. Run a read-only capability against a cluster (defaults to dev, never the current context)
python3 .claude/skills/platform-sre/scripts/report.py --cluster dev

# 3. Run an experiment and auto-grade it
cd spikes/exp-duckdb-parquet && ./run.sh           # -> results.json
cd ../exp-harness && python3 aggregate.py          # -> COMPARISON.md
```

For real `/dev/kvm` (KubeVirt, honest benchmarks) on hourly bare metal, see
`spikes/talos-baremetal/cherry-qemu-setup.sh` and **Appendix A** of the book.

## Ethos

Read-only by default. Ask which cluster first. Show every command. Findings are structured
(`{id, severity, summary, evidence, proposed_fix}`), ranked, with `--json`. The agent is a
careful, evidence-grounded teammate — not an autopilot. And no measurement in the book or this
repo is invented: it was run, or it is marked as a runnable spike with no number.
