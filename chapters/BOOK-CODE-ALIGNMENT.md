# Book ↔ Code alignment report

The manuscript (`…/aipoweredkubernetesplatformengineering/manuscript/`) and this
companion repo drifted apart while each was built. A reader who buys the book and
clones the repo must find what they read. This report maps every divergence and
recommends a fix direction per item.

**Guiding principle:** the **book is the source of truth for narrative, naming, and
the five guardrails** (it's polished and customer-facing). The **companion code is
the source of truth for what actually runs** (it's verified live). Where they
disagree, prefer: change the code to match the book's *contracts* (names, layout),
and recommend small book tweaks only where the book is *factually wrong* (a command
that won't run).

Legend: **[CODE]** = fix in this repo · **[BOOK]** = recommend a manuscript tweak
(hand to the manuscript agent) · **[BOTH]** = meet in the middle.

---

## 1. Skill name — `platform-sre` (book) vs `platform-sre` (code)  → **DECISION NEEDED**

The book ships `platform-sre` in Ch2 (folder layout, `SKILL.md` example, description).
The code is `platform-sre` (directory, SKILL.md, 7 chapter briefs, install.sh, memory).

- **Recommendation: rename code → `platform-sre`.** The book is the published
  artifact and frames the skill as working against *any* conformant cluster with
  Talos as the lab substrate — `platform-sre` is the intentional, broader name.
  Cost: rename one directory + ~15 references. Lower-risk than editing the book.
- **To flip** (keep `platform-sre`): change ~4 book mentions in Ch2 instead. `platform-sre`
  is more literally accurate (the lab is Talos) but narrower than the book's pitch.

## 2. Cluster naming — `dev/staging/prod` (book) vs `ops/dev/staging/prod` (code)  → **DECISION NEEDED**

The biggest divergence. The book teaches a simple progression: create `dev`, later add
`staging`, mention `prod`. The lab is a 4-cluster **hub-spoke** (`ops` runs ArgoCD +
Gitea; `dev/staging/prod` are GitOps targets) — which the GitOps chapter genuinely needs
(you can't demo multi-cluster fan-out from one `dev`).

- **Recommendation [BOTH]:** keep BOTH, and make the book name the gap explicitly.
  - The book's `dev` is the *teaching* cluster for Ch1–4 (health/reliability/security/
    certs against one cluster — true to the prose).
  - The companion lab's `ops + workload-*` hub-spoke is the **Ch5 GitOps** topology.
  - Add one paragraph to book Ch1 §1.6 and Ch5 §5.1: "the companion repo provisions a
    4-cluster lab (`ops` hub + three `workload-*` spokes) so Chapter 5's multi-cluster
    GitOps is real; chapters 3–4 work identically against any one of them."
  - **[CODE]** make the skill accept any context (it already does — `admin@<name>`),
    and document that `admin@dev` is the book's `dev`-equivalent.

## 3 + 4. Lab create command & the DNS/etcd wedge  → **[BOOK] — correctness bug**

Book Ch1 §1.6 says:
```
talosctl cluster create --name dev
```
Two problems for a reader on Docker/OrbStack:
1. Our verified lab uses `talosctl cluster create docker --name … --config-patch dns.yaml`.
   On Talos v1.13 the docker provisioner and the nameserver patch matter.
2. **The book never mentions the empty-`dnsServers` etcd wedge.** A reader on OrbStack
   may hit an etcd that hangs forever pulling its image, and the book gives them no
   way out. This is the single most likely "the book's lab doesn't work for me" issue.

- **Recommendation [BOOK]:** add a short, honest sidebar to §1.6 — "On some Docker
  runtimes (notably OrbStack on macOS) a Talos node comes up with no DNS server and
  etcd can't pull its image; the companion repo's `01-create-clusters.sh` pins
  nameservers via `--config-patch` to fix this. Use that script rather than the bare
  command if your cluster hangs on etcd." This turns a reader-blocker into a teaching
  moment (and it's exactly the kind of hard-won detail your style favours).
- **[CODE]** already handled in `spikes/talos-gitops/scripts/patches/dns.yaml`.

## 5. Skill folder layout  → **[CODE] partial**

| Book layout | Code layout | Action |
|---|---|---|
| `workflow.md` at skill root | `references/workflow.md` | **[BOOK]** trivial: book can show it under `references/` (matches reqsume-sre too) |
| `steps/` at skill root | `references/steps/` | same — **[BOOK]** or **[CODE]** move; recommend book matches code (reqsume-sre nests under references) |
| `kube_runner.py` + `talos_runner.py` | `kube.py` (one `Cluster` class) | **[CODE]** acceptable to keep unified; **[BOOK]** mention it's one runner module |
| `env_loader.py` | (none) | **[CODE]** not needed (no vault); **[BOOK]** drop from layout or note "kubeconfig is the only config" |
| `references/schema.md` | `references/talos-cheatsheet.md` | **[CODE]** rename/add `schema.md` (k8s+Talos resource reference) — cheap win |
| `references/presets/` | (none) | **[CODE]** add `references/presets/*.yaml` canned checks (see item 8) |

## 6. Findings model — structured (book) vs text lines (code)  → **[CODE] — best "make it better"**

The book sells findings as structured objects: `id`, `severity`, `evidence{source,
detail}`, `recommendation`/`proposed_fix`/`prediction`, and a reasoning layer that
**ranks by severity** and **drops any finding without evidence**. The code currently
prints text warnings and uses exit-code = count.

- **Recommendation [CODE]:** upgrade `kube.py`'s `Findings` to carry structured
  findings (`id`, `severity`, `evidence`, optional `proposed_fix`) and add a
  `--json` output mode. This is the highest-value code change — it makes the code
  actually demonstrate the book's central pitch (grounded, cited, ranked findings)
  instead of approximating it. Keep the human text mode as the default.

## 7. Report dimensions — `Operations` (book) vs `Control-plane` (code)  → **[BOTH]**

Book scores Reliability/Security/Certificates/**Operations**; code scores
**Control-plane**/Reliability/Security/Certificates.

- **Recommendation:** rename the code's `Control-plane` dimension to **`Operations`**
  (control-plane health *is* the operational signal) so the report matches the book's
  example verbatim — **[CODE]**, one-line change in `report.py`.

## 8. Preset checks & step set  → **[CODE]**

Book has `step-05-preset` and `references/presets/` (canned read-only checks, inherited
from reqsume-sre's `presets/*.sql`). Code dropped presets and instead has
`step-05-report` + `step-06-remediate`.

- **Recommendation [CODE]:** add back a **preset** concept as drop-in
  `references/presets/*.yaml` (each a named bundle of read-only checks) and a
  `step-05-preset.md`, then renumber report→`step-06`, remediate→`step-07`. This
  restores the book's structure and the "add a preset, no code change" extensibility
  story your style favours. **[BOOK]** then add report + remediate steps to Ch4/Ch5
  layout (they're currently implied, not drawn).

---

## Recommended execution order

1. **[CODE, safe, now]** item 7 (rename dimension → Operations); item 5 `schema.md`;
   item 6 structured findings + `--json` (the big win).
2. **[DECISION]** items 1 + 2 (skill name; cluster-naming reconciliation) — pick a
   direction, then I apply the rename/notes.
3. **[BOOK, hand to manuscript agent]** items 3+4 (DNS sidebar — correctness), item 5
   layout wording, item 8 step list.

The book is strong as prose; the work is making the companion repo *be* what the book
promises, plus one honest correctness sidebar so a reader's lab actually boots.
