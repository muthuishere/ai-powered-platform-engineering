#!/usr/bin/env python3
"""
health.py — Chapter 3: cluster health.

Read-only health sweep of ONE cluster: nodes Ready, etcd quorum, control-plane
pods, Talos node services. Every check is backed by the command shown above it.
Exits with the number of findings (0 = healthy), so it doubles as a CI gate.

    python3 health.py --cluster admin@ops
"""
from __future__ import annotations

import argparse
import json
import sys
from pathlib import Path

sys.path.insert(0, str(Path(__file__).parent))
from kube import Cluster, Findings, section, set_json_mode  # noqa: E402


def main() -> None:
    p = argparse.ArgumentParser(description="Talos cluster health sweep")
    p.add_argument("--cluster", help="cluster name or context (dev/staging/prod/...); default dev")
    p.add_argument("--json", action="store_true", help="emit findings as a JSON bundle")
    args = p.parse_args()

    c = Cluster(args.cluster)
    set_json_mode(args.json)
    f = Findings(c.ctx, "operations")

    section("NODES — all should be Ready")
    nodes = c.kubectl("get", "nodes", "-o", "json")
    print(c.kout("get", "nodes", "-o", "wide", quiet=True))
    try:
        items = json.loads(nodes.stdout)["items"]
        notready = [n["metadata"]["name"] for n in items
                    if not any(cnd["type"] == "Ready" and cnd["status"] == "True"
                               for cnd in n["status"]["conditions"])]
        if notready:
            f.add(f"nodes not Ready: {', '.join(notready)}")
        else:
            f.ok(f"all {len(items)} nodes Ready")
    except Exception:
        f.add("could not parse node status")

    section("ETCD — members healthy")
    et = c.talosctl("etcd", "status")
    if et.returncode == 0 and et.stdout.strip():
        print(et.stdout.strip())
        f.ok("etcd answered")
    else:
        f.add("etcd status query failed — control plane may be degraded")

    section("CONTROL-PLANE PODS (kube-system)")
    cp = c.kubectl("get", "pods", "-n", "kube-system", "-o", "json")
    print(c.kout("get", "pods", "-n", "kube-system", quiet=True))
    try:
        bad = []
        for pod in json.loads(cp.stdout)["items"]:
            phase = pod["status"].get("phase", "?")
            if phase not in ("Running", "Succeeded"):
                bad.append(f'{pod["metadata"]["name"]}({phase})')
        if bad:
            f.add(f"control-plane pods not Running: {', '.join(bad)}")
        else:
            f.ok("control-plane pods Running")
    except Exception:
        f.add("could not parse kube-system pods")

    section("TALOS NODE SERVICES (etcd / kubelet / apid)")
    svc = c.tout("services")
    for line in svc.splitlines():
        if any(k in line for k in ("NODE", "etcd", "kubelet", "apid")):
            print(line)

    f.exit(as_json=args.json)


if __name__ == "__main__":
    main()
