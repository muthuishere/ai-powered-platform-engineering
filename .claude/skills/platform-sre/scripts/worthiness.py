#!/usr/bin/env python3
"""
worthiness.py — Chapter 7: "is this even a Kubernetes workload?"

A read-only advisory. Kubernetes is overhead you should only pay when you need
real scale — independent telemetry (CAST AI) shows clusters routinely run at
~8% CPU / ~20% memory because most workloads don't need k8s elasticity. A
common, sourced heuristic: below roughly **15–20 distinct services**, with no
real scale-variability, the operational overhead of k8s usually isn't worth it —
ECS Fargate / Cloud Run / Azure Container Apps cost far less to run.

This capability counts the signals and gives an HONEST advisory (a heuristic, not
a law): service/workload count, autoscaling presence, and replica scale. It never
tells you to leave k8s — it tells you to *ask the question* with evidence.

Same guardrails: ask-which-cluster (default dev), read-only, show-every-command.
`--json` emits the verdict. Exits 0 (advisory, not a gate).

    python3 worthiness.py --cluster dev [--threshold 15] [--json]
"""
from __future__ import annotations

import argparse
import json
import sys
from pathlib import Path

sys.path.insert(0, str(Path(__file__).parent))
from kube import Cluster, section, set_json_mode, _human  # noqa: E402

SKIP_NS = {"kube-system", "kube-public", "kube-node-lease", "argocd", "gitea",
           "cert-manager", "ingress-nginx", "monitoring"}


def main() -> None:
    p = argparse.ArgumentParser(description="Kubernetes-worthiness advisory")
    p.add_argument("--cluster", help="cluster name or context (dev/staging/prod/...); default dev")
    p.add_argument("--threshold", type=int, default=15,
                   help="services below which k8s overhead is questioned (sourced: ~15-20)")
    p.add_argument("--json", action="store_true", help="emit the verdict as JSON")
    args = p.parse_args()
    c = Cluster(args.cluster)
    set_json_mode(args.json)

    workloads = json.loads(c.kubectl("get", "deploy,statefulset", "-A", "-o", "json").stdout
                           or '{"items":[]}')["items"]
    user_wl = [w for w in workloads if w["metadata"]["namespace"] not in SKIP_NS]
    svcs = json.loads(c.kubectl("get", "svc", "-A", "-o", "json").stdout or '{"items":[]}')["items"]
    user_svcs = [s for s in svcs if s["metadata"]["namespace"] not in SKIP_NS
                 and s["spec"].get("type") != "ExternalName"]
    hpas = json.loads(c.kubectl("get", "hpa", "-A", "-o", "json").stdout or '{"items":[]}')["items"]
    max_replicas = max([w["spec"].get("replicas", 1) for w in user_wl], default=0)

    n_wl, n_svc, n_hpa = len(user_wl), len(user_svcs), len(hpas)

    section("KUBERNETES-WORTHINESS SIGNALS")
    _human(f"  user workloads: {n_wl}   services: {n_svc}   HPAs (autoscaling): {n_hpa}   "
           f"max replicas on any workload: {max_replicas}")

    scale_signal = n_hpa > 0 or max_replicas >= 3
    worthy = n_svc >= args.threshold or scale_signal

    verdict = {
        "cluster": c.ctx,
        "workloads": n_wl, "services": n_svc, "hpas": n_hpa, "max_replicas": max_replicas,
        "threshold": args.threshold,
        "scale_variability": scale_signal,
        "verdict": "k8s-justified" if worthy else "questionable",
    }

    section("VERDICT (advisory — a heuristic, not a law)")
    if args.json:
        print(json.dumps(verdict, indent=2))
        sys.exit(0)

    if worthy:
        reason = []
        if n_svc >= args.threshold:
            reason.append(f"{n_svc} services (≥ {args.threshold})")
        if n_hpa > 0:
            reason.append(f"{n_hpa} HPA(s)")
        if max_replicas >= 3:
            reason.append(f"a workload at {max_replicas} replicas")
        _human(f"  ok Kubernetes looks justified here — {', '.join(reason)}.")
        _human("     You're using the elasticity/scale primitives k8s exists for.")
    else:
        _human(f"  !! Questionable: only {n_svc} service(s), no autoscaling, max {max_replicas} "
               f"replica(s) — below the ~{args.threshold}-service heuristic and no scale-variability.")
        _human("     Consider whether ECS Fargate / Cloud Run / Azure Container Apps would")
        _human("     deliver this with far less operational overhead. k8s is always overhead;")
        _human("     pay it when you need the scale, not because it's the default.")
        _human("     (Heuristic only — isolation, multi-tenancy, or portability can still justify k8s.)")
    sys.exit(0)


if __name__ == "__main__":
    main()
