# Talos on bare metal — provisioning brief

> **Teaching artifact, not a runnable lab.** The Docker lab in
> `spikes/talos-gitops/` is the live substrate for Chapters 1–6. This directory
> backs **Chapter 7** — taking the *same* declarative platform onto owned hardware.
> The netboot/install/join flow below needs real NICs, a DHCP/TFTP/HTTP boot
> environment, and a disk to install to — none of which the Docker provisioner has.
> So this is a brief to *understand* and a config + worksheet to *fill in*, not a
> `./create.sh`.

The whole point of the chapter: once a metal node has joined, it is **just another
context**. `talosctl --context <metal>` and `kubectl --context <metal>` address it
like any other, and the `platform-sre` skill — `health.py`, `reliability.py`,
`security_drift.py`, `certs.py`, `vuln.py`, `report.py`, `remediate.py` — runs
against it **unchanged**. There is no bare-metal-specific skill code, by design.

## How a server becomes a node

1. **iPXE netboot.** The server is configured (BIOS/UEFI, or a chained iPXE) to
   network-boot. A provisioner on the LAN serves the Talos installer over
   DHCP → TFTP/HTTP: the boot script points at the Talos `kernel` + `initramfs`.
2. **Pull the machine config.** The booted installer fetches its machine config
   (over HTTP from the provisioner, or handed to it by the control plane). That
   config is the same kind of `machineconfig` object you patch in the Docker lab —
   it declares the **install disk**, the **network interface(s)**, the
   **nameservers**, and whether the node is a **controlplane** or a **worker**. See
   [`sample-machineconfig.yaml`](sample-machineconfig.yaml).
3. **Install to disk + join.** Talos writes its immutable image to the install
   disk, reboots into it, and joins: the first controlplane node **bootstraps
   etcd**; further nodes join as controlplane or worker. From here on there is
   **no SSH** — the node is a Talos API endpoint, exactly like its container cousin.
4. **It's now a context.** Add it to your `talosconfig`/`kubeconfig` and the agent
   addresses it by context name. `report.py --cluster <that-context>` works
   immediately.

## The nameservers note (same etcd-wedge fix as Chapter 1)

The Docker lab's hard-won fix — pin `nameservers` so the node can resolve
`registry.k8s.io` and pull etcd, or etcd wedges in "Waiting" forever — applies on
metal too. If your provisioning network has no usable DNS handed out by DHCP, set
`machine.network.nameservers` explicitly in the machine config (the sample does
this). Same dependency, same fix, different substrate.

## Tooling options (DIY ↔ managed)

| Tool | What it is | Trade-off |
|---|---|---|
| **Sidero Omni** | Managed (SaaS or self-hosted) control plane for Talos fleets — registration, machine config, updates, secure wireguard mgmt plane | Easiest path, least DIY; a product to adopt |
| **Sidero Metal + Cluster API** | Declarative bare-metal provisioning as **Cluster API** infrastructure — servers and clusters are Kubernetes objects, reconciled | Fully declarative/GitOps-able; you run the CAPI management cluster |
| **matchbox + Cluster API / manual** | Lowest-level iPXE + machine-config/Ignition server; you wire DHCP/TFTP/HTTP yourself | Most control, most plumbing; good for learning the primitives |

All three end at the same place: a Talos node that joined via a declarative
machine config and is now an ordinary API endpoint.

## What is honestly NOT here

- **No live boot environment.** No DHCP/TFTP/HTTP server, no real NICs, no install
  disk — the Docker provisioner can't model PXE. Don't expect a runnable script.
- **No secrets.** The sample machine config is illustrative and explicitly
  non-secret (no real CA, tokens, or cluster endpoint). Real configs carry the
  cluster CA + bootstrap token and must be handled accordingly.
- **No TCO numbers for you.** [`tco-worksheet.md`](tco-worksheet.md) is a fill-in
  model with placeholder numbers and an honest "it depends on scale, egress, and
  utilization" caveat — not a verdict.

## Where to look next

- [`sample-machineconfig.yaml`](sample-machineconfig.yaml) — illustrative metal
  machine config: install disk + NIC + nameservers, with comments.
- [`tco-worksheet.md`](tco-worksheet.md) — owned-amortized vs cloud-equivalent,
  worked example.
- `chapters/chapter-7-bare-metal.md` — the agent-facing chapter brief.
