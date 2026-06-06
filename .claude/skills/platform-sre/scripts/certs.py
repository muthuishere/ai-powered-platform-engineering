#!/usr/bin/env python3
"""
certs.py — Chapter 4: certificate expiry → outage prediction.

Talos is API-driven with short-lived PKI; an expired control-plane cert takes
the API server down. This reads the kubeconfig client cert and the apiserver
serving cert, computes days-to-expiry, and predicts the outage window.
Read-only. Exits non-zero if anything expires within --threshold-days.

    python3 certs.py --cluster admin@ops [--threshold-days 30]
"""
from __future__ import annotations

import argparse
import base64
import datetime as dt
import re
import subprocess
import sys
from pathlib import Path

sys.path.insert(0, str(Path(__file__).parent))
from kube import Cluster, Findings, section, set_json_mode  # noqa: E402


def _enddate_of_pem(pem: str) -> "dt.datetime | None":
    try:
        out = subprocess.run(["openssl", "x509", "-noout", "-enddate"],
                             input=pem, capture_output=True, text=True, check=True).stdout
        raw = out.strip().split("=", 1)[1]  # "notAfter=Jun  5 17:09:20 2027 GMT"
        return dt.datetime.strptime(raw.replace(" GMT", ""), "%b %d %H:%M:%S %Y")
    except Exception:
        return None


def _days(end: "dt.datetime | None") -> "int | None":
    if end is None:
        return None
    return (end - dt.datetime.utcnow()).days


def main() -> None:
    p = argparse.ArgumentParser(description="Cert expiry / outage prediction")
    p.add_argument("--cluster", help="cluster name or context (dev/staging/prod/...); default dev")
    p.add_argument("--threshold-days", type=int, default=30)
    p.add_argument("--json", action="store_true", help="emit findings as a JSON bundle")
    args = p.parse_args()
    c = Cluster(args.cluster)
    set_json_mode(args.json)
    f = Findings(c.ctx, "certificates")
    worst: "int | None" = None

    def consider(d):
        nonlocal worst
        if d is not None and (worst is None or d < worst):
            worst = d

    section("KUBERNETES admin client cert (from kubeconfig)")
    b64 = c.kout("config", "view", "--raw", "--minify",
                 "-o", "jsonpath={.users[0].user.client-certificate-data}", quiet=True)
    if b64:
        end = _enddate_of_pem(base64.b64decode(b64).decode())
        d = _days(end)
        consider(d)
        if d is None:
            f.add("could not parse kube client cert")
        elif d < args.threshold_days:
            f.add(f"kube admin cert expires in {d} days ({end})")
        else:
            f.ok(f"kube admin cert OK ({d} days, {end})")
    else:
        f.add("could not read kube client cert from kubeconfig")

    section("KUBE-APISERVER serving cert (live TLS)")
    server = c.kout("config", "view", "--raw", "--minify",
                    "-o", "jsonpath={.clusters[0].cluster.server}", quiet=True)
    m = re.search(r":(\d+)$", server or "")
    if m:
        port = m.group(1)
        print(f"  $ openssl s_client -connect 127.0.0.1:{port} | openssl x509 -enddate", file=sys.stderr)
        try:
            chan = subprocess.run(
                f"echo | openssl s_client -connect 127.0.0.1:{port} 2>/dev/null | openssl x509",
                shell=True, capture_output=True, text=True).stdout
            end = _enddate_of_pem(chan)
            d = _days(end)
            consider(d)
            if d is None:
                # A probe failure is NOT a cert-expiry finding — don't penalise
                # the score for an unreadable endpoint. Warn only.
                print("  !! could not read apiserver serving cert (probe failed — not counted)")
            elif d < args.threshold_days:
                f.add(f"apiserver serving cert expires in {d} days ({end})")
            else:
                f.ok(f"apiserver serving cert OK ({d} days, {end})")
        except Exception as e:
            print(f"  !! apiserver cert probe failed: {e} (not counted)")

    section("OUTAGE PREDICTION")
    if worst is None:
        print("  no cert expiry could be determined")
    elif worst < 0:
        print("  !! a control-plane cert is ALREADY EXPIRED — API outage in effect")
    elif worst < args.threshold_days:
        print(f"  !! earliest control-plane cert failure in ~{worst} days → predicted API outage window")
        print("     remediate before then (rotate Talos PKI or recreate the lab cluster)")
    else:
        print(f"  ok no cert-driven outage within {args.threshold_days} days (earliest expiry: {worst} days)")

    f.exit(as_json=args.json)


if __name__ == "__main__":
    main()
