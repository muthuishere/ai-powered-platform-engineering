# Talos AI Operator — embedded, air-tight, on-prem AI plugin (book Ch9)

A single self-contained plugin you **build, push, and install into a Talos cluster**.
It embeds a local tool-calling LLM (**mochallama**, as a library, model baked in) plus
**all the platform-sre tools**, and exposes an **air-tight OpenAI-compatible endpoint**
so the cluster has both an on-board SRE agent *and* a sovereign local-LLM service —
**no egress, no model download, no external daemon.**

## What it is (two jobs, one install)
1. **On-board SRE agent** — the embedded model orchestrates the platform-sre tools
   (health, reliability, security, certs, vuln, upgrade, report, k8s-worthiness) to
   review the cluster *from inside it*, citing evidence — same guardrails (read-only).
2. **Sovereign local-LLM service** — exposes `POST /v1/chat/completions` (system+user
   messages, `tools[]`, SSE) as a **ClusterIP** service other workloads can call.
   Air-tight: model baked in, NetworkPolicy denies egress, optional bearer token.

## Why mochallama (grounded in its repo)
- **Library, in-process** (Project Panama FFM over llama.cpp) — no sidecar daemon; "all embedded."
- **Local GGUF path** supported (`llamacpp.model.url=file:///models/...gguf` + `filename`,
  precedence over hf-id) → **no network at runtime**.
- **Spring AI adapter** maps `@Tool`/`ToolCallback` → core `ToolDefinition` → tool calling.
- **Starter** autoconfigures the **OpenAI REST controller** (`/v1/chat/completions`, tools, SSE).
- **Tool-calling-only by contract** — rejects non-tool models at load (good: fail-fast).

## The artifact (fat, self-contained image)
```
talos-ai-operator:<tag>   (built, pushed to the in-cluster Gitea registry)
├── JDK 22 runtime                      # mochallama needs FFM (JDK22)
├── Spring Boot agent (this app)
│   ├── mochallama-spring-boot-starter  # OpenAI /v1/chat/completions, in-process
│   ├── mochallama-core-platform        # native llama.cpp libs for linux/<arch>
│   ├── mochallama spring-ai adapter     # @Tool -> ToolDefinition
│   └── SreTools.java                   # @Tool methods, one per capability
├── /models/<model>.gguf                # model BAKED IN (no download) — air-gapped
├── python3 + kubectl + talosctl        # so the @Tool methods can exec our scripts
└── /opt/platform-sre/scripts/*.py      # the existing read-only capabilities, reused
```
Each `@Tool` (e.g. `clusterHealth(cluster)`, `vulnReview(cluster)`) shells out to the
matching read-only Python script and returns its evidence/JSON to the model.

## Locked defaults (vetoable)
- **Registry:** Gitea container registry on `ops` (`build && push` target).
- **Model (lab):** `Qwen2.5-3B-Instruct` GGUF (q4_k_m) baked in — tool-capable, CPU-runnable;
  swap a bigger GGUF for real hardware via one build arg.
- **Tools:** JVM `@Tool` methods exec the existing read-only Python capabilities (reuse all).
- **Air-tight:** ClusterIP only + NetworkPolicy (deny egress, allow in-cluster) + optional
  `Authorization: Bearer` token; read-only ServiceAccount/ClusterRole (get/list/watch).

## Install (Helm / GitOps)
```
helm/talos-ai-operator/
├── Deployment        # the fat image; resources sized for CPU inference
├── Service           # ClusterIP -> :8080 /v1/chat/completions
├── ServiceAccount + ClusterRole(get,list,watch) + binding   # read-only
├── NetworkPolicy     # no egress; ingress from chosen namespaces only
└── Secret (optional) # bearer token
```
Installed via the same ArgoCD/Helm path as Ch5 — `build → push → ArgoCD syncs`.

## Honest caveats (will be stated in the chapter)
- **CPU inference is heavy.** A 3B model runs on CPU but is slow; the 8-node OrbStack lab
  is already strained — the lab demo uses the small model and a single replica; real use
  wants a sized node (or GPU). We'll measure and report, not pretend.
- **Small local models < Claude** at multi-step reasoning — the *tool grounding* carries it;
  scope tasks accordingly.
- **Image is large** (JDK + native libs + python/kubectl/talosctl + baked GGUF, multi-GB) —
  that's the "all embedded / no network" trade you asked for. Pushing it needs the registry.
- **Talos system-extension path** (baking into the node OS image via Image Factory) is the
  *other* meaning of "plugin on Talos" — we deliberately did NOT use it (extensions are for
  small low-level services; a multi-GB LLM belongs in a workload, not the boot image). One
  honest paragraph in the chapter explains why.

## Build & push (Taskfile)
```
task build     # docker build the fat image (model baked via build arg)
task push      # push to the Gitea registry on ops
task install   # helm install / or commit to the GitOps repo for ArgoCD
task smoke     # port-forward + curl /v1/chat/completions + run one tool review
```
