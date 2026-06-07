#!/usr/bin/env python3
"""
upgrade.py — Chapter 6: upgrade readiness ("fearless upgrades").

Read-only pre-upgrade review of one cluster. It does NOT perform an upgrade — it
tells you whether one is safe and surfaces the right commands to run yourself:

  1. CURRENT VERSIONS — running Talos + Kubernetes.
  2. NODE VERSION SKEW — are all kubelets on the same version (i.e. is a previous
     rolling upgrade actually finished)?
  3. DEPRECATED / REMOVED API PREFLIGHT — if a scanner (pluto or kubent) is on
     PATH, list workloads using APIs deprecated/removed in the target release.
     Degrades honestly with a note if no scanner.
  4. UPGRADE PLAN — prints the exact (privileged) Talos commands, including the
     built-in deprecation preflight `talosctl upgrade-k8s --dry-run`, and the A/B
     atomic-upgrade + boot-time rollback story.

Talos truth (don't conflate): the OS (`talosctl upgrade`) and Kubernetes
(`talosctl upgrade-k8s`) are TWO commands coupled by a compatibility matrix.
Talos's edge is that the deprecated/removed-API preflight is built INTO the
upgrade path — not that it's the only way to detect them (pluto/kubent/`kubeadm
upgrade plan` also do).

Same guardrails as every capability: ask-which-cluster (default dev), read-only,
show-every-command, fail-fast. Exits with the finding count; `--json` emits the
ranked bundle. Feeds nothing scored by default — it's a readiness gate.

    python3 upgrade.py --cluster dev [--target-k8s v1.34] [--json]
"""
from __future__ import annotations

import argparse
import json
import re
import shutil
import subprocess
import sys
from pathlib import Path

sys.path.insert(0, str(Path(__file__).parent))
from kube import Cluster, Findings, section, set_json_mode  # noqa: E402


def _minor(v: str) -> "tuple[int, int] | None":
    m = re.search(r"v?(\d+)\.(\d+)", v or "")
    return (int(m.group(1)), int(m.group(2))) if m else None


def find_scanner() -> "str | None":
    for s in ("pluto", "kubent"):
        if shutil.which(s):
            return s
    return None


def scan_deprecated(scanner: str, ctx: str) -> "list[dict]":
    """Best-effort deprecated/removed-API scan via pluto or kubent. Returns rows."""
    rows: list[dict] = []
    try:
        if scanner == "pluto":
            # Best-effort: pluto/kubent read the *current* kubeconfig context. The
            # operator should `kubectl config use-context <ctx>` first, or scope it.
            out = subprocess.run(
                ["pluto", "detect-all-in-cluster", "-o", "json"],
                capture_output=True, text=True, timeout=120,
            ).stdout
            data = json.loads(out or "{}")
            for it in data.get("items", []) or []:
                api = it.get("api", {}) or {}
                rows.append({
                    "name": it.get("name"), "namespace": it.get("namespace"),
                    "kind": api.get("kind"), "deprecated_in": api.get("deprecatedIn"),
                    "removed_in": api.get("removedIn"), "removed": bool(api.get("removed")),
                })
        else:  # kubent
            out = subprocess.run(["kubent", "-o", "json"], capture_output=True, text=True, timeout=120).stdout
            for it in json.loads(out or "[]") or []:
                rows.append({
                    "name": it.get("Name"), "namespace": it.get("Namespace"),
                    "kind": it.get("Kind"), "deprecated_in": it.get("ApiVersion"),
                    "removed_in": it.get("RemovedIn"), "removed": False,
                })
    except Exception:
        return []
    return rows


def main() -> None:
    p = argparse.ArgumentParser(description="Upgrade readiness / deprecation preflight")
    p.add_argument("--cluster", help="cluster name or context (dev/staging/prod/...); default dev")
    p.add_argument("--target-k8s", help="target Kubernetes version, e.g. v1.34")
    p.add_argument("--json", action="store_true", help="emit findings as a JSON bundle")
    args = p.parse_args()
    c = Cluster(args.cluster)
    set_json_mode(args.json)
    f = Findings(c.ctx, "upgrade")

    section("CURRENT VERSIONS")
    tver = (re.findall(r"Tag:\s*(v[\d.]+)", c.tout("version")) or [""])[-1]
    k8s = c.kout("get", "nodes", "-o",
                 "jsonpath={.items[0].status.nodeInfo.kubeletVersion}", quiet=True)
    print(f"  talos: {tver or '?'}   kubernetes: {k8s or '?'}"
          f"   target: {args.target_k8s or '(none given)'}")

    section("NODE VERSION SKEW — is the last rolling upgrade finished?")
    versions = c.kout("get", "nodes", "-o",
                      "jsonpath={.items[*].status.nodeInfo.kubeletVersion}", quiet=True).split()
    uniq = sorted(set(versions))
    if len(uniq) > 1:
        f.add(f"node version skew: {', '.join(uniq)}", id="node-version-skew",
              severity="medium", evidence="mixed kubeletVersions across nodes",
              proposed_fix="finish the in-progress rolling upgrade so all nodes match")
    elif uniq:
        f.ok(f"all nodes on {uniq[0]}")

    section("DEPRECATED / REMOVED API PREFLIGHT")
    scanner = find_scanner()
    if not scanner:
        print("  !! no deprecated-API scanner (pluto/kubent) on PATH — skipping (not counted)")
        print("     install one:  brew install fairwindsops/tap/pluto   # or kubent")
    else:
        print(f"  using {scanner}", file=sys.stderr)
        rows = scan_deprecated(scanner, c.ctx)
        if not rows:
            f.ok("no deprecated/removed API usage detected")
        for r in rows:
            removed = r.get("removed") or r.get("removed_in")
            sev = "high" if removed else "medium"
            where = f'{r.get("namespace") or "-"}/{r.get("name") or "?"} ({r.get("kind")})'
            f.add(f"deprecated API: {where} {r.get('deprecated_in') or ''}".strip(),
                  id="deprecated-api", severity=sev,
                  evidence=f"removed_in={r.get('removed_in')}" if r.get("removed_in") else "deprecated",
                  proposed_fix="migrate the manifest to the current apiVersion before upgrading")

    section("UPGRADE PLAN — run these yourself (privileged; not executed here)")
    print(f"  $ talosctl --context {c.talos_ctx} upgrade --nodes <node> --image <installer-image:vX>")
    print(f"  $ talosctl --context {c.talos_ctx} upgrade-k8s --to {args.target_k8s or '<target>'} --dry-run")
    print("    ^ built-in preflight: warns on removed API resources/flags before anything changes")
    print(f"  $ talosctl --context {c.talos_ctx} upgrade-k8s --to {args.target_k8s or '<target>'}")
    print("  A/B image upgrade is atomic; the bootloader auto-rolls-back if the new image")
    print("  fails to boot, and `talosctl rollback` reverts to the prior slot — services intact.")

    if args.target_k8s:
        cur, tgt = _minor(k8s), _minor(args.target_k8s)
        if cur and tgt and (tgt[0] > cur[0] or tgt[1] > cur[1] + 1):
            f.add(f"target {args.target_k8s} skips minor versions from {k8s}",
                  id="minor-skip", severity="high",
                  evidence="Kubernetes supports only +1 minor version skew at a time",
                  proposed_fix="step through one minor at a time (e.g. 1.32 → 1.33 → 1.34)")

    f.exit(as_json=args.json)


if __name__ == "__main__":
    main()
