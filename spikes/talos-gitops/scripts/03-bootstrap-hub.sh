#!/usr/bin/env bash
# Bootstrap the OPS cluster as the GitOps hub:
#   1. Install ArgoCD            (argocd ns)
#   2. Install Gitea (sqlite)    (gitea ns)   — in-cluster git server
#   3. Seed Gitea: user + public 'platform' repo, push this spike's gitops/ tree
#   4. Apply the App-of-Apps root → ArgoCD starts reconciling from Gitea
#
# Idempotent: re-running skips installs that are already present and force-pushes
# the latest gitops/ content.
source "$(dirname "$0")/lib.sh"

require kubectl
require git
require curl
OPS_CTX="$(kube_ctx "$OPS_CLUSTER")"        # admin@ops
ARGOCD_VERSION="v2.13.2"

kubectl --context "$OPS_CTX" get nodes >/dev/null 2>&1 \
  || die "ops cluster not reachable on context $OPS_CTX — run 01 first"

# ---------------------------------------------------------------------------
# 1. ArgoCD
# ---------------------------------------------------------------------------
log "installing ArgoCD ($ARGOCD_VERSION) into ns/$ARGOCD_NS"
kubectl --context "$OPS_CTX" create namespace "$ARGOCD_NS" \
  --dry-run=client -o yaml | kubectl --context "$OPS_CTX" apply -f -
kubectl --context "$OPS_CTX" -n "$ARGOCD_NS" apply \
  -f "https://raw.githubusercontent.com/argoproj/argo-cd/${ARGOCD_VERSION}/manifests/install.yaml"

# ---------------------------------------------------------------------------
# 2. Gitea (single replica, sqlite, ephemeral — spike only)
# ---------------------------------------------------------------------------
log "installing Gitea into ns/$GITEA_NS"
kubectl --context "$OPS_CTX" apply -f - <<YAML
apiVersion: v1
kind: Namespace
metadata:
  name: ${GITEA_NS}
---
apiVersion: apps/v1
kind: Deployment
metadata:
  name: gitea
  namespace: ${GITEA_NS}
spec:
  replicas: 1
  selector:
    matchLabels: {app: gitea}
  template:
    metadata:
      labels: {app: gitea}
    spec:
      containers:
        - name: gitea
          image: gitea/gitea:1.22.3
          ports:
            - {containerPort: 3000, name: http}
          env:
            - {name: GITEA__database__DB_TYPE,         value: "sqlite3"}
            - {name: GITEA__database__PATH,            value: "/data/gitea/gitea.db"}
            - {name: GITEA__security__INSTALL_LOCK,    value: "true"}
            - {name: GITEA__server__HTTP_PORT,         value: "3000"}
            - {name: GITEA__server__DOMAIN,            value: "gitea-http.${GITEA_NS}.svc.cluster.local"}
            - {name: GITEA__server__ROOT_URL,          value: "http://gitea-http.${GITEA_NS}.svc.cluster.local:3000/"}
            - {name: GITEA__service__DISABLE_REGISTRATION, value: "true"}
          resources:
            requests: {cpu: 50m, memory: 128Mi}
            limits:   {memory: 512Mi}
          volumeMounts:
            - {name: data, mountPath: /data}
      volumes:
        - name: data
          emptyDir: {}
---
apiVersion: v1
kind: Service
metadata:
  name: gitea-http
  namespace: ${GITEA_NS}
spec:
  selector: {app: gitea}
  ports:
    - {name: http, port: 3000, targetPort: 3000}
YAML

log "waiting for Gitea to become ready..."
kubectl --context "$OPS_CTX" -n "$GITEA_NS" rollout status deploy/gitea --timeout=180s

log "waiting for ArgoCD core components..."
for d in argocd-repo-server argocd-server argocd-applicationset-controller; do
  kubectl --context "$OPS_CTX" -n "$ARGOCD_NS" rollout status "deploy/$d" --timeout=300s
done

# ---------------------------------------------------------------------------
# 3. Seed Gitea: admin user + public repo, push gitops/ tree
# ---------------------------------------------------------------------------
log "creating Gitea user '$GITEA_USER'"
# Must run as the 'git' user — gitea refuses to run as root (which is what a bare
# `kubectl exec` gives you). `su git -c` drops to the right uid.
kubectl --context "$OPS_CTX" -n "$GITEA_NS" exec deploy/gitea -- \
  su git -c "gitea admin user create --username '$GITEA_USER' --password '$GITEA_PASS' \
    --email '${GITEA_USER}@example.com' --admin --must-change-password=false" \
  2>&1 | grep -v "already exists" || true

log "port-forwarding Gitea to localhost:3000"
kubectl --context "$OPS_CTX" -n "$GITEA_NS" port-forward svc/gitea-http 3000:3000 >/dev/null 2>&1 &
PF_PID=$!
trap 'kill $PF_PID 2>/dev/null || true' EXIT
# wait for the tunnel
for _ in $(seq 1 20); do curl -fsS http://localhost:3000/api/v1/version >/dev/null 2>&1 && break; sleep 1; done

log "creating public repo '$GITEA_REPO'"
curl -fsS -u "${GITEA_USER}:${GITEA_PASS}" -X POST \
  -H 'Content-Type: application/json' \
  http://localhost:3000/api/v1/user/repos \
  -d "{\"name\":\"${GITEA_REPO}\",\"private\":false,\"auto_init\":false}" \
  >/dev/null 2>&1 && log "repo created" || log "repo already exists — will force-push"

log "pushing gitops/ tree to Gitea"
TMP="$(mktemp -d)"
cp -R "$SPIKE_ROOT/gitops" "$TMP/gitops"
(
  cd "$TMP"
  git init -q -b main
  git add .
  git -c user.email="${GITEA_USER}@example.com" -c user.name="$GITEA_USER" \
      commit -q -m "platform gitops: app-of-apps + 4 ApplicationSets"
  git remote add origin "http://${GITEA_USER}:${GITEA_PASS}@localhost:3000/${GITEA_USER}/${GITEA_REPO}.git"
  git push -f -q -u origin main
)
rm -rf "$TMP"
kill $PF_PID 2>/dev/null || true; trap - EXIT
log "gitops content is now in Gitea at $GITOPS_REPO_URL"

# ---------------------------------------------------------------------------
# 4. App-of-Apps root
# ---------------------------------------------------------------------------
log "applying App-of-Apps root"
kubectl --context "$OPS_CTX" apply -f "$SPIKE_ROOT/gitops/bootstrap/root-app.yaml"

log "hub bootstrap complete."
log "  ArgoCD admin password:"
kubectl --context "$OPS_CTX" -n "$ARGOCD_NS" get secret argocd-initial-admin-secret \
  -o jsonpath='{.data.password}' 2>/dev/null | base64 -d 2>/dev/null && echo || \
  log "  (initial-admin-secret not present yet; check again shortly)"
log "  UI: kubectl --context $OPS_CTX -n $ARGOCD_NS port-forward svc/argocd-server 8080:443"
log "Next: ./scripts/04-register-clusters.sh"
