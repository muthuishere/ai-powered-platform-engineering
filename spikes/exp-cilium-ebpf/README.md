# exp-cilium-ebpf — Cilium (eBPF) on Talos: kube-proxy replacement, L7 policy, Hubble

This spike swaps the Kubernetes dataplane from the classic `iptables`/kube-proxy
model to **Cilium**, whose dataplane is **eBPF** programs running inside the Linux
kernel. It then shows the two things eBPF buys you that iptables can't: **Layer-7
(HTTP-aware) network policy** and **Hubble**, flow-level observability of every
connection in the cluster.

## The learning

### eBPF as a "programmable kernel" — flag the metaphor

The popular line is *"eBPF turns the kernel into a programmable platform."* It's a
useful mental model and it's **mostly** true — but flag it, don't swallow it whole:

- **What's real:** eBPF lets you load small, verified programs into kernel hooks
  (sockets, tc/XDP, kprobes) that run on every packet/syscall at near-native speed,
  *without* recompiling the kernel or loading a kernel module. Cilium attaches eBPF
  to the network path so service routing, load-balancing, and policy decisions happen
  in-kernel instead of as a giant linear `iptables` chain that grows O(services).
- **Where the metaphor leaks:** it is **not** "arbitrary code in ring 0." Every eBPF
  program goes through the in-kernel **verifier** — bounded loops, no arbitrary memory
  access, must provably terminate. You program *within a sandbox the kernel polices*,
  using a fixed instruction set and a fixed menu of helper functions and hook points.
  So: programmable, yes; a free-for-all kernel module, no. That sandbox is exactly why
  it's safe enough to ship in CNIs, observability agents, and security tools.

### Cilium dataplane

Cilium replaces kube-proxy: instead of kube-proxy writing iptables/IPVS rules for
every Service, Cilium's eBPF programs implement service load-balancing and NAT in
the kernel hook path. Benefits: routing cost stays ~flat as Service count grows,
each pod gets a stable **identity** (derived from its labels, not its ephemeral IP),
and policy is enforced on identity rather than IP — which is what makes it survive
pod churn.

### L7 policy + Hubble

- **L7 policy:** a normal `NetworkPolicy` is L3/L4 ("pod A may talk to pod B on :80").
  A **`CiliumNetworkPolicy`** can go to **L7**: *"pod A may only `GET /public` on pod
  B, everything else is denied."* Cilium does this by transparently steering matched
  traffic through a node-local **Envoy** proxy. A denied request returns **HTTP 403**
  (the L4 connection is allowed; the L7 request is refused) — so you assert on the
  status code, not a connection reset.
- **Hubble** is Cilium's observability layer: because the dataplane already sees every
  flow in eBPF, Hubble can export those flows (source/dest identity, verdict, L7 verb +
  path) with no sidecars and near-zero app changes. `hubble observe` is effectively
  `tcpdump` at the level of Kubernetes identities and HTTP verbs.

### This isn't niche — the big clouds already run Cilium

- **GKE Dataplane V2** is Cilium/eBPF under the hood.
- **AKS** offers Azure CNI **powered by Cilium**, and its "Advanced Container Networking
  Services" L7 policies are Cilium L7.
- EKS, OpenShift, and most Talos/bare-metal stacks deploy Cilium directly.

So the eBPF dataplane is the mainstream direction, not a homelab curiosity.

## kube-proxy-replacement on Talos — the honest nuance

Talos has a documented Cilium install. The catch that most blog posts gloss over:

**True `kubeProxyReplacement=true` requires the cluster to have been *created without*
kube-proxy and *without* a default CNI.** That is a Talos **machine-config** decision,
applied at cluster-creation time (and a reboot), not a flag you flip on a running
cluster:

```yaml
cluster:
  network:
    cni:
      name: none        # don't install Flannel; Cilium will be the CNI
  proxy:
    disabled: true      # don't run kube-proxy; Cilium replaces it
```

