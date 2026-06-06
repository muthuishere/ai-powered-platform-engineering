# Chapter 7 — Bare Metal & the On-Prem Cloud-Native Datacenter

> **Audit posture:** read-only · blast radius = **zero** · **no new skill code.**
> The punchline of this chapter is that there *is* nothing new to build in the
> skill. A bare-metal Talos cluster is just another kube/talos API endpoint —
> `report.py --cluster <any-context>` runs unchanged. The agent doesn't know, or
> need to know, whether the node is a Docker container or a 2U server.

> Everything so far ran against Talos-in-Docker. This chapter takes the same
> declarative platform onto **owned hardware** — cloud-native without the cloud
> bill — and makes the honest TCO argument for it. The lab artifact is a
> provisioning brief + a sample machine config + a fill-in TCO worksheet; the skill
> capability is **none new**, by design.

## What you build

- A **provisioning brief** (`spikes/talos-baremetal/README.md`) — how a server
  iPXE-netboots Talos, pulls a machine config, and joins the cluster; the tooling
  options; and the key note that once joined the node is *just another context*.
- A **sample machine config** (`spikes/talos-baremetal/sample-machineconfig.yaml`)
  — an illustrative, clearly-marked-example Talos config fragment for a metal node:
  install disk, network interface, and the Chapter-1 nameservers patch.
- A **TCO worksheet** (`spikes/talos-baremetal/tco-worksheet.md`) — a fill-in
  model: owned-hardware amortized cost vs the cloud-equivalent column, with a
  worked example on placeholder numbers and an honest "it depends" note.

No new `scripts/*.py`. That absence *is* the chapter's thesis.

## Why it matters (enterprise / audit / agentic)

- **Cloud-native without the cloud bill.** Talos, Kubernetes, GitOps, ArgoCD — the
  entire stack from Chapters 1–6 — runs identically on metal. You keep the
  declarative, immutable, API-driven operating model and drop the managed-k8s
  premium, the per-GB egress, and the always-on compute markup.
- **Talos on metal is genuinely declarative.** A server PXE/iPXE-boots the Talos
  installer, pulls a machine config (the same `machineconfig` object you'd patch in
  the Docker lab), writes itself to disk, and joins. There's still **no SSH** — the
  metal node is an API endpoint exactly like its container cousin. The audit
  property that made the lab safe is the same one that makes the datacenter safe.
- **The TCO argument is real but not a slam dunk.** Owned hardware amortized over
  its life can beat cloud opex *at sustained, high utilization* — but repatriation
  is a trade-off, not a free win: you take on capacity planning, hardware
  lifecycle, power/cooling, remote hands, and the ops burden the cloud used to
  carry. The worksheet makes you write those numbers down honestly. The result
  swings hard on **scale, egress volume, and utilization**.
- **The agent is what makes on-prem safe for a small team.** Repatriation's hidden
  cost is operational headcount. An evidence-grounded, read-only SRE agent —
  health, reliability, security, certs, vulnerability, and GitOps remediation, all
  from Chapters 1–6 — is exactly the leverage that lets a small team run owned
  infrastructure without a 24/7 NOC. The agent doesn't care that the cluster is on
  metal; it's the same five-dimension report against a new context.

## What to start

The provisioning flow itself is **not runnable in the Docker lab** — it needs real
NICs, a DHCP/TFTP/HTTP boot environment, and a disk to install to. This chapter is
therefore a **teaching + decision** chapter: read the provisioning brief, study the
sample machine config, and fill in the TCO worksheet for your own numbers. The one
thing you *can* prove with the existing lab: point the skill at any context and
watch it behave identically — that's the whole portability claim.

## How to do it

```bash
# The portability proof — the skill is context-agnostic. Today it's a Docker
# context (dev/staging/prod/ops); on metal it's your real cluster's context.
python3 .claude/skills/platform-sre/scripts/report.py --cluster dev
# → on a bare-metal cluster, the SAME command, a real context name. No code change.
```

Provisioning (teaching-level — see `spikes/talos-baremetal/README.md` for detail):

- The server **iPXE-netboots** the Talos installer image (matchbox / Omni / Sidero
  serves the boot script + kernel/initramfs).
- It **pulls its machine config** (install disk, NIC, nameservers — see
  `sample-machineconfig.yaml`) over HTTP from the provisioner.
- It **installs to disk and joins** the cluster (control-plane bootstrap or worker
  join). From that moment it's a context `talosctl`/`kubectl` address like any other.

Tooling options (covered honestly in the brief):

- **Sidero Omni** — the managed/SaaS-or-self-hosted control plane for Talos fleets
  (easiest path, least DIY).
- **Sidero Metal + Cluster API** — declarative bare-metal provisioning as CAPI
  infrastructure; clusters are Kubernetes objects.
- **matchbox + Cluster API / manual** — the lowest-level, most-DIY iPXE + Ignition/
  machine-config server.

## What is what (artifact map)

| Path | Role |
|---|---|
| `spikes/talos-baremetal/README.md` | provisioning brief — netboot → config → join; tooling options; portability note |
| `spikes/talos-baremetal/sample-machineconfig.yaml` | illustrative metal machine config (install disk + NIC + nameservers) |
| `spikes/talos-baremetal/tco-worksheet.md` | fill-in TCO model: owned-amortized vs cloud-equivalent, worked example |
| `.claude/skills/platform-sre/scripts/report.py` | **unchanged** — runs against the metal context exactly as against dev |

## Verify

- There is **no new script** to verify — the chapter's claim is the *absence* of
  new code. Verification is conceptual + portability:
  - `report.py --cluster <ctx>` is context-agnostic (it already runs against
    dev/staging/prod/ops); a real metal context is just another value.
  - The sample machine config carries the Chapter-1 nameservers patch — the same
    etcd-wedge fix, because the same DNS dependency exists on metal.
  - The TCO worksheet's worked example totals both columns and states the
    break-even depends on utilization/egress/scale.

## Status (built vs stubbed)

- **Built (docs/artifacts):** provisioning brief, sample machine config, TCO
  worksheet — all under `spikes/talos-baremetal/`.
- **Not runnable in the Docker lab (by nature):** the netboot/install/join flow
  needs real hardware + a boot environment; the brief is explicit about this.
- **No skill change — intentional.** The portability of the read-only agent onto
  metal is the deliverable; pointing the existing skill at a metal context is the
  only "new" action, and it needs zero new code.
