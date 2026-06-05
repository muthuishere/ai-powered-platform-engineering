#!/usr/bin/env bash
# Shared configuration + helpers for the Talos GitOps spike.
# Source this from every numbered script:  source "$(dirname "$0")/lib.sh"
set -euo pipefail

# ---------------------------------------------------------------------------
# Cluster topology
# ---------------------------------------------------------------------------
# Talos' Docker provisioner gives every cluster ONE control-plane node plus
# N workers, each as a Docker container on a per-cluster bridge network.
# We carve a distinct /24 for each cluster so the bridges never collide.
# The provisioner auto-publishes each cluster's API on a RANDOM high host port
# and writes it into kubeconfig — so there's no 6443 collision to manage.
#
#   name        subnet          role
#   ----        ------          ----
#   ops         10.5.0.0/24     hub: Gitea + ArgoCD
#   workload-1  10.5.1.0/24     spoke
#   workload-2  10.5.2.0/24     spoke
#   workload-3  10.5.3.0/24     spoke

# "name:subnet"
CLUSTERS=(
  "ops:10.5.0.0/24"
  "workload-1:10.5.1.0/24"
  "workload-2:10.5.2.0/24"
  "workload-3:10.5.3.0/24"
)

WORKLOAD_CLUSTERS=(workload-1 workload-2 workload-3)
OPS_CLUSTER="ops"

# Every cluster: 1 control-plane + 1 worker (2 nodes each, 8 containers total).
# Right-sized for a laptop — 12 nodes wedged the Docker engine under OrbStack.
WORKERS_PER_CLUSTER=1

# Memory (MiB) per node. These are Docker caps, not reservations — OrbStack only
# uses what's touched, but a cap must be high enough that Prometheus won't OOM.
CP_MEM=3072
WK_MEM=4096      # workers host the platform stack (Prometheus tuned small)

K8S_VERSION=1.36.1

# ---------------------------------------------------------------------------
# Helpers
# ---------------------------------------------------------------------------
log()  { printf '\033[1;34m==>\033[0m %s\n' "$*"; }
warn() { printf '\033[1;33m!! \033[0m %s\n' "$*"; }
die()  { printf '\033[1;31mxx \033[0m %s\n' "$*" >&2; exit 1; }

# kubectl/talosctl context names that the Docker provisioner generates.
kube_ctx()  { echo "admin@$1"; }          # e.g. admin@ops
k()         { local c="$1"; shift; kubectl --context "$(kube_ctx "$c")" "$@"; }

# Field accessors for a CLUSTERS entry ("name:subnet").
c_name()   { echo "${1%%:*}"; }
c_subnet() { echo "${1##*:}"; }

# Control-plane container name the provisioner creates: <cluster>-controlplane-1
cp_container() { echo "$1-controlplane-1"; }
# Bridge network name the provisioner creates for a cluster.
net_name()     { echo "$1"; }

# ---------------------------------------------------------------------------
# Hub services (run on the ops cluster)
# ---------------------------------------------------------------------------
ARGOCD_NS=argocd
GITEA_NS=gitea
GITEA_USER=gitops
GITEA_PASS=gitops-admin-123          # spike only — not a secret
GITEA_REPO=platform
# In-cluster URL ArgoCD uses to pull the GitOps repo from Gitea.
GITOPS_REPO_URL="http://gitea-http.${GITEA_NS}.svc.cluster.local:3000/${GITEA_USER}/${GITEA_REPO}.git"
# Label that marks a registered cluster as a deploy target (cluster generator).
TARGET_LABEL_KEY=environment
TARGET_LABEL_VAL=workload

require() { command -v "$1" >/dev/null 2>&1 || die "missing required tool: $1"; }

SPIKE_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
export SPIKE_ROOT
