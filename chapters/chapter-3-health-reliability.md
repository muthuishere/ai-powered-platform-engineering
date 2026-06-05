# Chapter 3 — Cluster Health & Reliability Review

> **Audit posture:** read-only · blast radius = **zero** · every `kubectl`/`talosctl`
> call is echoed before it runs. These two capabilities are themselves audit
> controls — they observe and cite evidence, they never change anything.

> Two questions, one chapter: **is the platform alive** (health — the *substrate*:
> nodes, etcd, control-plane) and **will the workloads survive Tuesday**
> (reliability — the *tenants*: probes, replicas, PDBs). Different blast surfaces,
> same "survive a bad day" intent.

## What you build

Two read-only capabilities, each a clean `1 script + 1 step file + 1 route` unit:

- `health.py` — nodes Ready, etcd quorum, control-plane pods, Talos services.
- `reliability.py` — per-workload: missing probes, single-replica-with-no-PDB,
  missing resource limits.

## Why it matters (enterprise / audit / agentic)

- **Evidence-grounded, not vibes.** Each finding is produced from a raw API read the
  script shows you. The LLM reasons over the script's output; it never free-hands a
  judgement about the cluster. That's what makes findings *auditable*.
- **Findings double as CI gates.** Each script's exit code = its finding count, so
  the same capability a human invokes conversationally can run unattended in a
  pipeline. Zero new code to "productionize" it.
- **Health vs reliability is the substrate/tenant split** an enterprise platform team
  already thinks in: the platform SRE owns etcd; the app team owns probes/PDBs. The
  agent speaks to both.

## What to start

Chapter 1 lab up (`admin@ops`, `admin@workload-1/2/3` reachable). Deploy the lab's
fault workloads so reliability has something real to find:

```bash
kubectl --context admin@workload-1 apply -f spikes/talos-gitops/lab/fault-workloads.yaml
```

## How to do it

```bash
# substrate health (expect 0 findings on a fresh lab cluster)
python3 .claude/skills/talos-sre/scripts/health.py      --cluster admin@ops

# tenant reliability (expect findings against the fault workloads)
python3 .claude/skills/talos-sre/scripts/reliability.py --cluster admin@workload-1
```

Implementation notes the chapter should teach:

- Both scripts construct a guarded `Cluster` handle from `kube.py`; every read goes
  through the read-only allow-list and is printed first.
- `reliability.py` skips platform namespaces (`kube-system`, `argocd`, `gitea`) and
  reasons over Deployment/StatefulSet specs in JSON — probes/limits/replicas are
  structural facts, not guesses.
- The single-replica-**and**-no-PDB finding is the headline reliability risk (a node
  drain becomes an outage) and is the one Chapter 5 remediates end-to-end.

## What is what (artifact map)

| Path | Role |
|---|---|
| `.claude/skills/talos-sre/scripts/health.py` | substrate health sweep |
| `.claude/skills/talos-sre/scripts/reliability.py` | workload reliability review |
| `.claude/skills/talos-sre/scripts/kube.py` | read-only wrappers + `Findings` (shared) |
| `.claude/skills/talos-sre/references/steps/step-01-health.md` | health runbook |
| `.claude/skills/talos-sre/references/steps/step-02-reliability.md` | reliability runbook |
| `spikes/talos-gitops/lab/fault-workloads.yaml` | intentional drift to detect |

## Verify (observed on the live lab)

- `health.py --cluster admin@workload-1` → **0 findings** (cluster healthy by design).
- `reliability.py --cluster admin@workload-1` → **7 findings**: `demo/web` (no
  liveness, no readiness, no limits, single-replica/no-PDB) + `demo/cache`
  (no liveness, no readiness, single-replica/no-PDB).

## Status (built vs verified)

- **Built & verified live:** both scripts run against the lab and produce the
  findings above. Exit-code-as-finding-count confirmed.
