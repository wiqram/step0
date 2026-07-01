# Dev-box → prod minikube API access over 10GbE

**Date:** 2026-07-01
**Status:** approved, implementing

## Goal

Let the **dev box** (`10.10.10.2`) reach the **prod minikube** Kubernetes API
(`https://172.16.238.2:8443`) over the dedicated 10GbE point-to-point link, so a
developer can run `kubectl` and use **IntelliJ Services → Kubernetes** against the
prod cluster from the dev machine.

Scope is **API-only**: just TCP `8443` to the API server. No registry (`:5000`) push,
no direct NodePort access, no pod-network reachability. IntelliJ Services (browse
pods/services, logs, `port-forward`) all tunnel through the API server on `8443`, so
API-only is sufficient for it.

## Topology (facts)

| Thing | Value |
|-------|-------|
| 10GbE link | `enp4s0` on prod, `10.10.10.1/30`; dev box is `10.10.10.2` (0.2 ms, direct cable) |
| Prod minikube node / API | `172.16.238.2:8443` on the `5million` docker bridge (`172.16.0.0/16`, gw `172.16.238.1`) |
| Docker bridge iface | `br-<networkid>` — **name changes if `5million` is recreated** (start-scratch recreates it), so firewall rules must NOT pin the bridge name |
| API cert SANs | already include `IP Address:172.16.238.2` → TLS validates from the dev box, no cert regen needed |
| `net.ipv4.ip_forward` | already `1` on prod (docker keeps it on) |
| prod→dev SSH | **not currently reachable** (22/2222/22022 closed on dev) → dev-box side delivered as copy-paste |

## Why the firewall change is the crux

Traffic from `enp4s0` destined for a container on the docker bridge is **cross-interface
forwarded** traffic. Docker's `FORWARD` chain drops such packets by default (only its own
bridge/published-port rules pass). The fix is to ACCEPT this specific flow in the
`DOCKER-USER` chain — Docker never clobbers `DOCKER-USER`, and it is traversed before
Docker's own forward rules.

Return routing needs nothing extra: the prod host has a connected route to `10.10.10.0/30`
via `enp4s0`, and the minikube container's default route is the bridge gateway on the host.

## Components

### 1. Host: `enable-devbox-kube-access.sh` (new, in STEP0 repo)

Idempotent (delete-then-insert so re-runs don't stack duplicates). Parameterised by
`DEV_IP` (default `10.10.10.2`) and `API_IP`/`API_PORT` (default `172.16.238.2`/`8443`).

Rules inserted into `DOCKER-USER`:

```
iptables -I DOCKER-USER -s $DEV_IP -d $API_IP -p tcp --dport $API_PORT -j ACCEPT
iptables -I DOCKER-USER -d $DEV_IP -s $API_IP -p tcp --sport $API_PORT \
         -m conntrack --ctstate ESTABLISHED,RELATED -j ACCEPT
```

Also drops a sysctl file `/etc/sysctl.d/99-devbox-kube-forward.conf` with
`net.ipv4.ip_forward=1` (belt-and-suspenders; docker already sets it at runtime).

### 2. Host: `devbox-kube-access.service` (systemd, installed by an `--install` flag)

`DOCKER-USER` is recreated **empty** whenever dockerd restarts, so the rules must be
re-applied at boot. A oneshot unit ordered `After=docker.service Wants=docker.service`
runs the script on boot. Installed idempotently (`--install` copies the script to a
stable path, writes+enables the unit).

### 3. Host: wire into bootstrap

Call `enable-devbox-kube-access.sh` from `start-scratch.sh` and `restart-minikube.sh`
(after minikube is up) so a cluster rebuild re-arms access, matching the existing
`install-cron.sh` bootstrap pattern.

### 4. Dev box: persistent route (netplan)

Add to the 10GbE interface in `/etc/netplan/*.yaml`:

```yaml
      routes:
        - to: 172.16.238.2/32
          via: 10.10.10.1
```

then `sudo netplan apply`. (Host route, not the whole `/16`, to keep scope tight.)

### 5. Dev box: kubeconfig

On prod: `kubectl config view --flatten --minify` produces a portable, cert-embedded
kubeconfig whose server is already `https://172.16.238.2:8443`. Copy it to the dev box
and merge as a **`prod-minikube`** context in `~/.kube/config`. IntelliJ Services
auto-discovers `~/.kube/config` contexts.

## Acceptance

1. From dev box: `kubectl --context prod-minikube get ns` lists the prod namespaces.
2. IntelliJ Services → Kubernetes shows the `prod-minikube` cluster and its pods.
3. After a prod reboot, both still work with no manual step (systemd unit re-applies).

## Security note

The exported kubeconfig carries **cluster-admin** credentials. Acceptable here because
the link is a single-peer /30 cable to one trusted dev machine. Recorded explicitly; if
the trust model changes, issue a scoped RBAC ServiceAccount token instead.

## Non-goals

- Registry push / NodePort / pod-network access from the dev box.
- Exposing the API on the general LAN (`enp6s0`/`192.168.50.0/24`) — 10GbE link only.
