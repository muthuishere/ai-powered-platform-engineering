# Step 07: Vulnerability & patch review

Use when the user asks about CVEs, vulnerabilities, image scanning, patch status,
"are we behind on Talos/Kubernetes", supply-chain, or "is anything running a
known-vulnerable image".

## Show the command, then run

```bash
python3 .claude/skills/platform-sre/scripts/vuln.py --cluster {cluster} [--all-namespaces] [--require-digests]
```

Read-only. Three checks, each evidence-grounded:

1. **Version currency** — reports the running Talos + Kubernetes versions and flags
   if they're below a floor (`--min-talos` / `--min-k8s`). A declared version is one
   you can reason about: "are we exposed to an already-fixed CVE?"
2. **Supply-chain hygiene** — images on a mutable `:latest` tag (high), images from
   an un-allow-listed registry (medium). `--require-digests` adds the strict check
   that every image be pinned by `@sha256` (off by default — most clusters pin by
   tag, so it's noise unless you've decided to enforce digests).
3. **Image CVE scan** — *if* `trivy` or `grype` is on PATH, enumerates the images the
   cluster runs, scans them, and ranks HIGH/CRITICAL CVEs (image + CVE id + fixed
   version as evidence). With no scanner it skips this check and says so — the
   absence of a scanner is not a cluster finding.

## Summarize

- Exit code = finding count. Lead with the worst severity.
- A `:latest` image is the headline supply-chain risk — what's deployed can change
  under you and can't be audited to a known CVE state. It's directly fixable (pin a
  version, ideally a digest), and a natural `remediate.py` candidate (v2).
- If a scanner is present, the CVE findings per image are the high-value output;
  rank by severity and cite the CVE ids.

## Notes

- Feeds the **Vulnerability** dimension of the maturity report (`report.py`).
- To activate CVE scanning: `brew install trivy` (first scan downloads a vuln DB).
- The savings story (book Ch6): this is the continuous, cited CVE + version review
  that replaces a security engineer's manual weekly cross-check — and Talos's small
  attack surface (no shell/SSH/package manager) means there's far less to find.

## Failure modes

- "no image scanner on PATH" — expected without trivy/grype; version + supply-chain
  checks still run. Install a scanner to add CVE detail.
- scan timeout on a large image — the script notes it and moves on (not counted).
