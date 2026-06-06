# Book ↔ Code alignment — status

The manuscript (`…/aipoweredkubernetesplatformengineering/manuscript/`) and this
companion repo drifted apart while each was built. Decision (Muthukumaran):
**align the code to the book, keep the docker lab, make it work for a big org,
don't drift too much.** This is the resolution log.

Legend: ✅ done in code · 📖 recommend a manuscript tweak (hand to the book agent).

---

## ✅ 1. Skill name → `platform-sre`
Renamed `talos-sre` → `platform-sre` (directory + every reference). Matches the
book and the broader "works against any conformant cluster" framing.

## ✅ 2. Cluster model — org-ready
- Lab renamed: `ops` hub + `dev` / `staging` / `prod` spokes (was workload-1/2/3).
- The skill takes **any** kube context. `prerequisites.resolve_cluster()` accepts
  `dev` / `staging` / `prod` or any literal context; if none is named it
  **defaults to `dev`, never the current context**; unknown → refuse with the list.
- **Repo guard removed.** A repo guard would refuse to run in a customer's repo —
  fatal for a big org. The guard is now the book's **cluster guard** (the context
  must exist). This is the one deliberate deviation from the house repo-guard rule,
  justified by the big-org requirement and the book's five guardrails.

## ✅ 3 + 📖 4. Lab create command & the DNS/etcd wedge
- Code: `01-create-clusters.sh` already uses the Docker provisioner with the
  nameserver `--config-patch` that prevents the etcd wedge on OrbStack.
- 📖 **Book correctness fix (hand to manuscript agent):** Ch1 §1.6 shows
  `talosctl cluster create --name dev` with no mention of the empty-`dnsServers`
  etcd wedge. On OrbStack a reader's etcd can hang forever. Add a short sidebar
  pointing at `01-create-clusters.sh`'s `--config-patch` fix. This is the most
  likely "the book's lab doesn't work for me" issue.

## ✅ 5. Skill layout
- Kept a single unified `kube.py` runner (the book can call it "a runner module" —
  we didn't split into kube_runner/talos_runner to avoid churn).
- Added `references/schema.md` (k8s + Talos resource/field reference) for book parity.
- `env_loader.py` intentionally omitted — there is no vault; kubeconfig is the
  only config. 📖 the book's Ch2 layout can drop `env_loader.py` and note this.

## ✅ 6. Structured, evidence-grounded findings — the headline upgrade
`kube.py` `Findings` now carries `{id, severity, summary, evidence, proposed_fix}`,
ranked worst-first, with `--json` on every capability. This makes the code
actually demonstrate the book's central pitch (grounded, cited, ranked findings)
instead of approximating it with text lines. Severities wired: node/etcd =
critical, control-plane/privileged/hostPath/expiring-cert = high, probes/root =
medium, limits/NetworkPolicy = low, expired cert = critical.

## ✅ 7. Report dimensions → `Operations`
`report.py` scores Reliability / Security / Certificates / **Operations** (was
Control-plane), matching the book's Ch4 example. `--json` scored bundle added.

## 📖 8. Presets / step-05-preset — deferred (don't-drift)
The book's Ch2 layout lists `references/presets/` + `step-05-preset`. We **did not**
add presets or renumber the steps — it's churn against the "don't drift too much"
guidance, and our six concrete capabilities (health, reliability, security, certs,
report, remediate) are the substance. 📖 the book can present presets as a
documented **extension point** ("drop a `.yaml` check in `references/presets/`")
rather than a shipped step, matching reqsume-sre's spirit without the code drift.

---

## Net
Code now matches the book's contracts: `platform-sre`, dev/staging/prod, the five
guardrails (read-only, ask-which-cluster/default-dev, show-every-command, cluster
guard, fail-fast), structured findings, the maturity report, GitOps remediation —
and it runs against any org's clusters, not just this lab. Two items are **book
tweaks** to hand to the manuscript agent: the DNS sidebar (correctness) and the
layout/preset wording (cosmetic).
