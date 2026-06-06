# Run STATUS — book↔code alignment (2026-06-06)

Branch `feat/talos-sre-lab-and-skill`. Everything below is built, **aligned to the
manuscript**, and **verified live**. Nothing pushed to a remote.

## What changed (code → book alignment)

Direction (Muthukumaran): align the code to the published book, keep the docker
lab, make it work for a big org, don't drift too much.

| Area | Result |
|---|---|
| Skill name | `talos-sre` → **`platform-sre`** (dir + every reference) |
| Cluster model | Org-ready: takes **any** kube context; resolves `dev`/`staging`/`prod` or a literal context; **defaults to `dev`, never the current context**; unknown → refuse |
| Guard model | **Repo guard removed** → the book's **cluster guard** (so it runs against any org's clusters, not just this repo) |
| Lab names | `workload-1/2/3` → **`dev` / `staging` / `prod`** (`ops` stays the hub); GitOps fan-out unchanged (`environment=workload`) |
| Findings | **Structured** `{id, severity, evidence, proposed_fix}`, ranked worst-first, **`--json`** on every capability |
| Severities | node/etcd=critical, control-plane/privileged/hostPath/expiring-cert=high, probes/root=medium, limits/NetworkPolicy=low, expired-cert=critical |
| Report | dimension `Control-plane` → **`Operations`** (book Ch4); `report.py --json` |
| Docs | `references/schema.md` added; SKILL/README/workflow/steps/chapters reworded to cluster-guard + default-dev |

## Lab (rebuilt to book names, verified)

4 clusters via the Docker provisioner, **8 nodes**, all Ready:
`admin@ops` (ArgoCD + Gitea hub) + `admin@dev` / `admin@staging` / `admin@prod`.
GitOps pipeline rebuilt clean (the `su git` Gitea-user fix held): `platform` repo
seeded, App-of-Apps applied, **ArgoCD Applications Healthy** (cert-manager,
ingress-nginx, metrics-server, kube-prometheus-stack across all three spokes).
Fault workloads (`demo/web`, `demo/cache` privileged) deployed to `dev`.

## Verification (live)

- **default-dev**: `prerequisites.py` with no `--cluster` → "defaulting to
  'admin@dev' (never the current context)" → cluster guard passed.
- **book short-name resolves**: `report.py --cluster dev --json` → `admin@dev`,
  scored JSON (Reliability/Security/Certificates/Operations).
- **reliability --json**: 26 ranked findings; top = high single-replica/no-PDB.
- **security_drift --json**: privileged + hostPath (high) ranked above
  runAsNonRoot (medium) and NetworkPolicy (low). Privileged `cache` pod scheduled
  (the `demo` PSA-relaxation label held).
- **health/certs**: 0 findings on a fresh cluster; cert outage prediction clean.

## Bug found & fixed during verification

`reliability.py` referenced an undefined `obj` in a finding's `evidence`, crashing
`--json` (and making `report.py` misread the exit code as "1 finding"). Fixed to
`{kind}/{name}`; re-verified 26 findings.

## Two items for the manuscript agent (book-side, not code)

1. **Ch1 §1.6 DNS sidebar (correctness):** the book's `talosctl cluster create
   --name dev` omits the empty-`dnsServers` etcd wedge on OrbStack — a reader's
   lab can hang. Point at `01-create-clusters.sh`'s `--config-patch` fix.
2. **Ch2 layout (cosmetic):** drop `env_loader.py` (no vault here) and present
   presets as an extension point rather than a shipped `step-05-preset`.

See `chapters/BOOK-CODE-ALIGNMENT.md` for the full resolution log.

## To bring the lab up from cold

```bash
cd spikes/talos-gitops
./scripts/01-create-clusters.sh && ./scripts/02-connect-networks.sh
./scripts/03-bootstrap-hub.sh   && ./scripts/04-register-clusters.sh
kubectl --context admin@dev apply -f lab/fault-workloads.yaml
# then: python3 .claude/skills/platform-sre/scripts/report.py --cluster dev
```
