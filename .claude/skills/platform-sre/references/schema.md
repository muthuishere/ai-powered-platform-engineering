# Resource schema — what the capabilities read

A quick reference to the Kubernetes + Talos resources platform-sre inspects and
the exact fields each finding is grounded in. Everything here is **read-only**;
these are the evidence sources behind the findings.

## Kubernetes resources

| Resource | Read by | Fields that drive findings |
|---|---|---|
| `nodes` | health | `.status.conditions[type=Ready].status` |
| `pods` (kube-system) | health | `.status.phase` (Running/Succeeded) |
| `deployments`, `statefulsets` | reliability | `.spec.replicas`; `.spec.template.spec.containers[].livenessProbe` / `.readinessProbe` / `.resources.limits` |
| `poddisruptionbudgets` | reliability | presence in the workload's namespace |
| `pods` (all ns) | security | `.spec.containers[].securityContext.privileged`; `.spec.securityContext.runAsNonRoot` / container-level; `.spec.hostNetwork` / `.spec.hostPID`; `.spec.volumes[].hostPath` |
| `namespaces` | security | a namespace with **0** `networkpolicies` |
| `networkpolicies` | security | count per namespace |
| kubeconfig client cert | certs | `.users[].user.client-certificate-data` → `notAfter` |
| kube-apiserver serving cert | certs | live TLS handshake → `notAfter` |

## Talos resources (via `talosctl`)

| Query | Read by | Signal |
|---|---|---|
| `health` | health | Talos's own cluster-health verdict |
| `etcd status` | health | etcd member present + healthy (the least-forgiving component) |
| `services` | health | `etcd` / `kubelet` / `apid` service health |
| `version` | vuln | running Talos node version (currency vs a floor) |

## Vulnerability sources (vuln.py)

| Source | Signal |
|---|---|
| `talosctl version` (Server Tag) | Talos version currency vs `--min-talos` floor |
| `nodes[].status.nodeInfo.kubeletVersion` | Kubernetes version currency vs `--min-k8s` floor |
| `pods[].spec.containers[].image` (+ initContainers) | image refs → mutable `:latest` (high), un-allow-listed registry (medium), not-digest-pinned (`--require-digests`) |
| `trivy`/`grype` image scan (optional) | per-image HIGH/CRITICAL CVE counts + ids (skipped if no scanner) |

## Finding shape

Every finding the capabilities emit is a structured object (see `scripts/kube.py`):

```json
{
  "id": "single-replica-and-no-poddisruptionbudget-node-drain-outage",
  "severity": "high",                 // critical | high | medium | low | info
  "summary": "demo/web: single replica AND no PodDisruptionBudget (node drain = outage)",
  "evidence": "Deployment/web replicas<=1 and 0 PDBs in ns demo",
  "proposed_fix": "add a PodDisruptionBudget (minAvailable: 1) — see remediate.py --fix missing-pdb"
}
```

`--json` on any capability emits `{cluster, dimension, count, findings[]}` ranked
worst-severity-first. A finding without traceable `evidence` is a bug, not a
feature — the reasoning layer drops anything it cannot cite.

## Namespaces the reviews skip

`reliability` and `security` skip platform/system namespaces that legitimately
need elevated access or aren't tenant workloads: `kube-system`, `kube-public`,
`kube-node-lease`, and (for reliability) `argocd`, `gitea`.
