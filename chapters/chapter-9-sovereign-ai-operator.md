# Chapter 9 — A Sovereign On-Prem AI Operator: Custom Tools + a Local Model

> **Audit posture:** the agent's tools are **read-only** (no remediate/write tool in
> the image); the only "network" is the in-cluster API via a read-only ServiceAccount.
> The endpoint is **air-tight** — ClusterIP + NetworkPolicy deny-egress + optional token.

> **Who it's for:** regulated / air-gapped / no-egress teams, and anyone who wants to
> **build their own tools + run their own model**. **What you learn:** package an AI
> operator as an installable plugin that runs entirely on your hardware.

## What you build
`spikes/talos-ai-operator/` — one self-contained image, **built → pushed → installed
into Talos**:
- **mochallama as a library** (in-process local LLM, no daemon/JNI) + the **model
  baked in** (Qwen2.5-3B-Instruct GGUF, loaded from a local file → zero runtime network).
- The read-only platform-sre capabilities registered as Spring AI **`@Tool`** methods
  (each execs the matching Python script).
- The starter's OpenAI controller → an **air-tight `POST /v1/chat/completions`**
  ClusterIP service (system+user, tools, SSE) other workloads consume.

## Why it matters
Two jobs, one install: an **on-board SRE agent** (the local model orchestrates the
tools, cites evidence) *and* a **sovereign local-LLM service** for the cluster.
Nothing — platform, data, or the reasoning — leaves the building. This is the book's
finale: everything on your own hardware.

## What is what (artifact map)
| Path | Role |
|---|---|
| `spikes/talos-ai-operator/DESIGN.md` | the grounded spec |
| `src/.../SreTools.java` | 8 read-only `@Tool`s → exec the Python capabilities |
| `src/.../AgentConfig.java`, `ReviewController.java` | ChatClient + `POST /review` |
| `src/.../BearerTokenFilter.java` | env-gated air-tight token |
| `Dockerfile` | JDK22 + python3 + kubectl + talosctl + scripts + baked GGUF |
| `helm/talos-ai-operator/` | Deployment + ClusterIP + read-only RBAC + NetworkPolicy + Secret |
| `Taskfile.yml` | build / push (Gitea) / install / smoke |

## Verify / Status
- **Validated:** `gradlew build -x test` (real Maven Central, mochallama 0.1.6),
  `helm lint` + `helm template`, `docker build --call=check`, `task --list`.
- **Needs real hardware:** `task build` (multi-GB GGUF + image), `push`/`install`/`smoke`
  (live cluster; CPU model load takes minutes; usable throughput wants a sized node/GPU).
- Honest caveats in `README.md`/`DESIGN.md`: CPU inference heavy, small-model ceiling,
  multi-GB image, and why **not** a Talos system extension (wrong tool for a multi-GB LLM).
