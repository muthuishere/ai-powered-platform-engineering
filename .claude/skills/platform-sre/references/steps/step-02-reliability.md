# Step 02: Reliability review

Use when the user asks about probes, replicas, HA, PDBs, resource limits, or
"will this survive a node drain".

## Show the command, then run

```bash
python3 .claude/skills/platform-sre/scripts/reliability.py --cluster {cluster}
```

Scans Deployments/StatefulSets in **user** namespaces (skips kube-system, argocd,
gitea). Per workload it flags:

- no `livenessProbe` / no `readinessProbe`
- a container with no resource `limits`
- `replicas <= 1` **and** no PodDisruptionBudget in the namespace (a node drain
  becomes an outage)

## Summarize

- Exit code = finding count.
- Group by workload; for single-replica/no-PDB, note that this is the highest-impact
  reliability gap and is directly remediable (route to `step-06-remediate.md`,
  `--fix missing-pdb`).

## Notes

- The PDB check is namespace-level (a proxy). If a PDB exists but may not select the
  workload, say so rather than asserting it's covered.
