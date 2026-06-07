# Step 08: Upgrade readiness (fearless upgrades)

Use when the user asks "can we upgrade", about version skew, deprecated APIs, or
Talos/Kubernetes upgrades.

## Show the command, then run

```bash
python3 .claude/skills/platform-sre/scripts/upgrade.py --cluster {cluster} [--target-k8s vX.Y]
```

Read-only. It reports current Talos + Kubernetes versions, flags **node version
skew** (an unfinished rolling upgrade), runs a **deprecated/removed-API preflight**
if `pluto` or `kubent` is on PATH (skips with a note otherwise — not a finding),
and prints the **privileged upgrade plan** it does *not* execute:
`talosctl upgrade` (OS) and `talosctl upgrade-k8s --to … --dry-run` (the built-in
deprecation preflight), then the real `upgrade-k8s`.

## Summarize

- Lead with deprecated/removed APIs (high if removed in the target) and version skew.
- Explain the Talos safety net: **two coupled commands** (OS vs k8s, compatibility
  matrix), **A/B atomic upgrade**, **automatic boot-time rollback**, `talosctl rollback`.
- The agent never runs the upgrade — that's a privileged human step (and it ships via
  GitOps where the cluster state is declared).

## Notes

- `--target-k8s` flags a finding if it skips more than one minor (k8s allows +1 skew).
- Install a scanner for the preflight: `brew install fairwindsops/tap/pluto` (or kubent).
