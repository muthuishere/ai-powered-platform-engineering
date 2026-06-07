#!/usr/bin/env python3
"""
reliability.py — Chapter 3: reliability review.

Scans Deployments/StatefulSets in user namespaces for the classic SRE gaps:
missing liveness/readiness probes, single replica with no PodDisruptionBudget,
and no resource limits. Read-only; each finding cites the workload. Exits with
the finding count.

    python3 reliability.py --cluster admin@dev
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

    # PDBs per namespace, parsed so we can MATCH selectors against a workload's
    # pod labels (a PDB only protects a workload its selector actually covers).
    pdb_ns: dict[str, list] = {}
    for w in workloads:
        ns = w["metadata"]["namespace"]
        if ns not in pdb_ns:
            raw_pdb = c.kubectl("get", "pdb", "-n", ns, "-o", "json", quiet=True).stdout
            try:
                pdb_ns[ns] = json.loads(raw_pdb or '{"items":[]}')["items"]
            except Exception:
                pdb_ns[ns] = []

    def pdb_covers(ns: str, pod_labels: dict) -> bool:
        """True iff some PDB in ns has a selector that matches the pod labels."""
        for pdb in pdb_ns.get(ns, []):
            sel = (pdb.get("spec") or {}).get("selector") or {}
            match_labels = sel.get("matchLabels") or {}
            match_exprs = sel.get("matchExpressions") or []
            # An empty selector ({}) matches everything; a missing selector matches nothing.
            if not match_labels and not match_exprs and "selector" in (pdb.get("spec") or {}):
                return True
            if all(pod_labels.get(k) == v for k, v in match_labels.items()) and \
               _exprs_match(match_exprs, pod_labels) and (match_labels or match_exprs):
                return True
        return False

    def _exprs_match(exprs: list, labels: dict) -> bool:
        for e in exprs:
            key, op, vals = e.get("key"), e.get("operator"), e.get("values") or []
            present = key in labels
            if op == "In" and labels.get(key) not in vals:
                return False
            if op == "NotIn" and labels.get(key) in vals:
                return False
            if op == "Exists" and not present:
                return False
            if op == "DoesNotExist" and present:
                return False
        return True

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

        pod_labels = (spec["template"]["metadata"].get("labels") or {})
        if replicas <= 1:
            if not pdb_covers(ns, pod_labels):
                n_pdb = len(pdb_ns.get(ns, []))
                detail = (f"{n_pdb} PDB(s) in ns {ns} but none whose selector matches this workload's "
                          f"pod labels {pod_labels}") if n_pdb else f"0 PDBs in ns {ns}"
                f.add(f"{ns}/{name}: single replica AND no PodDisruptionBudget covering it (node drain = outage)",
                      severity="high",
                      evidence=f"{kind}/{name} replicas<=1 and {detail}",
                      proposed_fix="add a PodDisruptionBudget (minAvailable: 1) whose selector matches this workload — see remediate.py --fix missing-pdb")
            else:
                f.ok(f"single replica but a PDB selector covers {name} in {ns}")
        else:
            f.ok(f"replicas={replicas} (HA)")

    f.exit(as_json=args.json)


if __name__ == "__main__":
    main()
