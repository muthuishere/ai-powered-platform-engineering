# exp-spiffe-spire — Workload identity & mTLS without a service mesh

**Topic (Hari's):** SPIFFE/SPIRE — give every workload a cryptographic identity by
*attestation* (not by IP, not by a mounted secret), then do mutual TLS keyed on that
identity — with **no service mesh required**.

## The idea in one breath

A workload should not prove "I am 10.5.3.7" or "I hold this static token". It should prove
"I am `spiffe://exp.spiffe/ns/exp-spiffe/sa/spiffe-client/client`", and that proof should be
a short-lived, auto-rotated X.509 certificate it never had to be handed as a secret.

- **SPIFFE** is the spec: a universal identity (`spiffe://trust-domain/path`) and the
  **Workload API** (a local Unix socket) over which a workload fetches its **SVID**
  (SPIFFE Verifiable Identity Document — here an X.509 cert).
- **SPIRE** is the runtime that implements it: a **server** (the CA / registry) and an
  **agent DaemonSet** on every node. The agent does:
  - **node attestation** — proves the node is what it claims (k8s PSAT),
  - **workload attestation** — proves the *pod* is what it claims (asks the kubelet about
    the calling process's pod: namespace, service account, labels),
  before it will hand that pod an SVID.

## What this experiment does

1. Installs SPIRE via the official **helm-charts-hardened** chart (`spiffe/spire`,
   chart `0.28.5` / SPIRE `1.15.1`): server + agent DaemonSet + controller-manager +
   **SPIFFE CSI driver** (mounts the Workload API socket into pods at
   `/spiffe-workload-api` — safer than a hostPath).
2. Registers two workloads with `ClusterSPIFFEID` CRs — **by pod selector**, the
   attestation-native way (`k8s/30-clusterspiffeids.yaml`).
3. Deploys a **server** and a **client** pod (stock `python:3.12-slim`) that use
   **py-spiffe** (`spiffe==0.2.9` + `spiffe-tls==0.3.2`) to fetch their X.509-SVIDs over
   the Workload API and do **mTLS authorized on SPIFFE ID** — `authorize_id(...)`, not
   on DNS/CN/SAN.
4. Deploys an **intruder** pod that mounts the same socket but matches **no**
   `ClusterSPIFFEID` — and shows the agent **refuses to issue it an SVID**.

## Run

```bash
./run.sh             # install → register → deploy → verify → results.json + RESULTS.md
./run.sh --teardown  # remove demo workloads + SPIRE + namespaces
```

Outputs: `results.json` (`svid_issued`, `spiffe_id`, `mtls_ok`,
`unregistered_rejected`, `svid_issue_ms`) and `RESULTS.md`.

## Layout

```
install-spire.sh            helm install of the SPIRE stack (pinned)
run.sh                      orchestrator + verification + metrics
k8s/00-namespace.yaml       exp-spiffe namespace
k8s/10-spire-values.yaml    Helm values: trust domain, className, CSI driver
k8s/30-clusterspiffeids.yaml workload registrations (server + client; intruder absent)
k8s/40-app-code.yaml        demo server/client/intruder as a ConfigMap (py-spiffe)
k8s/50-workloads.yaml       SAs + server Deployment/Service + client/intruder Jobs
```

## The learning

- **Identity by attestation, not by IP or secret.** No long-lived credentials are
  distributed. The pod earns its cert at runtime because the platform can *attest* what it
  is. Rotate-by-default, short TTLs, no secret sprawl.
- **mTLS is mesh-optional.** People reach for Istio/Linkerd to get mTLS. SPIFFE/SPIRE
  gives you the *identity + cert plumbing* directly; two plain pods did mutual TLS with no
  sidecar and no mesh control plane. A mesh can *consume* SPIRE (Istio integrates with it),
  but you don't need one to get cryptographic workload identity.
- **CNCF-graduated.** SPIFFE and SPIRE are CNCF **graduated** projects — the maturity tier
  for production-grade, widely-adopted infrastructure.

## Honest caveat — NOT a NetworkPolicy replacement

SPIFFE/SPIRE answers *"who are you, cryptographically?"* (authentication, and
identity-based authorization at the application/TLS layer). It does **not** control L3/L4
network reachability — an unregistered pod can still send packets at your service; it just
can't complete the mTLS handshake. For network segmentation you still want
**NetworkPolicy** (or your CNI's equivalent). The two are complementary: NetworkPolicy
gates the wire, SPIFFE gates the identity.
