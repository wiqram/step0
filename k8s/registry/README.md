# Durable container registry (plan.md R8)

Replaces minikube's ephemeral `registry` addon with a **self-managed registry whose blobs live on
sdb2 (`/mnt/kachra`)**, so a `minikube stop`/crash no longer wipes every pushed image (the
2026-06-16 outage, twice — see `RESTART-RECOVERY.md` N-0006 #2).

## Why the addon couldn't just be patched
The addon Deployment is `addonmanager.kubernetes.io/mode: Reconcile`: a `kubectl patch` to add a
volume is reverted, and the node manifests (`/etc/kubernetes/addons/registry-*.yaml`) are
regenerated on every `minikube start`. So we **disable the addon** and run our own copies (no
Reconcile label). The manifests here are behaviour-identical to the addon — same image digests,
`kube-system` namespace, Service name `registry`, selector `actual-registry:"true"`, and the
`registry-proxy` DaemonSet's `hostPort 5000` — so `172.16.238.2:5000` and the NPM-fronted
`container-registry.traderyolo.com` keep working unchanged. The only addition is a PVC at
`/var/lib/registry`.

## Why sdb2 only activates on a COLD boot
minikube's docker driver binds exactly **one** host dir into the node
(`/mnt/minikube-backups/minikube-mnt → /mnt`, on sdb1) and the bind is **`rprivate`**. sdb2
(`/mnt/kachra`) is a separate disk not in the node, and the driver accepts only one
`--mount-string`. `ensure-registry-store.sh` therefore bind-mounts sdb2's image dir **into** the
minikube-mnt tree on the host (persisted in `/etc/fstab`). Docker bind-mounts are **recursive
(rbind)**, so this nested mount is captured **when the container is created** — but `rprivate`
means a *running* node won't pick it up. Net: it takes effect on the **next cold boot**
(`minikube delete` + `start-scratch.sh`). A warm `minikube stop`/`start` reuses the existing
container, so until the next cold boot the registry still uses the old (ephemeral) store.

## Files
| File | Role |
|------|------|
| `ensure-registry-store.sh` | Host-side: fstab bind `sdb2 → minikube-mnt/container-registry-images`. Run by `start-scratch.sh` **before** `minikube start`. |
| `00-pv.yaml` / `10-pvc.yaml` | hostPath PV (`/mnt/container-registry-images`) + bound PVC. `Retain` + claimRef pin → blobs survive PVC delete. |
| `20-registry.yaml` | Self-managed `registry` Deployment (PVC at `/var/lib/registry`, `Recreate` strategy) + Service. |
| `30-registry-proxy.yaml` | `registry-proxy` DaemonSet — exposes the registry on node `hostPort 5000`. |

## Apply (wired into `start-scratch.sh`)
```bash
k8s/registry/ensure-registry-store.sh      # host bind (before minikube start)
minikube addons disable registry           # stop the ephemeral addon
kubectl apply -f k8s/registry/             # PV, PVC, registry, proxy
```
Then re-push images from the node's docker cache (same as outage recovery):
```bash
minikube ssh -- 'docker push container-registry.traderyolo.com/jenkins-inbound-agent-vik:cloud'
# ...then each app image; see RESTART-RECOVERY.md triage row 3 / HANDOFF §2
```

## Acceptance test (the one that proves R8)
```bash
minikube stop && minikube start
curl -fsS https://container-registry.traderyolo.com/v2/_catalog   # STILL populated
kubectl get po -A | grep -i imagepull                              # none
ls /mnt/kachra/container-registry-images/docker/registry/v2/repositories   # blobs on sdb2
```

## Rollback
```bash
kubectl delete -f k8s/registry/ && minikube addons enable registry
```
(Returns to the ephemeral addon. The fstab bind is harmless to leave; remove the line + `sudo umount`
the dir if reverting fully.)

## Caveat
sdb2 (`/mnt/kachra`) is a separate HDD from the minikube disk, so push/pull blob I/O is slightly
slower than `/var` — the accepted trade for durability.
