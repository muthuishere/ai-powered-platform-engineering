#!/usr/bin/env python3
"""
report.py — Chapter 4: Platform Maturity Report (the headline output).

Runs health + reliability + security + certs against one cluster, turns each
dimension's finding-count into a 0-100 score, and prints a scored report with
grades and bars. Always exits 0 — it's a report, not a gate.

    python3 report.py --cluster admin@ops
"""
from __future__ import annotations

import argparse
import subprocess
import sys
from pathlib import Path

HERE = Path(__file__).parent
sys.path.insert(0, str(HERE))
from prerequisites import enforce  # noqa: E402

PENALTY = 15  # points per finding


def run_dim(script: str, cluster: str) -> int:
    """Run a capability script; its exit code is the finding count."""
    r = subprocess.run([sys.executable, str(HERE / script), "--cluster", cluster],
                       capture_output=True, text=True)
    return r.returncode


def grade(s: int) -> str:
    return "A" if s >= 90 else "B" if s >= 80 else "C" if s >= 70 else "D" if s >= 60 else "F"


def bar(s: int) -> str:
    full = s // 10
    return "[" + "#" * full + "." * (10 - full) + "]"


def main() -> None:
    p = argparse.ArgumentParser(description="Platform maturity report")
    p.add_argument("--cluster", required=True)
    args = p.parse_args()
    enforce(cluster=args.cluster)

    print(f"Generating platform maturity report for {args.cluster} — running all capabilities...")
    # Dimension names match the book's maturity report (Ch4): Operations is the
    # control-plane/health signal; the other three are 1:1.
    dims = {
        "Reliability": run_dim("reliability.py", args.cluster),
        "Security": run_dim("security_drift.py", args.cluster),
        "Certificates": run_dim("certs.py", args.cluster),
        "Operations": run_dim("health.py", args.cluster),
    }
    scores = {k: max(0, 100 - v * PENALTY) for k, v in dims.items()}
    total = sum(scores.values()) // len(scores)

    print("\n================ PLATFORM MATURITY REPORT ================")
    print(f"  cluster: {args.cluster}")
    print("---------------------------------------------------------")
    for k in dims:
        s = scores[k]
        print(f"  {k:<14} {bar(s)} {s:>3} / 100  ({grade(s)})  [{dims[k]} findings]")
    print("---------------------------------------------------------")
    print(f"  PLATFORM MATURITY  {bar(total)}  {total:>3} / 100   GRADE {grade(total)}")
    print("=========================================================")
    print("\n  Drill in:   python3 scripts/reliability.py --cluster", args.cluster)
    print("  Remediate:  python3 scripts/remediate.py --cluster", args.cluster, "--finding <id>")
    sys.exit(0)


if __name__ == "__main__":
    main()
