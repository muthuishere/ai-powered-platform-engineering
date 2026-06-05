# Talos read-only cheat-sheet

The underlying commands the capability scripts wrap. All read-only. Context names:
kube = `admin@<cluster>`, talos = `<cluster>` (e.g. `ops`).

## kubectl (read verbs only)

```bash
kubectl --context admin@ops get nodes -o wide
kubectl --context admin@ops get pods -A
kubectl --context admin@ops get deploy,statefulset -A -o json
kubectl --context admin@ops get pdb -n <ns>
kubectl --context admin@ops get netpol -n <ns>
kubectl --context admin@ops get events -A --field-selector type=Warning
```

## talosctl (health/inspection only)

```bash
talosctl --context ops --nodes 127.0.0.1 etcd status
talosctl --context ops --nodes 127.0.0.1 services
talosctl --context ops --nodes 127.0.0.1 health
talosctl --context ops --nodes 127.0.0.1 get members
talosctl --context ops --nodes 127.0.0.1 dmesg
```

## Certs

```bash
# kubeconfig admin client cert expiry
kubectl config view --raw --minify -o jsonpath='{.users[0].user.client-certificate-data}' \
  | base64 -d | openssl x509 -noout -enddate

# live apiserver serving cert (port from kubeconfig server URL)
echo | openssl s_client -connect 127.0.0.1:<port> 2>/dev/null | openssl x509 -noout -enddate
```

## Lab facts (Docker provisioner on OrbStack)

- Each cluster = 1 control-plane + 1 worker; per-cluster /24 (`ops`=10.5.0.0/24,
  `workload-1`=10.5.1.0/24, …).
- The provisioner auto-publishes each API on a random high host port (written into
  kubeconfig). Container IPs are not host-routable.
- DNS gotcha: Talos-in-Docker comes up with empty `dnsServers`; the create script
  pins 8.8.8.8/1.1.1.1 via `--config-patch` (`spikes/talos-gitops/scripts/patches/dns.yaml`)
  so etcd can pull its image. Without it, etcd wedges and the cluster never bootstraps.
- 12 nodes wedged the Docker engine on this laptop → the lab runs at 1 worker/cluster
  (8 nodes). If `docker ps` hangs, restart OrbStack (`osascript -e 'quit app "OrbStack"'`
  then `open -a OrbStack`).
