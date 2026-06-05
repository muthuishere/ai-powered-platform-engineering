#!/usr/bin/env python3
"""
kube.py — read-only cluster access for talos-sre.

Importable helper used by every capability script (health, reliability,
security_drift, certs, report). Calls prerequisites.enforce(cluster) before
touching anything, so it inherits the repo + cluster guard.

Two guardrails live here:
  * SHOW EVERY COMMAND — `kubectl(...)` / `talosctl(...)` print the exact
    command to stderr before running it. Nothing happens off-screen.
  * READ-ONLY — only allow-listed verbs/subcommands run. A mutating verb is a
    hard error, not a silent pass. The only state-changing path in this skill is
    remediate.py, which changes *git*, never the cluster.

Cluster identity: capability scripts take a kube context like `admin@ops`. The
matching talos context is the suffix after `admin@` (i.e. `ops`).
"""
from __future__ import annotations

import subprocess
import sys
from pathlib import Path

sys.path.insert(0, str(Path(__file__).parent))
from prerequisites import enforce  # noqa: E402

KUBECTL_READ_VERBS = {
    "get", "describe", "top", "api-resources", "api-versions",
    "version", "explain", "logs", "cluster-info", "config",
}
TALOS_READ_CMDS = {
    "get", "health", "version", "services", "etcd", "dmesg",
    "containers", "list", "read", "time", "disks", "config",
}


def _echo(cmd: list[str]) -> None:
    print(f"  $ {' '.join(cmd)}", file=sys.stderr)


def _die(msg: str) -> None:
    print(msg, file=sys.stderr)
    sys.exit(1)


class Cluster:
    """A guarded handle to one lab cluster."""

    def __init__(self, kube_context: str):
        enforce(cluster=kube_context)
        self.ctx = kube_context
        self.talos_ctx = kube_context[len("admin@"):] if kube_context.startswith("admin@") else kube_context

    # --- read-only kubectl --------------------------------------------------
    def kubectl(self, *args: str, check: bool = False, quiet: bool = False) -> subprocess.CompletedProcess:
        verb = args[0] if args else ""
        if verb not in KUBECTL_READ_VERBS:
            _die(f"Refused: non-read kubectl verb `{verb}` (talos-sre is read-only).")
        cmd = ["kubectl", "--context", self.ctx, *args]
        if not quiet:
            _echo(cmd)
        return subprocess.run(cmd, check=check, capture_output=True, text=True)

    def kout(self, *args: str, quiet: bool = False) -> str:
        """kubectl returning stdout (empty string on failure)."""
        return self.kubectl(*args, quiet=quiet).stdout.strip()

    # --- read-only talosctl -------------------------------------------------
    def talosctl(self, *args: str, node: str = "127.0.0.1", quiet: bool = False) -> subprocess.CompletedProcess:
        cmd0 = args[0] if args else ""
        if cmd0 not in TALOS_READ_CMDS:
            _die(f"Refused: non-read talosctl command `{cmd0}` (talos-sre is read-only).")
        cmd = ["talosctl", "--context", self.talos_ctx, "--nodes", node, *args]
        if not quiet:
            _echo(cmd)
        return subprocess.run(cmd, capture_output=True, text=True)

    def tout(self, *args: str, node: str = "127.0.0.1", quiet: bool = False) -> str:
        return self.talosctl(*args, node=node, quiet=quiet).stdout.strip()


# --- shared finding accumulator + output helpers ---------------------------
class Findings:
    """Collects evidence-grounded findings; the count becomes the exit code."""

    def __init__(self) -> None:
        self.items: list[str] = []

    def add(self, msg: str) -> None:
        self.items.append(msg)
        print(f"  !! {msg}")

    def ok(self, msg: str) -> None:
        print(f"  ok {msg}")

    @property
    def count(self) -> int:
        return len(self.items)

    def exit(self) -> None:
        if self.count == 0:
            print("\nresult: 0 findings")
        else:
            print(f"\nresult: {self.count} finding(s)")
        sys.exit(self.count)


def section(title: str) -> None:
    print(f"\n== {title}")
