# Talos AI Operator — embedded, air-tight, on-prem AI SRE plugin (book Ch9 capstone)

A single self-contained plugin you **build, push, and install into a Talos cluster**.
It embeds a local tool-calling LLM ([**mochallama**](https://github.com/deemwar-products/mochallama),
as a *library*, model baked into the image) plus **all the read-only platform-sre
capabilities**, and exposes an **air-tight OpenAI-compatible endpoint** — so the cluster
gets both an on-board SRE agent *and* a sovereign local-LLM service. **No egress, no model
download, no external daemon.**

See [`DESIGN.md`](DESIGN.md) for the full rationale; this README is the build/run guide.

## Status: proven on real bare metal

This is not a paper design. The image **builds**, the model **loads from the baked-in
GGUF with no network**, the OpenAI endpoint **serves a real completion**, and `/review`
**executed a tool against a live cluster**:

- **Build:** the fat image builds clean — JDK 22 JRE + Spring Boot agent + python3 +
  kubectl + talosctl + the baked GGUF. ~5.31 GB (the model layer dominates). Runs with
  `--enable-native-access=ALL-UNNAMED` for mochallama's Project Panama FFM bridge.
- **Air-gapped model load (confirmed):** the model loads from `/models/<file>.gguf` with
  **no egress**. mochallama's `HuggingFaceModels.downloadIfAbsent` short-circuits on
  `Files.exists(...)` *before* it ever dereferences the `file://` URL, so nothing is
  fetched at runtime. Model **READY in ~3.2s** on the test box.
- **Local completion served:** a real `POST /v1/chat/completions` was answered by the
  in-process local model.
- **Tool executed against the cluster:** the model emitted a structured tool call
  (`clusterHealth({"cluster":"dev"})`, `finish_reason: tool_calls`), and `POST
  /review?cluster=dev` actually ran `health.py` against the live cluster and came back
  with real node/pod data.

Two engineering lessons fell out of getting there — see
[**Two things that bit us**](#two-things-that-bit-us) below.

## What it is

Two jobs, one install:

1. **On-board SRE agent** — the baked-in model orchestrates the read-only platform-sre
   tools (health, reliability, security drift, certs, vuln, upgrade, report,
   k8s-worthiness) to review the cluster *from inside it*, citing evidence. Reach it with
   `POST /review?cluster=dev`, or drive it yourself through the OpenAI endpoint.
2. **Sovereign local-LLM service** — `POST /v1/chat/completions` (system+user messages,
   `tools[]`, SSE) as a **ClusterIP** service other in-cluster workloads can call. The
   model is baked in, a NetworkPolicy denies general egress, and an optional bearer token
   gates it.

### How it's wired (grounded in the mochallama repo)

| Piece | Coordinate (mochallama **0.1.6**) | Role here |
|-------|-----------------------------------|-----------|
| starter | `io.github.deemwario:mochallama-spring-boot-starter:0.1.6` | autoconfigures `LlamaCppService` + the OpenAI `/v1/chat/completions` controller, in-process |
| spring-ai adapter | `io.github.deemwario:mochallama-spring-ai:0.1.6` | maps Spring AI `@Tool`/`ToolCallback` → core `ToolDefinition` → the local model |
| natives | `io.github.deemwario:mochallama-core-platform:0.1.6` (`runtimeOnly`) | prebuilt llama.cpp libs for the image's OS/arch (Project Panama FFM, no JNI) |
| Spring AI | `org.springframework.ai:spring-ai-client-chat` (BOM **1.0.8**) | `ChatClient`/`ChatModel` + the tool-calling API |

The model is loaded **offline** from a local GGUF:
`llamacpp.model.url=file:///models/<filename>` (+ `.filename`) — which takes precedence over
any `hf-id`, so the model is **never** downloaded at runtime. The GGUF is fetched at **image
build time** and baked into `/models`.

`@Tool` methods live in [`SreTools.java`](src/main/java/dev/platformsre/aiop/SreTools.java);
each shells out (via `ProcessBuilder`) to
`python3 /opt/platform-sre/scripts/<x>.py --cluster <c> --json` and returns the JSON. They
are **read-only** — there is deliberately no `remediate` tool (remediation mutates git via a
PR, outside this workload).

## The image (fat, self-contained)

```
talos-ai-operator:<tag>
├── JDK 22 (Temurin)                      # mochallama needs FFM (JDK 22+); run with --enable-native-access
├── Spring Boot agent jar (mochallama embedded)
├── /models/<model>.gguf                  # BAKED IN at build time — air-gapped
├── python3 + kubectl + talosctl          # so the @Tool methods can exec the scripts
└── /opt/platform-sre/scripts/*.py        # the existing read-only capabilities, reused
```

Default model: **Qwen2.5-3B-Instruct (Q4_K_M)** — tool-capable, CPU-runnable. Swap a bigger
GGUF for real hardware via one build arg (`MODEL_URL` + `MODEL_FILENAME`).

## Build → push → install → smoke

All via [`Taskfile.yml`](Taskfile.yml):

```bash
task build     # docker build the fat image (GGUF baked in at BUILD time)
task push      # push to the Gitea container registry on `ops`
task install   # helm upgrade --install (or commit to the GitOps repo for ArgoCD)
task smoke     # rollout wait + port-forward + curl /v1/chat/completions (system+user+tool) + POST /review
```

Override the model or coordinates without editing files:

```bash
task build MODEL_URL=https://huggingface.co/unsloth/Phi-4-mini-instruct-GGUF/resolve/main/Phi-4-mini-instruct-Q4_K_M.gguf \
           MODEL_FILENAME=Phi-4-mini-instruct-Q4_K_M.gguf
task install CONTEXT=admin@dev NAMESPACE=platform-sre TAG=0.1.0
```

Pushing to the in-cluster Gitea registry needs a port-forward first (run in another shell):

```bash
task registry:port-forward   # localhost:3000 -> gitea-http on ops
```

No-cluster validation:

```bash
task lint                    # helm lint + helm template render
./gradlew build -x test      # compile + assemble the fat jar (needs JDK 22)
```

## Install (Helm / GitOps)

[`helm/talos-ai-operator/`](helm/talos-ai-operator/):

- **Deployment** — the fat image; resources sized for CPU inference; non-root,
  `readOnlyRootFilesystem`, dropped caps; readiness/liveness on the Actuator health probes
  (UP only when the model state is **READY**).
- **Service** — ClusterIP → `:8080`.
- **ServiceAccount + ClusterRole(get/list/watch) + binding** — read-only, cluster-wide.
- **NetworkPolicy** — deny general egress (model is baked in); allow ingress only from
  `networkPolicy.allowedNamespaces`; narrowly allow DNS + the Kubernetes API server so the
  read-only tools can `get/list/watch`.
- **Secret (optional)** — bearer token, injected as `AIOP_AUTH_TOKEN` when `auth.enabled`.

Key `values.yaml` knobs: `image.*`, `model.{filename,contextSize,threads,temperature}`,
`auth.{enabled,token,existingSecret}`, `resources`, `networkPolicy.allowedNamespaces`.

Installed via the same ArgoCD/Helm path as Ch5 — `build → push → ArgoCD syncs`.

## Two things that bit us

These two cost the most time getting from "compiles" to "executes a tool against the
cluster." Both are now fixed in the code; if you re-wire this yourself, expect them.

1. **You must run the tool-execution loop yourself.** The mochallama spring-ai adapter
   surfaces the model's tool-call *request* but does **not** run the execute → re-prompt
   loop — a plain `ChatClient.call()` hands you the raw tool call, not the answer. So
   [`AgentConfig`](src/main/java/dev/platformsre/aiop/AgentConfig.java) +
   [`ReviewController`](src/main/java/dev/platformsre/aiop/ReviewController.java) drive it
   explicitly with Spring AI's `ToolCallingManager`: offer the tools with
   `internalToolExecutionEnabled(false)`, execute the requested `@Tool`, append the result
   to the conversation, and call again — capped at `MAX_TURNS` so a confused model can't
   loop forever.

2. **Pin a low temperature or a small model won't emit structured tool calls.** The
   adapter does **not** inherit `llamacpp.model.temperature`; with no temperature on the
   request options it falls back to the core default (0.7), at which a small (1.5B–3B)
   model *narrates the tool call as prose JSON* instead of emitting the structured
   `<tool_call>` the parser detects — so `hasToolCalls()` stays false and the loop never
   fires. `ReviewController` pins `temperature(0.0)` on the call options, which makes
   structured tool-calling deterministic.

> **Honest caveat on small-model summaries.** With a 1.5B model, the wiring, serving,
> and tool execution are all correct, but the model **paraphrases the tool's JSON loosely
> in its final prose** — in one run it summarised the nodes as "node1/node2" when the live
> cluster's node was `cherry-bench-controlplane-1`. The evidence it ran on was real; the
> *summary fidelity* is a model-size limitation. A 3B+ model summarises faithfully. Scope
> the model to the hardware and the fidelity you need.

## Honest caveats

- **CPU inference is heavy.** A 3B Q4 model runs on CPU but is slow (single-digit to ~12
  tok/s per mochallama's own numbers). The 8-node OrbStack lab is already strained — the lab
  demo uses the small model and a single replica. Real use wants a sized node (or GPU).
- **Small local models < Claude** at multi-step reasoning. The *tool grounding* carries it —
  the model's job is to pick the right read-only tool and summarise its JSON evidence, not to
  reason from scratch. Scope tasks accordingly.
- **The image is large** (JDK + native libs + python/kubectl/talosctl + a multi-GB baked
  GGUF). That is the "all embedded / no network at runtime" trade. Pushing it needs the
  registry; the model layer dominates the size.
- **Why not a Talos system extension?** Baking this into the node OS via Image Factory is the
  *other* meaning of "plugin on Talos", and we deliberately did **not** use it. Extensions
  are for small, low-level services that belong in the boot image; a multi-GB LLM with a JVM,
  python, and two CLIs is a *workload*, not part of the OS. It belongs in a Deployment with
  RBAC, a NetworkPolicy, and probes — which is exactly what this chart ships.

## What needs a real (non-lab) machine

- `task build` downloads a multi-GB GGUF and builds a multi-GB image — do it on a box with
  disk + bandwidth, not in CI on a tiny runner.
- `task push` needs the Gitea registry reachable (the `ops` cluster + a port-forward).
- `task smoke` / `task install` need a live Talos cluster; model load on CPU can take minutes,
  which is why the readiness probe `failureThreshold` is generous.
- Actually *running* inference at a usable speed wants a sized node or a GPU; the lab proves
  the wiring, not the throughput.
