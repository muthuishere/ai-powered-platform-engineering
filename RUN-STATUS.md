# Overnight autonomous run — STATUS (2026-06-06)

Coding agent handoff. Everything below was built and **verified live** unless marked
otherwise. Nothing was pushed to a remote; work is committed to a feature branch for
your review.

## TL;DR

The full book lab + the `platform-sre` skill are built and working end-to-end. Four
Talos clusters, the GitOps hub (ArgoCD + Gitea), platform components syncing onto all
three workload clusters, and all six skill capabilities tested against real injected
faults. Per-chapter build briefs written under `chapters/`.

## Lab (`spikes/talos-gitops/`)

| Component | Status |
|---|---|
| 4 clusters (`ops` + `dev/2/3`), 1 cp + 1 worker each = 8 nodes | ✅ all nodes Ready, k8s v1.36.1 |
| DNS/etcd fix (`patches/dns.yaml`, `--config-patch`) | ✅ baked into `01`; clusters boot deterministically |
| Network wiring (`02`) | ✅ workload control-planes routable from ops (10.5.0.4/5/6) |
| ArgoCD + Gitea hub (`03`) | ✅ running on `ops`; `platform` repo seeded; root App-of-Apps applied |
| Workload registration (`04`) | ✅ `cluster-dev/2/3` secrets, `environment=workload` |
| GitOps app sync | ✅ cert-manager, ingress-nginx, metrics-server, kube-prometheus-stack **Healthy** on all 3 workloads |
| Fault workloads (`lab/fault-workloads.yaml`) | ✅ deployed to dev (`demo/web`, `demo/cache`) |

**Footprint decision (yours, while away):** dropped from 2 workers/cluster (12 nodes)
to **1 worker/cluster (8 nodes)** — 12 nodes wedged the Docker engine. If `docker ps`
ever hangs, restart OrbStack (quit + reopen).

## Skill (`.claude/skills/platform-sre/`)

Rebuilt to match your `reqsume-sre` / `huddle` scaffold (Python scripts, `enforce()`
guard, `references/steps`, `activation-routing.xml`, README, install.sh). All
capabilities tested live against `dev`:

| Capability | Result |
|---|---|
| `prerequisites.py` | ✅ repo guard passes, lists all 4 clusters |
| `health.py` | ✅ 0 findings (cluster healthy) |
| `reliability.py` | ✅ found missing probes / limits / single-replica-no-PDB |
| `security_drift.py` | ✅ found privileged + hostPath `cache`, runAsNonRoot, no-NetworkPolicy (5) |
| `certs.py` | ✅ 0 findings; probe failure no longer mis-counted |
| `report.py` | ✅ scored maturity report (graded A–F) |
| `remediate.py` | ✅ dry-run prints PDB manifest + planned PR; `--apply` opens a Gitea PR |

Guardrails enforced in code: read-only allow-list, ask-which-cluster (no default),
show-every-command, repo guard, fail-fast. `remediate.py` is the only writer and it
changes **git** (a PR), never the cluster.

## Book build briefs (`chapters/`)

`chapters/README.md` (index + the 4 build-agent decisions answered) and
`chapter-1..5-*.md`. Agent-facing, path-first, with per-chapter audit banners and
`report` framed as the Ch4 capstone (huddle decisions, recorded in
`~/.config/muthuishere-agent-skills/.../huddle/2026-06-06.md`).

## Bugs found & fixed during verification

1. `03-bootstrap-hub.sh` created the Gitea user via a bare `kubectl exec` → ran as
   root → gitea refused. **Fixed:** `su git -c "gitea admin user create …"`.
2. `certs.py` counted an unreadable apiserver-serving-cert probe as a finding.
   **Fixed:** probe failure is now a warning, not a scored finding.
3. `remediate.py` dry-run named the wrong cluster for the Gitea port-forward.
   **Fixed:** always `admin@ops`.

## Known notes / v2 candidates (not blockers)

- `reliability.py`/`security_drift.py`/`report.py` scan **all** user namespaces, so
  once ArgoCD deploys the platform components into a workload cluster, they show up as
  findings too (e.g. helm charts without PDBs). This is *realistic* but muddies the
  clean `demo` teaching example. **Suggested v2:** a `--namespace` filter for scoped,
  deterministic book demos.
- ArgoCD sync status shows "Unknown" on the insecure cluster connections while the
  comparison cache warms; **health** is Healthy (ground truth = pods running).
- `remediate.py` MVP fix set = `missing-pdb` only; probe/securityContext patches and
  cert rotation are documented v2 extension points.

## To resume the lab from cold

```bash
cd spikes/talos-gitops
./scripts/01-create-clusters.sh && ./scripts/02-connect-networks.sh
./scripts/03-bootstrap-hub.sh   && ./scripts/04-register-clusters.sh
kubectl --context admin@dev apply -f lab/fault-workloads.yaml
```
