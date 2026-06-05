#!/usr/bin/env python3
"""
prerequisites.py — guard rail for the talos-sre skill.

talos-sre operates on a specific Talos-on-Docker lab (clusters `ops` and
`workload-1/2/3`, provisioned by `spikes/talos-gitops/`). Running it from an
unrelated repo, or against an unknown cluster, would produce confused or wrong
results. This module hard-fails before any tool runs unless:

  1. The required CLI binaries are on PATH
  2. CWD is inside a git repo whose `origin` ends with the path component
     `/ai-powered-platform-engineering` (suffix match — forks pass)
  3. If a cluster is requested: that kube context exists in kubeconfig

Every capability script calls `enforce(cluster)` as its first action.

Standalone usage:
    python3 prerequisites.py
    python3 prerequisites.py --cluster admin@ops
    python3 prerequisites.py --cluster admin@ops --extra-binary helm
"""
from __future__ import annotations

import argparse
import re
import shutil
import subprocess
import sys
from pathlib import Path
from typing import Optional

# Repo guard: any owner, trailing path component must match. Forks pass.
EXPECTED_REPO_SUFFIX = "ai-powered-platform-engineering"

# git for the repo guard, kubectl/talosctl for cluster reads, python3 for the
# scripts. helm/git/gh are required only by remediate — passed via extra.
REQUIRED_BINARIES = ["git", "kubectl", "talosctl", "python3"]

_INSTALL_HINTS = {
    "git": "macOS: `xcode-select --install` or `brew install git`",
    "kubectl": "macOS: `brew install kubernetes-cli`",
    "talosctl": "macOS: `brew install siderolabs/tap/talosctl`",
    "python3": "macOS: `brew install python` (3.11+)",
    "helm": "macOS: `brew install helm`",
    "gh": "macOS: `brew install gh`",
    "jq": "macOS: `brew install jq`",
}


def _die(msg: str) -> None:
    print(f"talos-sre prerequisite failed: {msg}", file=sys.stderr)
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


def _run(cmd: list[str], cwd: Optional[Path] = None) -> str:
    try:
        out = subprocess.run(cmd, cwd=cwd, check=True, capture_output=True, text=True)
        return out.stdout.strip()
    except FileNotFoundError:
        _die(f"`{cmd[0]}` not found on PATH")
    except subprocess.CalledProcessError as e:
        _die(f"`{' '.join(cmd)}` failed: {e.stderr.strip() or e.stdout.strip()}")


def repo_root() -> Path:
    if shutil.which("git") is None:
        _die("git is not installed or not on PATH")
    return Path(_run(["git", "rev-parse", "--show-toplevel"]))


def _parse_owner_repo(remote_url: str) -> Optional[str]:
    m = re.match(r"git@[^:]+:([^/]+/[^/]+?)(?:\.git)?$", remote_url)
    if m:
        return m.group(1)
    m = re.match(r"https?://[^/]+/([^/]+/[^/]+?)(?:\.git)?/?$", remote_url)
    if m:
        return m.group(1)
    return None


def check_repo() -> Path:
    root = repo_root()
    try:
        remote = _run(["git", "remote", "get-url", "origin"], cwd=root)
    except SystemExit:
        _die("no `origin` remote — talos-sre only runs in the "
             f"`/{EXPECTED_REPO_SUFFIX}` lab checkout")
    owner_repo = _parse_owner_repo(remote)
    if not owner_repo:
        _die(f"could not parse origin URL `{remote}`")
    repo_name = owner_repo.split("/", 1)[1] if "/" in owner_repo else owner_repo
    if repo_name != EXPECTED_REPO_SUFFIX:
        _die(f"wrong repo: origin is `{owner_repo}` (repo `{repo_name}`), "
             f"expected a `/{EXPECTED_REPO_SUFFIX}`-suffixed remote. talos-sre is "
             f"hard-wired to this lab's layout.")
    return root


def list_contexts() -> list[str]:
    """All kube contexts that look like lab clusters (admin@ops, admin@workload-N)."""
    out = _run(["kubectl", "config", "get-contexts", "-o", "name"])
    return [c for c in out.splitlines() if re.search(r"(ops|workload)", c)]


def check_cluster(cluster: str) -> str:
    """Verify the kube context exists. Returns it on success."""
    have = _run(["kubectl", "config", "get-contexts", "-o", "name"]).splitlines()
    if cluster not in have:
        labs = list_contexts()
        menu = "\n".join(f"  - {c}" for c in labs) or \
            "  (none — is the lab up? run spikes/talos-gitops/scripts/01-create-clusters.sh)"
        _die(f"kube context `{cluster}` not found. Lab clusters:\n{menu}")
    return cluster


def enforce(
    cluster: Optional[str] = None,
    *,
    extra_binaries: Optional[list[str]] = None,
) -> Path:
    """
    Single entry point used by every capability script.
    - Always: required binaries on PATH + repo guard.
    - If `cluster` given: that kube context must exist.
    Returns the repo root Path on success.
    """
    check_binaries(extra=extra_binaries)
    root = check_repo()
    if cluster is not None:
        check_cluster(cluster)
    return root


def main() -> None:
    p = argparse.ArgumentParser(description="talos-sre prerequisite check")
    p.add_argument("--cluster", help="Also verify this kube context exists (e.g. admin@ops)")
    p.add_argument("--extra-binary", action="append", default=[],
                   help="Additional binary to require (repeat).")
    args = p.parse_args()
    root = enforce(cluster=args.cluster, extra_binaries=args.extra_binary)
    print("talos-sre prerequisites OK")
    print(f"  repo root: {root}")
    print(f"  remote:    /{EXPECTED_REPO_SUFFIX}-suffixed")
    print(f"  binaries:  {', '.join(REQUIRED_BINARIES + args.extra_binary)}")
    if args.cluster:
        print(f"  cluster:   {args.cluster} (context exists)")
    else:
        print("  clusters known:")
        for c in list_contexts():
            print(f"    - {c}")


if __name__ == "__main__":
    main()
