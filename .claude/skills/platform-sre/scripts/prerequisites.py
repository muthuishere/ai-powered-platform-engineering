#!/usr/bin/env python3
"""
prerequisites.py — guard rail for the platform-sre skill.

platform-sre is a read-only SRE skill for Kubernetes clusters on Talos Linux. It
is designed to run against ANY cluster a team owns — the local Docker lab in this
book, or a real organisation's dev / staging / prod. So the guard here is about
the *cluster*, not a repository:

  1. The required CLI binaries are on PATH.
  2. The requested cluster resolves to a real, known context (the cluster guard).
     There is NO repo guard — this skill is not tied to one checkout.

Cluster resolution (book Chapter 2):
  * The request may name a cluster (`dev`, `staging`, `prod`, or any literal
    kube-context). We accept the bare name or its `admin@<name>` form.
  * If nothing is named, we DEFAULT TO `dev` — never to the kubeconfig's current
    context, which might be production from an hour ago.
  * An unknown name is a refusal, not a guess.

Every capability script calls `enforce(cluster)` (or resolves via `kube.Cluster`)
as its first action.

Standalone usage:
    python3 prerequisites.py
    python3 prerequisites.py --cluster dev
    python3 prerequisites.py --cluster staging --extra-binary helm
"""
from __future__ import annotations

import argparse
import shutil
import subprocess
import sys
from typing import Optional

# kubectl/talosctl for cluster reads, python3 for the scripts. git/gh/helm are
# required only by remediate — passed via extra_binaries.
REQUIRED_BINARIES = ["kubectl", "talosctl", "python3"]

# The book's canonical clusters. These are the DEFAULT vocabulary, not a fence —
# any context that exists in kubeconfig is accepted (a real org names its own).
KNOWN_CLUSTERS = ["dev", "staging", "prod"]
DEFAULT_CLUSTER = "dev"

_INSTALL_HINTS = {
    "kubectl": "macOS: `brew install kubernetes-cli`",
    "talosctl": "macOS: `brew install siderolabs/tap/talosctl`",
    "python3": "macOS: `brew install python` (3.11+)",
    "helm": "macOS: `brew install helm`",
    "git": "macOS: `xcode-select --install` or `brew install git`",
    "gh": "macOS: `brew install gh`",
    "jq": "macOS: `brew install jq`",
}


def _die(msg: str) -> None:
    print(f"platform-sre prerequisite failed: {msg}", file=sys.stderr)
    sys.exit(2)


def check_binaries(extra: Optional[list[str]] = None) -> None:
    needed = list(REQUIRED_BINARIES) + list(extra or [])
    missing = [b for b in needed if shutil.which(b) is None]
    if missing:
        lines = [f"missing required CLI(s) on PATH: {', '.join(missing)}", ""]
        for b in missing:
            hint = _INSTALL_HINTS.get(b, "")
            lines.append(f"  - {b}{(' - ' + hint) if hint else ''}")
        _die("\n".join(lines))


def all_contexts() -> list[str]:
    """Every context in the kubeconfig (the org's real cluster registry)."""
    try:
        out = subprocess.run(["kubectl", "config", "get-contexts", "-o", "name"],
                             check=True, capture_output=True, text=True).stdout
    except (FileNotFoundError, subprocess.CalledProcessError):
        return []
    return [c for c in out.splitlines() if c.strip()]


def resolve_cluster(requested: Optional[str]) -> str:
    """
    Resolve a cluster request to a real kube context, per the book's rules:
      * a named request resolves by exact match, then `admin@<name>`;
      * no request -> DEFAULT to `dev` (never the current context);
      * unknown -> refuse with the available list.
    """
    contexts = all_contexts()
    if not contexts:
        _die("no kube contexts found. Is the lab up? "
             "(spikes/talos-gitops/scripts/01-create-clusters.sh)")

    candidates = [requested] if requested else [DEFAULT_CLUSTER]
    for name in candidates:
        for form in (name, f"admin@{name}"):
            if form in contexts:
                if not requested:
                    print(f"no cluster given — defaulting to '{form}' "
                          f"(never the current context)", file=sys.stderr)
                return form

    if requested:
        menu = "\n".join(f"  - {c}" for c in contexts)
        _die(f"unknown cluster '{requested}'. Known contexts:\n{menu}")
    _die(f"no cluster given and no '{DEFAULT_CLUSTER}' context exists. "
         f"Pass --cluster <context>. Available:\n" +
         "\n".join(f"  - {c}" for c in contexts))
    raise AssertionError("unreachable")


def enforce(cluster: Optional[str] = None, *,
            extra_binaries: Optional[list[str]] = None) -> str:
    """
    Single entry point used by every capability script.
      * Always: required binaries on PATH.
      * Always: resolve + validate the cluster context (the cluster guard).
    Returns the resolved kube context (e.g. `admin@dev`).
    """
    check_binaries(extra=extra_binaries)
    return resolve_cluster(cluster)


def main() -> None:
    p = argparse.ArgumentParser(description="platform-sre prerequisite check")
    p.add_argument("--cluster", help="cluster name or context (dev/staging/prod/...)")
    p.add_argument("--extra-binary", action="append", default=[],
                   help="Additional binary to require (repeat).")
    args = p.parse_args()
    ctx = enforce(cluster=args.cluster, extra_binaries=args.extra_binary)
    print("platform-sre prerequisites OK")
    print(f"  binaries: {', '.join(REQUIRED_BINARIES + args.extra_binary)}")
    print(f"  cluster:  {ctx} (context exists — cluster guard passed)")
    print("  contexts known to kubeconfig:")
    for c in all_contexts():
        print(f"    - {c}")


if __name__ == "__main__":
    main()
