#!/usr/bin/env bash
#
# exp-mochallama-minio-operator — model boots from object storage, not the image.
#
# Flow (idempotent, uses the CURRENT kube-context):
#   1. deploy MinIO (StatefulSet + Service + Secret + model-config)
#   2. create the bucket (Job)            -> s3/models
#   3. upload a small tool-capable GGUF   (Job: curl HF -> mc cp into s3/models)
#   4. deploy mochallama (initContainer mc cp s3/models/<model> -> emptyDir /models;
#      app loads file:///models/<model> offline) + ClusterIP service
#   5. wait READY (Actuator readiness flips UP only when the model is loaded)
#   6. port-forward + curl /v1/chat/completions (system + user + a tool call)
#   7. write results.json (model_pull_s, model_load_s, completion_ms) + RESULTS.md
#
#   ./run.sh            # deploy + benchmark
#   ./run.sh --teardown # delete the namespace
#
# No fabricated numbers: every metric we cannot truly measure stays null with a reason.
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
K8S_DIR="${SCRIPT_DIR}/k8s"
NS="exp-mochallama-minio"
SPIKE="exp-mochallama-minio-operator"
KCTL="kubectl"
CLUSTER="$($KCTL config current-context 2>/dev/null || echo "unknown")"
RESULTS_JSON="${SCRIPT_DIR}/results.json"
RESULTS_MD="${SCRIPT_DIR}/RESULTS.md"
PF_PORT="${PF_PORT:-18080}"

log()  { printf '\033[1;36m[%s]\033[0m %s\n' "$SPIKE" "$*"; }
warn() { printf '\033[1;33m[%s] WARN:\033[0m %s\n' "$SPIKE" "$*" >&2; }
die()  { printf '\033[1;31m[%s] ERROR:\033[0m %s\n' "$SPIKE" "$*" >&2; exit 1; }

teardown() {
  log "tearing down namespace ${NS} (context: ${CLUSTER})"
  $KCTL delete namespace "$NS" --ignore-not-found --wait=true
  log "teardown complete"
}

