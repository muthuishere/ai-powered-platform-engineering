#!/usr/bin/env python3
"""
security_drift.py — Chapter 4: security drift.

Read-only scan for postures that drift in real clusters: privileged containers,
runAsNonRoot not enforced, host namespace / hostPath use, and namespaces with no
NetworkPolicy. Findings cite the offending pod/namespace. Exits with the count.

    python3 security_drift.py --cluster admin@dev
"""
from __future__ import annotations

import argparse
import json
import sys
from pathlib import Path

sys.path.insert(0, str(Path(__file__).parent))
from kube import Cluster, Findings, section, set_json_mode  # noqa: E402

SKIP_NS = {"kube-system", "kube-public", "kube-node-lease"}


def main() -> None:
    p = argparse.ArgumentParser(description="Security drift scan")
    p.add_argument("--cluster", help="cluster name or context (dev/staging/prod/...); default dev")
    p.add_argument("--json", action="store_true", help="emit findings as a JSON bundle")
    args = p.parse_args()
    c = Cluster(args.cluster)
    set_json_mode(args.json)
    f = Findings(c.ctx, "security")

    pods = json.loads(c.kubectl("get", "pods", "-A", "-o", "json").stdout or '{"items":[]}')["items"]
    user_pods = [p for p in pods if p["metadata"]["namespace"] not in SKIP_NS]

    section("PRIVILEGED containers")
    found = False
    for pod in user_pods:
        for ct in pod["spec"]["containers"]:
            if ct.get("securityContext", {}).get("privileged") is True:
                found = True
                f.add(f'privileged: {pod["metadata"]["namespace"]}/{pod["metadata"]["name"]} [{ct["name"]}]',
                      severity="high", evidence="securityContext.privileged=true (≈ root on the node)")
    if not found:
        f.ok("no privileged containers in user namespaces")

    section("runAsNonRoot not enforced")
    found = False
    for pod in user_pods:
        pod_sc = pod["spec"].get("securityContext", {})
        pod_nonroot = pod_sc.get("runAsNonRoot") is True
        ctr_all_nonroot = all(ct.get("securityContext", {}).get("runAsNonRoot") is True
                              for ct in pod["spec"]["containers"])
        if not (pod_nonroot or ctr_all_nonroot):
            found = True
            f.add(f'runAsNonRoot not enforced: {pod["metadata"]["namespace"]}/{pod["metadata"]["name"]}')
    if not found:
        f.ok("all user pods enforce runAsNonRoot")

    section("host namespace / hostPath use")
    found = False
    for pod in user_pods:
        spec = pod["spec"]
        host = spec.get("hostNetwork") or spec.get("hostPID") or \
            any("hostPath" in v for v in spec.get("volumes", []))
        if host:
            found = True
            f.add(f'host ns/path: {pod["metadata"]["namespace"]}/{pod["metadata"]["name"]}',
                  severity="high", evidence="hostNetwork/hostPID/hostPath in use")
    if not found:
        f.ok("no hostNetwork/hostPID/hostPath in user pods")

    section("Namespaces WITHOUT a NetworkPolicy")
    ns_list = [l for l in c.kout("get", "ns", "-o", "name", quiet=True).splitlines()]
    for nsname in (n.replace("namespace/", "") for n in ns_list):
        if nsname in SKIP_NS or nsname == "default":
            continue
        n = len([l for l in c.kout("get", "netpol", "-n", nsname, "--no-headers", quiet=True).splitlines() if l.strip()])
        if n == 0:
            f.add(f"namespace '{nsname}' has 0 NetworkPolicies (flat network)", severity="low")
        else:
            f.ok(f"{nsname}: {n} NetworkPolicy")

    f.exit(as_json=args.json)


if __name__ == "__main__":
    main()
