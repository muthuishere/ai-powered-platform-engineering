# exp-probe-failure — the "delete-and-readd 120 pods" anti-pattern, measured

> Hari's war story. A team kept manually deleting and re-adding pods every time
> the app went sick — at one point cycling all ~120 pods by hand — because
> Kubernetes happily kept sending traffic to a broken pod and never restarted
> it. The root cause was boring: **no liveness or readiness probes.** This spike
> reproduces that world on a real Talos cluster and puts numbers on it.

## The point

Without probes, **Kubernetes cannot tell a sick pod from a healthy one.**

- No **readiness** probe → a sick replica stays in the Service's endpoint list,
  so the load balancer keeps routing real traffic to it. Users keep getting 500s.
- No **liveness** probe → the sick container is never restarted, so it never
  self-heals. The pod sits there broken forever.

When both are missing, the only lever a human has is the crude one: *delete the
pod and hope the replacement is healthy.* Repeat for every broken pod. That
manual "delete and re-add everything" reflex **is the absence of probes** — it's
a human doing, badly and by hand, the job a readiness+liveness probe does
automatically and in seconds.

This is the exact gap the book's `reliability.py` flags: `no livenessProbe` /
`no readinessProbe` findings on a Deployment.

## Design

The **same** stateless HTTP app is deployed **twice** behind two Services, so the
*only* independent variable is the probe configuration:

| | Deployment | readiness | liveness |
|---|---|---|---|
| **A** | `app-with-probes` | `GET /healthz` (period 2s) | `GET /healthz` (period 3s) |
| **B** | `app-without-probes` | — none — | — none — |

The app (a ~60-line Python `http.server`, mounted from a ConfigMap into a stock
`python:3.12-slim` image — no image to build, no registry needed) serves:

- `GET /` — the "work" endpoint the traffic loop hits; `200` healthy, `500` sick.
- `GET /healthz` — what the probes hit; `200` healthy, `500` sick.
- `GET /break` — flips this **one** replica into "sick" (process-local flag), so
  every subsequent `/` and `/healthz` returns `500`.

`run.sh` then:

1. Rolls out both variants (3 replicas each) plus an in-cluster **traffic loop**
   pod that curls both Services every ~0.2s and logs `OK`/`FAIL` with timestamps.
2. Baselines traffic (expect ~0 failures).
3. **Induces failure:** `GET /break` on one specific pod IP per variant.
4. Measures over a window, then writes results.

## What it measures (`results.json`)

| key | meaning |
|---|---|
| `with_probes_bad_traffic_s` / `without_probes_bad_traffic_s` | seconds the broken replica kept receiving traffic after the break (last failed request − break time) |
| `with_probes_failed_requests` / `without_probes_failed_requests` | failed requests **after** the break |
| `liveness_restarts.with_probes` / `.without_probes` | `restartCount` on the broken pod — did it self-heal? |

Plus `evidence` (broken pod names, whether each broken pod is *still* a Service
endpoint). All numbers are **measured live** — nothing is fabricated; anything
unmeasurable stays `null` with a reason in `notes`.

**Expected shape of the result** (the comparison is the lesson, not the absolutes):
with probes → tiny bad-traffic window, few post-break failures, `restartCount`
ticks up (self-heal); without probes → bad-traffic window ≈ the whole measurement
window, many failures, `restartCount` stays `0`, broken pod still in endpoints.

## Run it

```bash
# uses the CURRENT kube context (a real Talos cluster); namespace exp-probe-failure
./run.sh

# tune the windows if you want
WINDOW_S=90 BASELINE_S=10 ./run.sh

# clean up
./run.sh --teardown
```

Outputs land beside this file: `results.json`, `RESULTS.md`, and the raw
per-request `traffic.log`.

## Caveats

- Small bare-metal cluster → modest absolute numbers; the **A-vs-B contrast** is
  the value.
- Bad-traffic resolution is bounded by the request interval (0.2s) and the
  readiness period (2s).
- "Sick" is in-memory, so a liveness restart produces a genuinely healthy
  process — which is exactly the self-heal we want to observe.
