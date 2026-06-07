# exp-kubespan-multidc — Talos KubeSpan: one cluster, nodes anywhere

**Experiment:** enable **KubeSpan** (Talos' built-in WireGuard full-mesh) so a
control plane on **Box A** and a worker on **Box B** — different networks / DCs —
form **one Kubernetes cluster** whose node-to-node traffic rides encrypted
WireGuard tunnels. Then measure **cross-node (cross-DC) pod-to-pod latency +
throughput over the mesh**.

> Needs **2 separate boxes**. KubeSpan spans *networks*; on a single host there's
> no second location to span. See [`setup.md`](setup.md). `run.sh` reports the
> cross-DC metrics as `null` (with a reason) when run with <2 boxes — never faked.

## The learning

**KubeSpan = automated WireGuard mesh between the NODES of a single cluster,
wherever those nodes physically are.** You don't hand-roll WireGuard configs,
exchange keys, or maintain a peer list. Two machine-config lines and the cluster
discovery service do it:

```yaml
machine: { network: { kubespan: { enabled: true } } }   # join the mesh
cluster: { discovery: { enabled: true } }               # find the peers
```

How it works (verified, Talos v1.11, 2026-06):
- Each node generates a **WireGuard keypair** — its *KubeSpan identity*
  (`talosctl get kubespanidentities`).
- Nodes register with **cluster discovery** (`discovery.talos.dev`, the *service*
  registry), advertising their public key + reachable endpoints. Discovery only
  ever sees data **encrypted with the cluster trust bundle** — it can't read your
  endpoints or keys.
- Each node uses that to **auto-dial every peer** over **UDP/51820**, forming a
  full mesh. Status: `talosctl get kubespanpeerstatuses` (`state: up`).
- With `advertiseKubernetesNetworks: true`, pod/service CIDRs are routed through
  the tunnels — so **cross-node pod-to-pod traffic is transparently encrypted**
  across the public internet, no CNI overlay gymnastics.

The payoff: **a cluster whose nodes live in different DCs / clouds / on-prem +
cloud**, joined over the open internet, with all inter-node traffic encrypted and
zero manual VPN plumbing. Add a node behind NAT in another region, it joins the
mesh and is reachable.

## KubeSpan is NOT cluster-to-cluster

This is the distinction the book should nail:

| | **KubeSpan** (this spike) | **Cluster Mesh** (Cilium) / **Submariner** |
|---|---|---|
| Scope | **One** cluster, nodes spread across DCs | **Many** clusters, joined together |
| Joins | **node ↔ node** (WireGuard full-mesh) | **cluster ↔ cluster** (service/pod CIDR bridging) |
| Identity | per-node WireGuard keypair | per-cluster identity / shared trust |
| You get | nodes anywhere, one control plane, one etcd | independent clusters sharing some services |
| Failure domain | one cluster (one etcd quorum spans DCs ⚠️) | per-cluster (each survives alone) |

- **KubeSpan**: stretch a *single* cluster across locations. Simplest mental
  model, one control plane — but the etcd quorum now spans the WAN, so latency
  and a partition matter (keep the control-plane majority co-located or accept
  the risk).
- **Cilium Cluster Mesh / Submariner**: keep *separate* clusters (one per DC,
  each with its own etcd) and bridge selected services across them. More moving
  parts, but each cluster has an independent failure domain — usually the right
  answer for true multi-region HA.

Rule of thumb: **KubeSpan to put nodes anywhere in one cluster; Cluster Mesh /
Submariner to connect separate clusters.**

## GTM / GSLB context

Spanning a cluster (or federating clusters) across DCs is the *substrate*; the
*front door* still needs **GSLB (Global Server Load Balancing)** to steer users
to the nearest healthy region — GeoDNS / anycast (Cloudflare, Route 53 latency
routing, etc.) resolving a single hostname to the closest entry point, with
health checks failing traffic away from a dead DC. KubeSpan gets your *nodes*
talking securely across regions; GSLB gets your *users* to the right region. A
multi-DC platform story wants both: KubeSpan/Cluster-Mesh for east-west
(node/service) connectivity, GSLB for north-south (user) routing.

## Files
| path | what |
|---|---|
| [`patches/kubespan.yaml`](patches/kubespan.yaml) | the verified KubeSpan + discovery machine-config patch |
| [`setup.md`](setup.md) | bring up the 2-box cluster with KubeSpan |
| [`scripts/01-gen-config.sh`](scripts/01-gen-config.sh) | gen Talos config with the patch baked in |
| [`scripts/02-patch-existing.sh`](scripts/02-patch-existing.sh) | enable KubeSpan on an already-running cluster |
| [`k8s/`](k8s) | the 2-pod iperf3 app, pinned to opposite nodes (forces a cross-DC path) |
| [`run.sh`](run.sh) | verify mesh → deploy split app → measure latency+throughput → results |
| `results.json` / `RESULTS.md` | metrics (written by `run.sh`) |

## Metrics (`results.json`)
| metric | meaning |
|---|---|
| `peers_count` | KubeSpan peers this node sees (`kubespanpeerstatuses`) |
| `wireguard_established` | `true` iff peers report `state: up` |
| `cross_node_latency_ms` | avg RTT, client pod (Box B) → server pod (Box A), over the tunnel |
| `cross_node_throughput` | iperf3 TCP throughput across the mesh (e.g. `"934 Mbits/sec"`) |

**Honest caveat:** all four require the **2-box** setup. Without it `run.sh`
writes them `null` with a reason in `notes` — no fabricated numbers. Absolute
throughput is bounded by the inter-box link *and* WireGuard's encrypt/decrypt
cost; the **comparison vs a same-DC / no-mesh baseline** is the insight.

## Run
```bash
# after setup.md has a 2-box KubeSpan cluster up and kubectl/talosctl pointed at it
./run.sh
cat results.json
./run.sh --teardown
```
