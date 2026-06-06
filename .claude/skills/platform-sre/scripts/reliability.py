#!/usr/bin/env python3
"""
reliability.py — Chapter 3: reliability review.

Scans Deployments/StatefulSets in user namespaces for the classic SRE gaps:
missing liveness/readiness probes, single replica with no PodDisruptionBudget,
and no resource limits. Read-only; each finding cites the workload. Exits with
the finding count.

    python3 reliability.py --cluster admin@workload-1
"""
from __future__ import annotations

import argparse
import json
import sys
from pathlib import Path

sys.path.insert(0, str(Path(__file__).parent))
from kube import Cluster, Findings, section, set_json_mode  # noqa: E402

SKIP_NS = {"kube-system", "kube-public", "kube-node-lease", "argocd", "gitea"}


def main() -> None:
    p = argparse.ArgumentParser(description="Reliability review")
    p.add_argument("--cluster", help="cluster name or context (dev/staging/prod/...); default dev")
    p.add_argument("--json", action="store_true", help="emit findings as a JSON bundle")
    args = p.parse_args()
    c = Cluster(args.cluster)
    set_json_mode(args.json)
    f = Findings(c.ctx, "reliability")

    raw = c.kubectl("get", "deploy,statefulset", "-A", "-o", "json")
    items = json.loads(raw.stdout or '{"items":[]}')["items"]
    workloads = [w for w in items if w["metadata"]["namespace"] not in SKIP_NS]
    if not workloads:
        section("no user workloads found (deploy a lab app first).")
        f.exit(as_json=args.json)

    # PDB count per namespace (cheap proxy — a real impl would match selectors).
    pdb_ns: dict[str, int] = {}
    for w in workloads:
        ns = w["metadata"]["namespace"]
        if ns not in pdb_ns:
            out = c.kout("get", "pdb", "-n", ns, "--no-headers", quiet=True)
            pdb_ns[ns] = len([l for l in out.splitlines() if l.strip()])

    for w in workloads:
        ns = w["metadata"]["namespace"]
        kind = w["kind"]
        name = w["metadata"]["name"]
        section(f"{ns}/{kind} {name}")
        spec = w["spec"]
        replicas = spec.get("replicas", 1)
        containers = spec["template"]["spec"]["containers"]

        if not any("livenessProbe" in ct for ct in containers):
            f.add(f"{ns}/{name}: no livenessProbe")
        else:
            f.ok("livenessProbe present")
        if not any("readinessProbe" in ct for ct in containers):
            f.add(f"{ns}/{name}: no readinessProbe")
        else:
            f.ok("readinessProbe present")
        if not all((ct.get("resources", {}).get("limits")) for ct in containers):
            f.add(f"{ns}/{name}: missing resource limits on a container", severity="low")
        else:
            f.ok("resource limits present")

        if replicas <= 1:
            if pdb_ns.get(ns, 0) == 0:
                f.add(f"{ns}/{name}: single replica AND no PodDisruptionBudget (node drain = outage)",
                      severity="high",
                      evidence=f"{obj} replicas<=1 and 0 PDBs in ns {ns}",
                      proposed_fix="add a PodDisruptionBudget (minAvailable: 1) — see remediate.py --fix missing-pdb")
            else:
                f.ok(f"single replica but a PDB exists in {ns} (verify it selects this app)")
        else:
            f.ok(f"replicas={replicas} (HA)")

    f.exit(as_json=args.json)


if __name__ == "__main__":
    main()
