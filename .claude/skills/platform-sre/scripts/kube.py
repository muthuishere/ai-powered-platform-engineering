#!/usr/bin/env python3
"""
kube.py — read-only cluster access for platform-sre.

Importable helper used by every capability script (health, reliability,
security_drift, certs, report). Calls prerequisites.enforce(cluster) before
touching anything, so it inherits the cluster guard (and resolves the default
`dev` cluster when none is named).

Three guardrails live here:
  * SHOW EVERY COMMAND — `kubectl(...)` / `talosctl(...)` print the exact
    command to stderr before running it. Nothing happens off-screen.
  * READ-ONLY — only allow-listed verbs/subcommands run. A mutating verb is a
    hard error, not a silent pass. The only state-changing path in this skill is
    remediate.py, which changes *git*, never the cluster.
  * EVIDENCE-GROUNDED FINDINGS — `Findings` collects structured findings
    ({id, severity, summary, evidence, proposed_fix}); a finding without a
    traceable source is a bug. `--json` emits the machine-readable bundle the
    reasoning layer ranks.

Cluster identity: a capability takes a cluster name or context (`dev`,
`admin@dev`, or any literal kube-context). The matching talos context is the
suffix after `admin@` when present, else the context name itself.
"""
from __future__ import annotations

import json
import subprocess
import sys
from pathlib import Path
from typing import Optional

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

# Severity vocabulary, ordered worst-first for ranking.
SEVERITY_ORDER = ["critical", "high", "medium", "low", "info"]

# When True, human-readable lines go to stderr and only the final JSON bundle is
# printed to stdout (so `--json` output is clean for piping).
_JSON_MODE = False


def set_json_mode(on: bool) -> None:
    global _JSON_MODE
    _JSON_MODE = bool(on)


def _human(line: str) -> None:
    print(line, file=(sys.stderr if _JSON_MODE else sys.stdout))


def _echo(cmd: list[str]) -> None:
    print(f"  $ {' '.join(cmd)}", file=sys.stderr)


def _die(msg: str) -> None:
    print(msg, file=sys.stderr)
    sys.exit(1)


class Cluster:
    """A guarded handle to one cluster (lab or a real org's)."""

    def __init__(self, spec: Optional[str] = None):
        # enforce() resolves the cluster (default `dev`, never current context)
        # and validates the context exists — the cluster guard.
        self.ctx = enforce(cluster=spec)
        self.talos_ctx = self.ctx[len("admin@"):] if self.ctx.startswith("admin@") else self.ctx

    # --- read-only kubectl --------------------------------------------------
    def kubectl(self, *args: str, check: bool = False, quiet: bool = False) -> subprocess.CompletedProcess:
        verb = args[0] if args else ""
        if verb not in KUBECTL_READ_VERBS:
            _die(f"Refused: non-read kubectl verb `{verb}` (platform-sre is read-only).")
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
            _die(f"Refused: non-read talosctl command `{cmd0}` (platform-sre is read-only).")
        cmd = ["talosctl", "--context", self.talos_ctx, "--nodes", node, *args]
        if not quiet:
            _echo(cmd)
        return subprocess.run(cmd, capture_output=True, text=True)

    def tout(self, *args: str, node: str = "127.0.0.1", quiet: bool = False) -> str:
        return self.talosctl(*args, node=node, quiet=quiet).stdout.strip()


# --- structured, evidence-grounded findings --------------------------------
class Findings:
    """
    Collects structured findings. The count becomes the exit code (so a
    capability doubles as a CI gate). `--json` emits the bundle, ranked by
    severity, for the reasoning layer.
    """

    def __init__(self, cluster: str = "", dimension: str = "") -> None:
        self.cluster = cluster
        self.dimension = dimension
        self.items: list[dict] = []

    def add(self, summary: str, *, id: Optional[str] = None, severity: str = "medium",
            evidence: Optional[str] = None, proposed_fix: Optional[str] = None) -> None:
        if severity not in SEVERITY_ORDER:
            severity = "medium"
        self.items.append({
            "id": id or _slug(summary),
            "severity": severity,
            "summary": summary,
            "evidence": evidence,
            "proposed_fix": proposed_fix,
        })
        _human(f"  !! [{severity}] {summary}")

    def ok(self, msg: str) -> None:
        _human(f"  ok {msg}")

    @property
    def count(self) -> int:
        return len(self.items)

    def ranked(self) -> list[dict]:
        return sorted(self.items, key=lambda f: SEVERITY_ORDER.index(f["severity"]))

    def to_json(self) -> str:
        return json.dumps({
            "cluster": self.cluster,
            "dimension": self.dimension,
            "count": self.count,
            "findings": self.ranked(),
        }, indent=2)

    def exit(self, as_json: bool = False) -> None:
        if as_json:
            print(self.to_json())
        elif self.count == 0:
            _human("\nresult: 0 findings")
        else:
            _human(f"\nresult: {self.count} finding(s), ranked:")
            for f in self.ranked():
                _human(f"  - [{f['severity']}] {f['summary']}")
        sys.exit(self.count)


def _slug(text: str) -> str:
    out = "".join(c if c.isalnum() else "-" for c in text.lower())
    return "-".join(p for p in out.split("-") if p)[:60] or "finding"


def section(title: str) -> None:
    _human(f"\n== {title}")