With that in place, Cilium points at Talos's **KubePrism** API endpoint — reachable
on every node at `localhost:7445` — via `k8sServiceHost=localhost` /
`k8sServicePort=7445`, and installs with `kubeProxyReplacement=true`.

**On a cluster that already runs kube-proxy + Flannel** (which is the default Talos
bootstrap, and what the lab cluster this spike was authored against actually is), you
**cannot** cleanly flip KPR from a workload script — deleting kube-proxy and rewriting
the CNI mid-flight tears out the live dataplane. The honest options are:

1. **Recreate** the cluster with the machine config above, then run with `CILIUM_KPR=true`
   to get the real kube-proxy-replacement path. *(Recommended for the book's headline.)*
2. **Additive mode** (this spike's default when kube-proxy is detected): install Cilium
   with `kubeProxyReplacement=false` so it coexists; kube-proxy still does Service
   routing, Cilium provides CNI + L7 + Hubble. The L7/Hubble demo is identical; only the
   "who load-balances Services" answer differs. `install-cilium.sh` **auto-detects** this
   and records the actual mode in `results.json`.

> Note also: modern Cilium dropped the old `partial`/`probe` values — `kubeProxyReplacement`
> is now `true`/`false`.

## What's in here

```
install-cilium.sh        Helm install of Cilium 1.18.0 + Hubble, Talos-recommended values
                         (KubePrism endpoint, dropped SYS_MODULE cap, manual cgroup root);
                         auto-detects KPR vs additive mode. --uninstall to remove.
run.sh                   install -> wait ready (cilium status / kubectl) -> deploy demo ->
                         L7 test (allow /public, deny /admin) -> Hubble flow count ->
                         pod-to-pod throughput -> results.json + RESULTS.md. --teardown.
k8s/
  00-demo-namespace.yaml exp-cilium-ebpf namespace
  10-demo-app.yaml       server (nginx: /public + /admin both 200) + client (curl) + Service
  20-l7-policy.yaml      CiliumNetworkPolicy: app=client may only GET /public on app=server
```

## Run it

```bash
# Default (additive mode if the cluster still has kube-proxy; KPR if not):
./run.sh

# Real Talos kube-proxy-replacement (cluster created with cni:none + proxy.disabled):
CILIUM_KPR=true ./run.sh

# Tear down the demo (leave Cilium):
./run.sh --teardown
# Remove Cilium itself:
./install-cilium.sh --uninstall
```

`cilium` CLI and `hubble` CLI are optional. If `cilium` is present, `run.sh` uses
`cilium status --wait` as the readiness gate and `cilium hubble port-forward` +
`hubble observe` for the flow count; otherwise it falls back to `kubectl rollout`
and records `hubble_flows: null` with a reason. Install them with:

```bash
# macOS
brew install cilium-cli hubble
```

## Metrics (`results.json`)

| key | meaning |
|---|---|
| `l7_allow_ok` | `GET /public` returned 200 through the L7 policy |
| `l7_deny_blocked` | `GET /admin` returned 403 (Envoy L7 deny) |
| `hubble_flows` | flow count Hubble reported for the demo namespace |
| `pod2pod_throughput_or_latency` | sequential `GET /public` requests/sec (a req/s proxy, not raw Gbps) |

Numbers are **measured, never fabricated** — any metric we can't measure stays
`null` with a reason in `notes`.

## Sources (verified, 2026)

- [Sidero Labs — Deploy Cilium CNI on Talos](https://docs.siderolabs.com/kubernetes-guides/cni/deploying-cilium)
- [Cilium — Layer 7 Policies](https://docs.cilium.io/en/stable/security/policy/layer7/)
- [Cilium — Installation using Helm](https://docs.cilium.io/en/stable/installation/k8s-install-helm/)
- [Cilium blog — Application-Aware (L7) Security Policies](https://cilium.io/blog/2025/05/20/cilium-l7-policies/)
- [How to Replace kube-proxy with Cilium on Talos Linux (2026)](https://oneuptime.com/blog/post/2026-03-03-replace-kube-proxy-with-cilium-on-talos-linux/view)
