# Chapter 6 — Vulnerability & Patch Management on Talos

> **Audit posture:** read-only · blast radius = **zero** · every command is shown.
> `vuln.py` *assesses* — it pulls the cluster's running versions and image
> references and (if a scanner is present) ranks CVEs. It changes nothing; every
> finding cites its evidence (a version string, an image ref, or a CVE id + digest).

> A fifth maturity dimension — **Vulnerability** — that asks the questions a
> security review asks every week: *are we behind on Talos/Kubernetes? are we
> pulling images we can't pin or trust? are any running images carrying known
> HIGH/CRITICAL CVEs?* — and answers them continuously, with citations.

| Check | What it flags | Needs a scanner? |
|---|---|---|
| Version currency | Talos / Kubernetes behind a target release | no |
| Supply-chain hygiene | image with no `@sha256:` digest (**high**); un-allow-listed registry (**medium**) | no |
| Image CVE scan | HIGH/CRITICAL CVEs — digest + CVE id + fixed version | yes (`trivy`/`grype`) |

If no scanner is on `PATH`, the CVE check skips with a note and checks 1–2 still
run. All three fold into the report's fifth dimension — evidence, not vibes.

## What you build

- `vuln.py` — three checks, each grounded in a live read, each degrading
  gracefully when a tool isn't present:
  1. **Version currency** — running Talos + Kubernetes versions, flagged if behind
     a target release.
  2. **Supply-chain hygiene** — images pulled by mutable tag instead of an
     `@sha256:` digest (**high**); images from un-allow-listed registries
     (**medium**). No scanner needed — this is pure manifest inspection.
  3. **Image CVE scan** — *if* `trivy` (or `grype`) is on `PATH`, enumerate the
     cluster's images, scan each, and rank HIGH/CRITICAL CVEs with **image digest
     + CVE id + fixed version** as evidence. No scanner → a clear note, checks 1–2
     still run.
- A new **"Vulnerability"** dimension wired into `report.py` — the maturity report
  is now **five** dimensions: Reliability / Security / Certificates / Operations /
  Vulnerability.

```
report ← { health.py, reliability.py, security_drift.py, certs.py, vuln.py }
```

`vuln.py` is a sibling capability (like `security_drift.py`), and `report.py`
folds its finding count into the scorecard exactly like the other four.

## Why it matters (enterprise / audit / agentic)

- **Patch currency is a posture you can fall behind on silently.** Talos and
  Kubernetes both move fast and EOL fast; "we're two minors behind" is a finding,
  not a footnote. `vuln.py` makes version drift a *scored* dimension, so it shows
  up in the same scorecard a platform lead already reads.
- **Supply-chain hygiene needs no scanner to be real.** A `:latest` (or any
  mutable tag) means you can't prove what's running; an image from an
  un-allow-listed registry is an ingress path you didn't sign off on. Both are
  detectable from the pod spec alone — cheap, deterministic, always-on.
- **CVE evidence, not CVE vibes.** When a scanner *is* present, every HIGH/CRITICAL
  is cited with the image digest, the CVE id, and the fixed version — the exact
  three fields a remediation ticket needs. The agent reasons over the scanner's
  output; it never invents a CVE.
- **The savings framing is continuous review.** A human security review
  cross-checks Talos release notes, the Kubernetes version skew policy, the image
  inventory, and a CVE feed — by hand, weekly, per cluster. `vuln.py` runs that
  cross-check on demand against every context, cited. Smaller blast radius
  (you find the un-pinned image before it bites), faster MTTR (the fixed-version
  is already in the evidence).

## What to start

Chapter 1 lab up; Chapter 3 fault workloads deployed. The lab artifact for this
chapter is a **deliberately-old image** in the fault workloads — a pinned,
known-behind tag — so the version-currency and (when a scanner is installed) the
CVE checks have something real to find. No scanner is required to follow the
chapter: checks 1–2 always produce findings; check 3 is the bonus when `trivy` or
`grype` is on `PATH`.

## How to do it

```bash
# default: version currency + supply-chain hygiene (+ CVE scan if trivy/grype present)
python3 .claude/skills/platform-sre/scripts/vuln.py --cluster dev

# machine-readable for the report / a ticket pipeline
python3 .claude/skills/platform-sre/scripts/vuln.py --cluster dev --json

# widen from the default namespace set to the whole cluster
python3 .claude/skills/platform-sre/scripts/vuln.py --cluster dev --all-namespaces
```

Implementation notes:

- **Read-only, same guardrails.** `vuln.py` calls `prerequisites.enforce()` first
  (binary + cluster guard, no-default-prod), shows every `kubectl`/`talosctl`
  command, and allow-lists only read verbs. It cannot mutate the cluster.
- **Version currency** reads the running Talos version (`talosctl version`) and the
  Kubernetes server version (`kubectl version`), compares against a target release
  baked into the script, and emits a finding per component that's behind.
- **Supply-chain hygiene** lists pods (`kubectl get pods -o json`, default namespaces
  unless `--all-namespaces`), inspects each container image ref: a tag with no
  `@sha256:` digest → **high**; a registry host not on the allow-list → **medium**.
- **CVE scan** is gated on `shutil.which("trivy")` / `which("grype")`. Present →
  it enumerates the unique image set and scans each, keeping HIGH/CRITICAL only,
  ranked, with digest + CVE id + fixed version. Absent → one informational line
  ("no scanner found; skipping CVE scan — install trivy or grype to enable") and a
  clean exit of the other two checks.
- **Finding count = exit code**, like the other capabilities, so `report.py` reads
  it as the Vulnerability dimension's penalty input.

## What is what (artifact map)

| Path | Role |
|---|---|
| `.claude/skills/platform-sre/scripts/vuln.py` | version currency + supply-chain hygiene + (optional) CVE scan |
| `.claude/skills/platform-sre/scripts/report.py` | maturity report, now with the **Vulnerability** dimension |
| `.claude/skills/platform-sre/references/step-07-vuln.md` | vulnerability runbook |
| `spikes/talos-gitops/lab/fault-workloads.yaml` | carries the deliberately-old image |

## Verify (observed / expected on the live lab)

- `vuln.py --cluster dev` → flags the deliberately-old image's version currency
  and any container pulled by mutable tag (the fault workloads pin tags, not
  digests) → at least the supply-chain finding(s) on every run.
- `vuln.py --cluster dev` with **no** scanner installed → checks 1–2 report,
  check 3 prints the graceful "no scanner found" note and is skipped.
- `vuln.py --cluster dev` with **trivy** installed → HIGH/CRITICAL CVEs on the old
  image, each line carrying image digest + CVE id + fixed version.
- `report.py --cluster dev` → now five dimensions; **Vulnerability** scored from
  `vuln.py`'s finding count alongside Reliability/Security/Certificates/Operations.

## Status (built vs verified)

- **Built:** `vuln.py` (version currency + supply-chain hygiene always on; CVE scan
  gated on trivy/grype); `report.py` extended to the five-dimension scorecard.
- **Note:** the CVE-scan path's exact finding set depends on the installed scanner
  and its DB freshness — checks 1–2 are deterministic and scanner-independent.
- **v2 (deferred):** feed a HIGH/CRITICAL finding into `remediate.py` as a
  bump-the-image PR; allow-list + target-release as config instead of in-script.
