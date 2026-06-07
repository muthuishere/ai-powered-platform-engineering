# exp-mochallama-minio-operator — the model boots from *your* object storage

**Headline:** a mochallama operator whose GGUF model is **pulled from MinIO at
startup**, not baked into the image. One small image, many models; the weights
live in object storage you own. This is the *sovereign operator, model in your
own S3* story.

Namespace: **`exp-mochallama-minio`**. Self-contained — carries its own MinIO.

---

## The pattern: model-from-object-storage vs baked-in

The sibling spike [`talos-ai-operator`](../talos-ai-operator/) bakes the GGUF
into the image at **build** time (`/models/<model>.gguf` via a `MODEL_URL`
build-arg). That gives a fully air-gapped, no-egress runtime — at the cost of a
multi-GB image, a rebuild per model, and a registry that has to carry weights.

This spike keeps the **exact same operator image and app** but changes *where the
model comes from*:

| | baked-in (`talos-ai-operator`) | model-from-S3 (this spike) |
|---|---|---|
| image size | multi-GB (weights inside) | small (no weights) |
| swap the model | rebuild + repush the image | `mc cp` a new GGUF into the bucket, change `model-config`, restart |
| many models | one image per model | **one image, many models** |
| where weights live | the container registry | **your own object storage** (MinIO / S3 / Garage) |
| runtime egress | none | none to the internet — only to in-cluster MinIO |
| air-gapped | yes (registry) | yes (MinIO is *inside* the cluster; nothing leaves) |

Crucially, both are **air-gapped from the public internet at runtime**. The
model never downloads from HuggingFace when the pod starts — it comes from MinIO,
which lives in your cluster. The only place a public URL is touched is the
one-time **`model-upload` Job** that seeds the bucket (and even that URL is
configurable / can be an internal mirror).

The app is unchanged because mochallama always loads the model offline via
`llamacpp.model.url=file:///models/<filename>`. Whether that file was *baked in*
or *pulled from S3 by an initContainer* is invisible to the app.

```
HuggingFace (or internal mirror)
      │  (one-time, model-upload Job: curl -> mc cp)
      ▼
  MinIO  s3/models/<model>.gguf        <-- weights live in YOUR object store
      │  (every pod start, initContainer: mc cp -> emptyDir)
      ▼
  emptyDir /models/<model>.gguf
      │  (app: file:///models/<model>.gguf, offline)
      ▼
  mochallama  POST /v1/chat/completions   (ClusterIP, readiness = model READY)
```

---

## What's in `k8s/`

| file | what |
|------|------|
| `00-namespace.yaml` | namespace `exp-mochallama-minio` |
| `10-minio-secret.yaml` | MinIO root creds + S3 access keys (**lab only**) |
| `11-minio-statefulset.yaml` | MinIO StatefulSet (PVC-backed) + headless Service `minio:9000` |
| `12-model-config.yaml` | **the one knob**: `MODEL_FILENAME`, `MODEL_URL`, bucket, endpoint |
| `20-bucket-job.yaml` | `mc mb s3/models` (idempotent) |
| `21-model-upload-job.yaml` | curl the GGUF from `MODEL_URL`, `mc cp` into `s3/models/` (skips if present) |
| `30-mochallama-deployment.yaml` | **initContainer** `mc cp s3/models/<model> -> emptyDir /models`, then the operator container loads it offline |
| `31-mochallama-service.yaml` | ClusterIP `mochallama:8080` — the sovereign LLM endpoint |

The lab model is **Qwen2.5-1.5B-Instruct (Q4_K_M)** — small, tool-capable,
CPU-runnable. Serve a different model from the **same image** by editing
`12-model-config.yaml` (`MODEL_FILENAME` + `MODEL_URL`) and re-running.

### Reused from `talos-ai-operator`

The operator **image and Spring Boot app are reused as-is** — same
`file://` offline loading, same `@Tool` wiring, same OpenAI-compatible
`/v1/chat/completions`. The only difference is the model **source** (MinIO via an
initContainer, vs baked into `/models`). The deployment overrides the image's
baked `/models` with a shared `emptyDir` the initContainer fills from S3.

> Build/push the operator image first (see `../talos-ai-operator/README.md` —
> `task build && task push`) so `image:` in `30-mochallama-deployment.yaml`
> resolves. Point that `image:` at wherever you pushed it.

---

## Run it

```bash
./run.sh             # deploy MinIO -> bucket -> upload model -> mochallama -> wait READY -> curl
./run.sh --teardown  # delete the namespace
```

Idempotent and uses your **current kube-context** (run against the spike's own
Talos cluster). It writes:

- `results.json` — `{ model_pull_s, model_load_s, completion_ms, reply_chars, tool_called }`
- `RESULTS.md` — the same as a table.

Numbers are **measured live**; anything not measurable on a given run stays
`null` with a reason (no fabricated metrics). `model_pull_s` is stamped by the
initContainer (S3 -> emptyDir copy time) and read back from the running pod.

---

## The learning (for the book)

- **One image, many models.** Decoupling weights from the image means a single
  small operator image serves any GGUF you drop in your bucket — swap models by
  changing object storage, not by rebuilding/repushing multi-GB images.
- **Sovereign, still air-gapped.** "Model from object storage" does **not** mean
  "model from the internet." MinIO (or Garage / any S3) sits inside your cluster;
  the runtime egress story is identical to baked-in. You own the weights at rest.
- **The initContainer is the seam.** It turns "pull from S3" into "a local file,"
  so the inference app stays dumb and offline. Same trick works for any
  file-loading runtime (llama.cpp, vLLM weight dirs, embeddings).
- **Trade-off.** You pay a per-pod-start **model_pull_s** (S3 -> emptyDir) and
  need the object store reachable at schedule time; baked-in pays neither but
  costs image size and a rebuild per model. This spike measures that pull cost so
  the book can put a number on the trade.
- **MinIO caveat.** Community edition was archived Feb 2026; **Garage** is the
  live S3-compatible alternative and is a drop-in swap (same `mc`, same flow).