# --- emit results.json + RESULTS.md ----------------------------------------
# args: model_pull_s model_load_s completion_ms reply_chars tool_called notes
write_results() {
  local pull="${1:-null}" load="${2:-null}" comp="${3:-null}" chars="${4:-null}" tool="${5:-null}" notes="${6:-}"
  local model_file ran_at
  model_file="$($KCTL -n "$NS" get configmap model-config -o jsonpath='{.data.MODEL_FILENAME}' 2>/dev/null || echo "unknown")"
  ran_at="$(date -u +%Y-%m-%dT%H:%M:%SZ)"

  cat > "$RESULTS_JSON" <<JSON
{
  "spike": "${SPIKE}",
  "cluster": "${CLUSTER}",
  "model": "${model_file}",
  "model_source": "minio-object-storage",
  "metrics": {
    "model_pull_s": ${pull},
    "model_load_s": ${load},
    "completion_ms": ${comp},
    "reply_chars": ${chars},
    "tool_called": ${tool}
  },
  "notes": "${notes}",
  "ran_at": "${ran_at}"
}
JSON

  cat > "$RESULTS_MD" <<MD
# Results — ${SPIKE}

| field | value |
|-------|-------|
| cluster (context) | \`${CLUSTER}\` |
| model | \`${model_file}\` |
| model source | MinIO object storage (\`s3/models/\`) — **not baked into the image** |
| model_pull_s (MinIO -> initContainer emptyDir) | ${pull} |
| model_load_s (GGUF -> ready, app readiness) | ${load} |
| completion_ms (one /v1/chat/completions round-trip) | ${comp} |
| reply_chars | ${chars} |
| tool_called | ${tool} |
| ran_at | ${ran_at} |

Notes: ${notes:-(none)}

> Metrics that are \`null\` were not measured on this run (see Notes). Numbers are
> measured live by \`run.sh\`, never fabricated.
MD

  log "wrote ${RESULTS_JSON} and ${RESULTS_MD}"
}

# ---------------------------------------------------------------------------
[[ "${1:-}" == "--teardown" ]] && { teardown; exit 0; }

command -v kubectl >/dev/null || die "kubectl not found"
$KCTL cluster-info >/dev/null 2>&1 || die "no reachable cluster for context '${CLUSTER}'"

log "context: ${CLUSTER}"

# 1) MinIO + config + secret -------------------------------------------------
log "applying namespace, secret, config, MinIO"
$KCTL apply -f "${K8S_DIR}/00-namespace.yaml"
$KCTL apply -f "${K8S_DIR}/10-minio-secret.yaml"
$KCTL apply -f "${K8S_DIR}/12-model-config.yaml"
$KCTL apply -f "${K8S_DIR}/11-minio-statefulset.yaml"

log "waiting for MinIO to be ready"
$KCTL -n "$NS" rollout status statefulset/minio --timeout=300s

# 2) bucket Job --------------------------------------------------------------
log "creating bucket (Job: minio-make-bucket)"
$KCTL -n "$NS" delete job minio-make-bucket --ignore-not-found
$KCTL apply -f "${K8S_DIR}/20-bucket-job.yaml"
$KCTL -n "$NS" wait --for=condition=complete job/minio-make-bucket --timeout=180s \
  || { $KCTL -n "$NS" logs job/minio-make-bucket || true; die "bucket job failed"; }

# 3) model-upload Job --------------------------------------------------------
log "uploading model into MinIO (Job: model-upload — downloads GGUF then mc cp)"
$KCTL -n "$NS" delete job model-upload --ignore-not-found
$KCTL apply -f "${K8S_DIR}/21-model-upload-job.yaml"
# Model download can be large; give it room.
$KCTL -n "$NS" wait --for=condition=complete job/model-upload --timeout=1200s \
  || { $KCTL -n "$NS" logs job/model-upload || true; die "model-upload job failed"; }
log "model is in object storage"

# 4) mochallama Deployment + Service ----------------------------------------
log "deploying mochallama (initContainer pulls model from MinIO into emptyDir)"
$KCTL apply -f "${K8S_DIR}/30-mochallama-deployment.yaml"
$KCTL apply -f "${K8S_DIR}/31-mochallama-service.yaml"

# 5) wait READY (model loaded) ----------------------------------------------
log "waiting for mochallama rollout (model pull + CPU load — can take minutes)"
if ! $KCTL -n "$NS" rollout status deploy/mochallama --timeout=1200s; then
  $KCTL -n "$NS" describe deploy/mochallama || true
  $KCTL -n "$NS" logs -l app.kubernetes.io/name=mochallama --all-containers --tail=80 || true
  write_results null null null null null "mochallama rollout did not become READY; metrics not collected"
  die "mochallama never became READY"
fi

# read model_pull_s stamped by the initContainer into the shared emptyDir
POD="$($KCTL -n "$NS" get pod -l app.kubernetes.io/name=mochallama -o jsonpath='{.items[0].metadata.name}')"
MODEL_PULL_S="$($KCTL -n "$NS" exec "$POD" -c operator -- cat /models/.model_pull_s 2>/dev/null || echo "null")"
[[ "$MODEL_PULL_S" =~ ^[0-9]+\.?[0-9]*$ ]] || MODEL_PULL_S="null"
log "model_pull_s (from MinIO): ${MODEL_PULL_S}"

# model_load_s: time from pod Ready-condition vs container start is not cleanly
# exposed; approximate via the app's own log line if present, else leave null.
MODEL_LOAD_S="$($KCTL -n "$NS" logs "$POD" -c operator 2>/dev/null \
  | grep -oiE 'model (loaded|ready)[^0-9]*([0-9]+\.?[0-9]*) ?s' \
  | grep -oE '[0-9]+\.?[0-9]*' | head -1 || true)"
[[ "${MODEL_LOAD_S:-}" =~ ^[0-9]+\.?[0-9]*$ ]] || MODEL_LOAD_S="null"

# 6) curl /v1/chat/completions (system + user + a tool) ----------------------
log "port-forward svc/mochallama ${PF_PORT}:8080"
$KCTL -n "$NS" port-forward svc/mochallama "${PF_PORT}:8080" >/tmp/mochallama-pf.log 2>&1 &
PF_PID=$!
trap 'kill $PF_PID 2>/dev/null || true' EXIT
sleep 3

for i in $(seq 1 30); do
  if curl -fsS "localhost:${PF_PORT}/actuator/health" 2>/dev/null | grep -q '"status":"UP"'; then
    log "endpoint UP"; break
  fi
  sleep 3
done

REQ='{
  "messages":[
    {"role":"system","content":"You are platform-sre, a read-only Talos SRE operator. Use a tool when asked to inspect the cluster."},
    {"role":"user","content":"Check the health of the dev cluster and summarise."}
  ],
  "tools":[{"type":"function","function":{
    "name":"clusterHealth",
    "description":"Run a Talos cluster health sweep. Read-only.",
    "parameters":{"type":"object","properties":{"cluster":{"type":"string"}},"required":["cluster"]}
  }}]
}'

log "POST /v1/chat/completions (system + user + tool)"
T0=$(date +%s.%N)
RESP="$(curl -sS "localhost:${PF_PORT}/v1/chat/completions" \
  -H 'Content-Type: application/json' -d "$REQ" || true)"
T1=$(date +%s.%N)

COMPLETION_MS="null"; REPLY_CHARS="null"; TOOL_CALLED="false"; NOTES=""
if [[ -n "$RESP" ]]; then
  COMPLETION_MS="$(awk "BEGIN { printf \"%.0f\", (${T1} - ${T0}) * 1000 }")"
  REPLY_CHARS="${#RESP}"
  echo "$RESP" | grep -qiE 'tool_call|clusterHealth|"function"' && TOOL_CALLED="true"
  log "completion_ms=${COMPLETION_MS} reply_chars=${REPLY_CHARS} tool_called=${TOOL_CALLED}"
  printf '%s\n' "$RESP" | head -c 600; echo
else
  NOTES="chat completion returned empty; check operator logs"
  warn "$NOTES"
fi

# 7) results -----------------------------------------------------------------
write_results "$MODEL_PULL_S" "$MODEL_LOAD_S" "$COMPLETION_MS" "$REPLY_CHARS" "$TOOL_CALLED" "$NOTES"
log "done. To remove everything: ./run.sh --teardown"
