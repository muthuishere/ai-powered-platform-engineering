#!/usr/bin/env python3
"""
vuln.py — Chapter 6: vulnerability & patch management.

Read-only vulnerability review of one cluster. Three checks, each evidence-grounded:

  1. VERSION CURRENCY — the running Talos + Kubernetes versions, and how far behind
     a target release the fleet is (a version you declared is a version you can
     reason about: "are we exposed to an already-fixed CVE?").
  2. SUPPLY-CHAIN HYGIENE — container images pinned by a mutable tag instead of an
     immutable @sha256 digest (and the dangerous `:latest`), and images from
     registries outside an allow-list. Needs no scanner — it's a pure API read.
  3. IMAGE CVE SCAN — when an image scanner (trivy or grype) is on PATH, enumerate
     the images the cluster actually runs, scan them, and rank HIGH/CRITICAL CVEs
     with the image + CVE id + fixed version as evidence. Degrades honestly: with
     no scanner it skips this check and says so (the absence of a scanner is not a
     cluster finding).

Same guardrails as every capability: ask-which-cluster (default dev), read-only,
show-every-command, fail-fast. Exits with the finding count; `--json` emits the
ranked bundle. Feeds the "Vulnerability" dimension of the maturity report.

    python3 vuln.py --cluster dev [--json] [--all-namespaces] [--min-talos v1.9.0]
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

# System namespaces skipped unless --all-namespaces (their images are the
# platform's, reviewed separately).
SKIP_NS = {"kube-system", "kube-public", "kube-node-lease"}

# Registries we treat as trusted by default. Anything else is flagged (medium).
ALLOWED_REGISTRIES = {
    "docker.io", "registry.k8s.io", "k8s.gcr.io", "quay.io", "ghcr.io",
    "gcr.io", "public.ecr.aws", "mcr.microsoft.com", "registry.gitlab.com",
}

# Targets for version currency. These are conservative floors, not "latest" —
# update them (or pass --min-talos / --min-k8s) as releases move. Being BELOW a
# floor means you're missing fixes that shipped in newer minors.
DEFAULT_MIN_TALOS = "v1.7.0"
DEFAULT_MIN_K8S = "v1.30.0"


def _minor(ver: str) -> "tuple[int, int] | None":
    m = re.search(r"v?(\d+)\.(\d+)", ver or "")
    return (int(m.group(1)), int(m.group(2))) if m else None


def parse_image(image: str) -> "tuple[str, str, bool]":
    """Return (registry, tag_or_latest, is_digest_pinned)."""
    digest_pinned = "@sha256:" in image
    ref = image.split("@", 1)[0]
    parts = ref.split("/")
    # The first path segment is a registry only if it looks like a host: it has a
    # dot or a port-colon AND there's a path after it, or it's 'localhost'. A bare
    # `busybox:1.36` is repo:tag on docker.io — the colon is the tag, not a port.
    if len(parts) > 1 and ("." in parts[0] or ":" in parts[0] or parts[0] == "localhost"):
        registry = parts[0]
        name = "/".join(parts[1:])
    else:
        registry = "docker.io"
        name = ref
    last = name.rsplit("/", 1)[-1]          # final segment carries the :tag
    tag = last.rsplit(":", 1)[1] if ":" in last else "latest"
    return registry, tag, digest_pinned


def collect_images(c: Cluster, all_ns: bool) -> "dict[str, list[str]]":
    """Map each unique image -> list of 'ns/pod' that run it."""
    raw = c.kubectl("get", "pods", "-A", "-o", "json").stdout or '{"items":[]}'
    out: "dict[str, list[str]]" = {}
    for pod in json.loads(raw)["items"]:
        ns = pod["metadata"]["namespace"]
        if not all_ns and ns in SKIP_NS:
            continue
        spec = pod.get("spec", {})
        where = f'{ns}/{pod["metadata"]["name"]}'
        for ct in spec.get("containers", []) + spec.get("initContainers", []):
            out.setdefault(ct["image"], []).append(where)
    return out


def find_scanner() -> "str | None":
    for s in ("trivy", "grype"):
        if shutil.which(s):
            return s
    return None


def scan_image(scanner: str, image: str) -> "tuple[int, int, list[str]]":
    """Return (critical, high, sample_cve_ids) for an image. Best-effort."""
    try:
        if scanner == "trivy":
            cmd = ["trivy", "image", "--quiet", "--severity", "HIGH,CRITICAL",
                   "--format", "json", "--timeout", "5m", image]
            out = subprocess.run(cmd, capture_output=True, text=True, timeout=360).stdout
            data = json.loads(out or "{}")
            crit = high = 0
            cves: list[str] = []
            for res in data.get("Results", []) or []:
                for v in res.get("Vulnerabilities", []) or []:
                    sev = v.get("Severity", "")
                    if sev == "CRITICAL":
                        crit += 1
                    elif sev == "HIGH":
                        high += 1
                    if len(cves) < 5 and v.get("VulnerabilityID"):
                        cves.append(v["VulnerabilityID"])
            return crit, high, cves
        else:  # grype
            cmd = ["grype", image, "-o", "json", "-q"]
            out = subprocess.run(cmd, capture_output=True, text=True, timeout=360).stdout
            data = json.loads(out or "{}")
            crit = high = 0
            cves = []
            for m in data.get("matches", []) or []:
                sev = (m.get("vulnerability", {}) or {}).get("severity", "")
                if sev == "Critical":
                    crit += 1
                elif sev == "High":
                    high += 1
                vid = (m.get("vulnerability", {}) or {}).get("id")
                if len(cves) < 5 and vid:
                    cves.append(vid)
            return crit, high, cves
    except Exception:
        return -1, -1, []  # scan error sentinel


def main() -> None:
    p = argparse.ArgumentParser(description="Vulnerability & patch review")
    p.add_argument("--cluster", help="cluster name or context (dev/staging/prod/...); default dev")
    p.add_argument("--json", action="store_true", help="emit findings as a JSON bundle")
    p.add_argument("--all-namespaces", action="store_true", help="include system namespaces")
    p.add_argument("--require-digests", action="store_true",
                   help="strict: flag every image not pinned by @sha256 digest")
    p.add_argument("--min-talos", default=DEFAULT_MIN_TALOS, help="minimum acceptable Talos version")
    p.add_argument("--min-k8s", default=DEFAULT_MIN_K8S, help="minimum acceptable Kubernetes version")
    p.add_argument("--max-images", type=int, default=25, help="cap images sent to the CVE scanner")
    args = p.parse_args()
    c = Cluster(args.cluster)
    set_json_mode(args.json)
    f = Findings(c.ctx, "vulnerability")

    # --- 1. version currency -------------------------------------------------
    section("VERSION CURRENCY — running Talos + Kubernetes vs a floor")
    tver = ""
    vout = c.tout("version")
    # talosctl prints Client then Server; the Server 'Tag:' is the node version.
    tags = re.findall(r"Tag:\s*(v[\d.]+)", vout)
    tver = tags[-1] if tags else ""
    k8s = c.kout("get", "nodes", "-o",
                 "jsonpath={.items[0].status.nodeInfo.kubeletVersion}", quiet=True)
    print(f"  talos: {tver or '?'}   kubernetes: {k8s or '?'}")
    tm, target_t = _minor(tver), _minor(args.min_talos)
    if tm and target_t and tm < target_t:
        f.add(f"Talos {tver} is below the floor {args.min_talos} — missing fixes shipped since",
              id="talos-version-behind", severity="high",
              evidence=f"running {tver}, floor {args.min_talos}",
              proposed_fix="upgrade Talos (atomic A/B image roll); see siderolabs/talos releases")
    elif tm:
        f.ok(f"Talos {tver} >= floor {args.min_talos}")
    km, target_k = _minor(k8s), _minor(args.min_k8s)
    if km and target_k and km < target_k:
        f.add(f"Kubernetes {k8s} is below the floor {args.min_k8s}",
              id="k8s-version-behind", severity="high",
              evidence=f"running {k8s}, floor {args.min_k8s}",
              proposed_fix="upgrade Kubernetes via Talos (talosctl upgrade-k8s)")
    elif km:
        f.ok(f"Kubernetes {k8s} >= floor {args.min_k8s}")

    # --- 2. supply-chain hygiene --------------------------------------------
    section("SUPPLY-CHAIN HYGIENE — image pinning & registries")
    images = collect_images(c, args.all_namespaces)
    if not images:
        f.ok("no user-namespace images found")
    for image, used_by in sorted(images.items()):
        registry, tag, digest = parse_image(image)
        if tag == "latest" and not digest:
            f.add(f"{image}: mutable ':latest' tag (unpinned, can change under you)",
                  id="image-latest-tag", severity="high",
                  evidence=f"used by {', '.join(used_by[:3])}",
                  proposed_fix="pin to a specific version and ideally an @sha256 digest")
        elif args.require_digests and not digest:
            # Off by default — nearly every real cluster pins by tag, so flagging
            # all of them is noise. --require-digests turns on the strict check.
            f.add(f"{image}: pinned by tag, not @sha256 digest",
                  id="image-not-digest-pinned", severity="low",
                  evidence=f"used by {', '.join(used_by[:3])}",
                  proposed_fix="pin to an immutable @sha256 digest for reproducibility")
        if registry not in ALLOWED_REGISTRIES:
            f.add(f"{image}: registry '{registry}' is not on the allow-list",
                  id="image-untrusted-registry", severity="medium",
                  evidence=f"registry={registry}",
                  proposed_fix="mirror to a trusted registry or add it to the allow-list")

    # --- 3. image CVE scan (scanner-optional) -------------------------------
    section("IMAGE CVE SCAN — HIGH/CRITICAL (needs trivy or grype)")
    scanner = find_scanner()
    if not scanner:
        print("  !! no image scanner (trivy/grype) on PATH — skipping CVE scan (not counted)")
        print("     install one to activate this check:  brew install trivy")
    elif images:
        print(f"  using {scanner}; scanning up to {args.max_images} unique image(s)")
        for image in sorted(images)[:args.max_images]:
            crit, high, cves = scan_image(scanner, image)
            if crit < 0:
                print(f"  !! {image}: scan failed/timed out (not counted)")
                continue
            if crit + high == 0:
                f.ok(f"{image}: no HIGH/CRITICAL CVEs")
            else:
                f.add(f"{image}: {crit} CRITICAL + {high} HIGH CVEs",
                      id=f"cve-{re.sub('[^a-z0-9]+','-',image.lower())}",
                      severity="critical" if crit else "high",
                      evidence=f"e.g. {', '.join(cves)}" if cves else f"{scanner} scan",
                      proposed_fix="rebuild on a patched base image / bump to a fixed version")
        if len(images) > args.max_images:
            print(f"  (capped at {args.max_images}; {len(images) - args.max_images} more not scanned)")

    f.exit(as_json=args.json)


if __name__ == "__main__":
    main()
