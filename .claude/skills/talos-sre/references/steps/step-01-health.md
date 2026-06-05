# Step 01: Cluster health

Use when the user asks if a cluster is healthy, about nodes/etcd/control-plane,
or "what's wrong with {cluster}".

## Show the command, then run

```bash
python3 .claude/skills/talos-sre/scripts/health.py --cluster {cluster}
```

The script (read-only) checks, echoing every `kubectl`/`talosctl` call:

1. **Nodes** — all `Ready` (parses `kubectl get nodes -o json`).
2. **etcd** — `talosctl etcd status` answers with a healthy member.
3. **Control-plane pods** — everything in `kube-system` `Running`/`Succeeded`.
4. **Talos services** — `etcd` / `kubelet` / `apid` health.

## Summarize

- Exit code = number of findings (0 = healthy). Lead with that.
- For each finding, quote the evidence line the script printed.
- If etcd failed, that's the headline — the control plane is degraded.

## Failure modes

- `cluster context not found` → preflight should have caught it; the lab may be down.
- etcd query fails but nodes are Ready → likely a transient apiserver restart;
  re-run once before declaring degraded.
