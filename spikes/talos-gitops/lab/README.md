# Lab fault-injection

Workloads with **intentional** drift so the `platform-sre` skill's read-only
capabilities (book Ch3-4) have real findings to surface. They deploy cleanly —
pods go Ready, the cluster stays healthy — the drift is in their *spec*.

## Apply (to a workload cluster, not ops)

```bash
kubectl --context admin@dev apply -f spikes/talos-gitops/lab/fault-workloads.yaml
```

## What each capability should then find

| Capability | Finding |
|---|---|
| `reliability.py` | `demo/web`: no livenessProbe, no readinessProbe, no resource limits, single replica + no PDB |
| `security_drift.py` | `demo/web`: runAsNonRoot not enforced; `demo/cache`: privileged + hostPath; namespace `demo`: 0 NetworkPolicies |
| `health.py` | nothing — the cluster is healthy by design |

## Remediate (Ch5)

The single-replica/no-PDB finding is fixable end-to-end:

```bash
# start the Gitea tunnel first (see platform-sre step-06)
python3 .claude/skills/platform-sre/scripts/remediate.py \
  --cluster admin@dev --fix missing-pdb --namespace demo --workload web --apply
```

## Clean up

```bash
kubectl --context admin@dev delete -f spikes/talos-gitops/lab/fault-workloads.yaml
```
