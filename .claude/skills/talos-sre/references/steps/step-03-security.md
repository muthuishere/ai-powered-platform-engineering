# Step 03: Security drift

Use when the user asks for a security review, or about privileged pods, root,
hostPath/hostNetwork, NetworkPolicies, or "is this hardened".

## Show the command, then run

```bash
python3 .claude/skills/talos-sre/scripts/security_drift.py --cluster {cluster}
```

Read-only scan over user-namespace pods:

- `privileged: true` containers
- `runAsNonRoot` not enforced (neither pod nor all containers set it)
- `hostNetwork` / `hostPID` / `hostPath` volume use
- namespaces with **zero** NetworkPolicies (flat network)

## Summarize

- Exit code = finding count.
- Privileged + root are the highest severity — lead with them.
- A namespace with no NetworkPolicy is a posture finding, not an active exploit;
  frame accordingly.

## Notes

- kube-system / kube-public / kube-node-lease are intentionally skipped — their
  components legitimately need elevated access.
