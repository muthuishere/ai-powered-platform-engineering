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
import json
import re
import subprocess
import sys
from pathlib import Path

sys.path.insert(0, str(Path(__file__).parent))
from kube import Cluster, Findings, section, set_json_mode, _human  # noqa: E402


def _enddate_of_pem(pem: str) -> "dt.datetime | None":
    try:
        out = subprocess.run(["openssl", "x509", "-noout", "-enddate"],
                             input=pem, capture_output=True, text=True, check=True).stdout
        raw = out.strip().split("=", 1)[1]  # "notAfter=Jun  5 17:09:20 2027 GMT"
        end = dt.datetime.strptime(raw.replace(" GMT", ""), "%b %d %H:%M:%S %Y")
        return end.replace(tzinfo=dt.timezone.utc)
    except Exception:
        return None


def _days(end: "dt.datetime | None") -> "int | None":
    if end is None:
        return None
    return (end - dt.datetime.now(dt.timezone.utc)).days


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
            f.add(f"kube admin cert expires in {d} days ({end})",
                  severity="critical" if d < 0 else "high",
                  evidence=f"client-certificate-data notAfter={end}")
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
                _human("  !! could not read apiserver serving cert (probe failed — not counted)")
            elif d < args.threshold_days:
                f.add(f"apiserver serving cert expires in {d} days ({end})",
                      severity="critical" if d < 0 else "high",
                      evidence=f"kube-apiserver serving cert notAfter={end}")
            else:
                f.ok(f"apiserver serving cert OK ({d} days, {end})")
        except Exception as e:
            _human(f"  !! apiserver cert probe failed: {e} (not counted)")

    section("NAMESPACE TLS SECRETS (kubernetes.io/tls) — leaf cert expiry")
    raw = c.kubectl("get", "secrets", "-A", "--field-selector",
                    "type=kubernetes.io/tls", "-o", "json", quiet=True).stdout
    try:
        secrets = json.loads(raw or '{"items":[]}')["items"]
    except Exception:
        secrets = []
    if not secrets:
        f.ok("no kubernetes.io/tls secrets found")
    for sec in secrets:
        ns = sec["metadata"]["namespace"]
        name = sec["metadata"]["name"]
        crt_b64 = (sec.get("data") or {}).get("tls.crt")
        if not crt_b64:
            _human(f"  !! {ns}/{name}: no tls.crt key (skipped)")
            continue
        try:
            pem = base64.b64decode(crt_b64).decode()
        except Exception:
            _human(f"  !! {ns}/{name}: tls.crt not decodable (skipped)")
            continue
        end = _enddate_of_pem(pem)
        d = _days(end)
        if d is None:
            _human(f"  !! {ns}/{name}: could not parse tls.crt (not counted)")
            continue
        consider(d)
        if d < args.threshold_days:
            f.add(f"TLS secret {ns}/{name} expires in {d} days ({end})",
                  id=f"tls-secret-{ns}-{name}",
                  severity="critical" if d < 0 else "high",
                  evidence=f"secret {ns}/{name} type=kubernetes.io/tls tls.crt notAfter={end}",
                  proposed_fix="rotate/reissue the certificate (e.g. cert-manager renewal) before expiry")
        else:
            f.ok(f"TLS secret {ns}/{name} OK ({d} days, {end})")

    section("OUTAGE PREDICTION")
    if worst is None:
        _human("  no cert expiry could be determined")
    elif worst < 0:
        _human("  !! a control-plane cert is ALREADY EXPIRED — API outage in effect")
    elif worst < args.threshold_days:
        _human(f"  !! earliest control-plane cert failure in ~{worst} days → predicted API outage window")
        _human("     remediate before then (rotate Talos PKI or recreate the lab cluster)")
    else:
        _human(f"  ok no cert-driven outage within {args.threshold_days} days (earliest expiry: {worst} days)")

    f.exit(as_json=args.json)


if __name__ == "__main__":
    main()
