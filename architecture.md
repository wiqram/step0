# Private-Cloud Architecture (STEP0)

> Single-node, GPU-accelerated private cloud running on a home workstation.
> `start-scratch.sh` is the master bootstrap script that brings the entire
> stack up from a cold/clean machine.

---

## 1. Physical Host

| Component     | Spec |
|---------------|------|
| Hostname      | `private-cloud` |
| CPU           | Intel Core i9-12900K (8 P-cores + 8 E-cores, 24 threads) |
| GPU           | NVIDIA GeForce RTX 3080 Ti (used for Ollama / LLM inference + CUDA workloads) |
| RAM           | 48 GB |
| Motherboard   | ASUS ProArt Z690 |
| OS            | Ubuntu Linux (kernel 6.8) |
| Storage mount | NFS / disk mount at `/mnt/minikube-backups` (backups + the `minikube-mnt` shared volume) |

Everything below runs on this **one** machine. There is no multi-node cluster —
"private cloud" = Docker + a single-node Minikube + an Nginx reverse proxy, all
co-located.

---

## 2. Layered Stack

```
┌──────────────────────────────────────────────────────────────────────┐
│ HOST (Ubuntu, i9-12900K / 48GB / RTX 3080Ti)                           │
│                                                                        │
│  Docker Engine ── network "5million" (bridge 172.16.0.0/16)            │
│   │                                                                    │
│   ├── nginx-proxy-manager  @ 172.16.238.10  (ports 80/443/81)          │
│   │      (TLS termination, Let's Encrypt, domain → NodePort routing)   │
│   │      + MariaDB sidecar                                             │
│   │                                                                    │
│   └── minikube node        @ 172.16.238.2   (driver=docker)            │
│         12 CPUs · 32 GB · 40 GB disk · --gpus all                      │
│         mount: /mnt/minikube-mnt → /mnt              │
│         insecure-registry 172.16.238.2:5000                            │
│         ┌──────────────────────────────────────────────────────────┐  │
│         │ Kubernetes (single node)                                  │  │
│         │  addons: registry, nvidia-gpu-device-plugin               │  │
│         │                                                           │  │
│         │  PLATFORM:  monitoring (kube-prometheus)                  │  │
│         │             vault       (HashiCorp Vault, Helm)           │  │
│         │             jenkins     (CI/CD)                           │  │
│         │             registry    (in-cluster image registry)      │  │
│         │                                                           │  │
│         │  APPS:      qcguy (Ghost CMS)                             │  │
│         │             yolo / trading-microservices                 │  │
│         │             predictonomy                                 │  │
│         │             helpmepdf                                    │  │
│         │             ollama (quantos/qwen2.5; ds-r1:32b def, GPU) │  │
│         │             splunk (HSBC demo, optional)                 │  │
│         │             tatesremedies (legacy / kvm2)                │  │
│         └──────────────────────────────────────────────────────────┘  │
└──────────────────────────────────────────────────────────────────────┘
```

---

## 3. Networking

### Docker network `5million`
- Driver: bridge, subnet `172.16.0.0/16`, ip-range `172.16.240.0/24`, gateway `172.16.238.1`.
- Created by `start-scratch.sh` if absent.
- **Fixed addresses on this network:**
  - `172.16.238.2`  – Minikube node (Kubernetes API + NodePorts + registry :5000)
  - `172.16.238.10` – nginx-proxy-manager
- There is also a libvirt/KVM equivalent (`5million.xml`, `default.xml`) from an
  earlier `kvm2`-driver design; the active driver is now `docker`.

### Ingress — Nginx Proxy Manager (NPM)
NPM is the single public entrypoint. It terminates TLS (Let's Encrypt) and forwards
each hostname to a Kubernetes **NodePort** on `172.16.238.2`. Current routing table:

| Domain | → NodePort | Service |
|--------|-----------|---------|
| `qcguy.com`, `www.qcguy.com` | 30368 | Ghost CMS (qcguy) |
| `traderyolo.com`, `www.` | 30000 | yolo / trading-microservices |
| `swagger.traderyolo.com` | 30090 | yolo API docs |
| `cert-java.traderyolo.com` | 30443 | yolo cert service |
| `ai.traderyolo.com` | 30072 | AI service |
| `ollama.traderyolo.com` | 30434 | Ollama (streaming, buffering off) |
| `ollamaapi.traderyolo.com` | 30010 | Ollama API (disabled) |
| `vault.traderyolo.com` | 30200 | HashiCorp Vault UI/API |
| `jenkins.traderyolo.com` | 30380 | Jenkins |
| `grafana.traderyolo.com` | 30330 | Grafana |
| `prometheus.traderyolo.com` | 30339 | Prometheus |
| `splunk.traderyolo.com` | 30008 | Splunk web |
| `hec-splunk.traderyolo.com` | 30088 | Splunk HEC |
| `receiving-splunk.traderyolo.com` | 30097 | Splunk receiver |
| `helpmepdf.com`, `www.` | 30001 | helpmepdf |
| `swagger.helpmepdf.com` | 30091 | helpmepdf API docs |
| `container-registry.traderyolo.com` | 5000 | Private image registry |
| `minikube`, `minikube-private-cloud.com` | 8443 | Kube API (HTTPS) |
| `tatesremedies.com`, `www.` | 30369 @ 192.168.39.134 | legacy (old kvm2 IP) |

NPM config/state lives in `~/Ideaprojects/nginx/` (`docker-compose.yml`, `data/`,
`letsencrypt/`). Admin UI on port 81.

### Dev box ↔ prod cluster over 10GbE

There are **two physical machines**, wired point-to-point over a dedicated **10GbE**
link (separate from the household LAN):

| Box | Role | 10GbE NIC / IP | LAN NIC |
|-----|------|----------------|---------|
| **prod** (`private-cloud`) | runs Docker + minikube + everything in this repo | `enp5s0` → `10.10.10.1/30` | `enp7s0` (192.168.50.53) |
| **dev** (`vik@10.10.10.2`) | developer workstation (IntelliJ, builds); **not** part of the cluster | `eno1` → `10.10.10.2/30` | `eno2` (192.168.50.x) |

> ⚠️ **Prod's NIC names shifted on 2026-08-07** — `enp4s0`→`enp5s0` (10GbE) and
> `enp6s0`→`enp7s0` (LAN). Nothing was rewired: installing the GM9000 NVMe pushed every
> PCI bus number up by one (AQC113CS `04:00.0`→`05:00.0`, I225-V `06:00.0`→`07:00.0`), and
> the kernel names interfaces after the bus. **MACs and the DHCP reservation are unchanged.**
> Nothing broke, and that is by design: the firewall rules match dest IP+port and
> `10gbe-link-watchdog.sh` derives the interface from the `/30`, so no code hardcodes a name.
> Treat any `enpXsY` in these docs as a label, not a key — expect it to move again on the next
> PCIe change, and never pin one in a script.

The dev box has **direct `kubectl` access to the prod Kubernetes API** (`172.16.238.2:8443`)
across this link — used from the CLI and from **IntelliJ Services → Kubernetes**. Scope is
**API-only** (no registry/NodePort/pod-network reachability). How it's wired:

- **Prod host firewall** — the API lives on the `5million` docker bridge, so traffic from
  `enp5s0` into it is *forwarded* traffic that Docker's `FORWARD` chain drops by default.
  `enable-devbox-kube-access.sh` inserts two `DOCKER-USER` ACCEPT rules
  (`10.10.10.2 → 172.16.238.2:8443` + established return), matched on **dest IP/port** (never
  the `br-<id>` name, which changes when `5million` is recreated). Persisted by the
  `devbox-kube-access.service` systemd unit (`After=docker.service`; `DOCKER-USER` is wiped on
  docker restart) and re-armed by `start-scratch.sh` / `restart-minikube.sh`.
  ⚠️ **Since Docker 28 those two rules are NOT sufficient on their own** (this box runs 29.7.2).
  Docker now ships **"direct routing" protection**: for every container IP on a user-defined
  bridge it installs `ip daddr <container-ip> iifname != "br-<id>" drop` in **`raw`/PREROUTING**,
  making container IPs unreachable from off-host by default. That chain runs at priority **−300**
  — before conntrack, long before `FORWARD` — so the `DOCKER-USER` ACCEPTs never see the packet.
  `enable-devbox-kube-access.sh` therefore also inserts a `raw`/PREROUTING ACCEPT for the single
  dev→API flow, pinned to the 10GbE iface (derived from the route, never hardcoded) so a LAN host
  can't reach the API by spoofing `10.10.10.2` — rp_filter here is loose (`2`), not strict.
  **The symptom is deeply misleading** (diagnosed 2026-08-07): SYNs arrive on the 10GbE NIC and
  are plainly visible in `tcpdump`, nothing reaches the bridge, `DOCKER-USER` counters sit at
  **0**, and `kubectl` merely times out — while every documented rule, route and link check
  passes. Note a `curl` to the API *from prod* also succeeds and proves nothing: that is
  locally-generated traffic and never traverses the forward path. Go straight to
  `iptables -t raw -L PREROUTING -n -v` and look for the DROP whose counter is climbing.
  The durable fix is recreating the network with
  `-o com.docker.network.bridge.trusted_host_interfaces=<iface>`; it cannot be set on a live
  network, so it waits for a cold bootstrap — see `plan.md`.
- **Dev box route** — a persistent NetworkManager route `172.16.238.2/32 via 10.10.10.1`
  on `eno1` (NM connection `"Wired connection 1"`) forces API traffic over the 10GbE link
  instead of the LAN gateway.
- **Dev box kubeconfig** — a flattened, cert-embedded copy of prod's admin kubeconfig, with
  its cluster/user/context renamed to **`prod-minikube`** so it coexists with the dev box's
  own local `minikube` context. The API cert already carries `IP Address:172.16.238.2` in its
  SANs, so TLS validates unchanged.
  ⚠️ **Re-emit it after every `minikube delete` — the CA is regenerated and the old kubeconfig
  dies silently.** Because the certs are *embedded*, the dev box's copy is a point-in-time
  snapshot: a cluster rebuild rotates the CA and invalidates both the `certificate-authority-data`
  and the client cert, but the file still looks perfectly valid. Symptom is `x509: certificate
  signed by unknown authority` or a bare `Unauthorized`, which reads like a firewall/route fault
  and sends you auditing `DOCKER-USER` and the link — both of which will be fine. Diagnose by
  comparing fingerprints, not by re-checking the network:
  `grep -m1 certificate-authority-data <kubeconfig> | sed 's/.*: //' | base64 -d | openssl x509 -noout -fingerprint`
  against `openssl x509 -in ~/.minikube/ca.crt -noout -fingerprint`. Fix on prod with
  `./enable-devbox-kube-access.sh --emit-kubeconfig`, copy over, then
  `./devbox-connect-prod.sh kubeconfig <file>` to merge. Hit on 2026-08-07 (CA jumped from a
  Jan-2023 `notBefore` to Aug-2026 while the emitted file still dated from Jul 1).
  The merge puts the **incoming file first** in `KUBECONFIG` — first file wins on conflicting
  keys, so the reverse (what it did until 2026-08-07) made a re-emit a silent no-op that kept
  the dead CA while reporting success. It then restores the previous `current-context`, so the
  merge can't quietly make **prod** the default target for bare `kubectl` on the dev box.
  IntelliJ (Services → Kubernetes, Ultimate only) reads `~/.kube/config` but caches it — refresh
  the Services window after a re-merge.
- From-scratch rebuild: prod side is `enable-devbox-kube-access.sh --install`; dev side is
  `devbox-connect-prod.sh` (this repo). The exported kubeconfig is **cluster-admin** —
  acceptable over the single-peer /30 cable.

> Note the `minikube` / `minikube-private-cloud.com` NPM entry above (→ `8443`) is a
> *public/DNS* path to the API; the dev box instead reaches `172.16.238.2:8443` **directly**
> over 10GbE, bypassing NPM.

#### Boot persistence + health check (`devbox-connect-prod.service`)

The dev-box side is **already durable across reboots without the systemd unit**: `eno1` is
`autoconnect=yes` with the static `10.10.10.2/30` and the API route baked into the NM
connection profile, so both come up on boot; the `prod-minikube` kubeconfig is just a file.
On top of that, `devbox-connect-prod.sh install-unit` installs **`devbox-connect-prod.service`**
(oneshot, `After=network-online.target NetworkManager.service ollama.service`,
`WantedBy=multi-user.target`) which runs `devbox-connect-prod.sh boot-check` on every boot to
make access **self-verifying and logged** (`journalctl -u devbox-connect-prod.service`). Each
boot it: (1) self-heals the 10GbE route if NM didn't reapply it, (2) verifies the dev **ollama
endpoint** is serving for prod (see below), (3) waits for the prod API to answer, then (4) logs a
`kubectl --context prod-minikube get ns` result (run as the human user, so it uses their
`~/.kube/config`). It is **advisory** — if prod is down it logs a `WARN` and exits 0 rather than
failing the boot, since a down prod host is not something the dev box can fix.
> **Boot-safety note:** `multi-user.target` is ordered *after* this oneshot, so it must never
> block for long. The installed unit therefore uses a **short** prod-wait (`WAIT_SECS=10`, vs the
> 60s default for manual `boot-check` runs) plus `TimeoutStartSec=45` as a hard backstop — so a
> boot while prod is down adds at most ~10s and can't stall the login. Access itself doesn't
> depend on the wait (the NM route + kubeconfig come up independently); the wait only makes the
> health-check log meaningful.

#### Dev ollama → prod yolo (reverse direction)

prod's **yolo** microservices consume LLM models served by **ollama on the dev box**. `ollama.service`
on dev is `enabled` (auto-starts on boot) and binds the **10GbE IP** (`OLLAMA_HOST=10.10.10.2:11434`),
so prod reaches it directly over the same /30 link — the reverse of the kube-API path above. The dev
box runs no host firewall (`ufw` inactive, `INPUT` policy `ACCEPT`), so nothing blocks
`10.10.10.1 → 10.10.10.2:11434`. The boot-check step above verifies this listener each boot and logs
the model count. **ollama service/model changes are owned by the ollama project (`~/IdeaProjects/ollama-dev`)**,
not this repo — STEP0's boot-check only observes the endpoint. The prod-side wiring (yolo pointing at
`10.10.10.2:11434`, and prod-pod egress/route to the dev box) lives with the yolo app, not here.

**Link stability — `10gbe-link-watchdog.sh`.** Both NICs are Aquantia/Marvell 10GBASE-T
cards on the `atlantic` driver, and this direct point-to-point link intermittently *wedges*:
`ethtool` reports "link detected: yes, 10Gb Full" and `carrier=1` on both ends, yet the
datapath stops passing frames — ARP fails both directions and `kubectl`/IntelliJ from the dev
box hang until it self-recovers minutes later (dev journal shows `atlantic … eno1: atlantic:
link change old 10000 new 0` then `new 10000`). This is a **link/PHY problem, not a
kube-access config fault** — the firewall rule, dev route, and kubeconfig above all work
end-to-end whenever the link is up. `10gbe-link-watchdog.sh` runs as a `systemd` service on
**both** ends: it pings the peer across the /30 and bounces the local NIC (re-training the
link) after a few failed probes, cutting the outage to seconds. It auto-detects the local
10GbE interface + NM connection from the /30, so the same script installs on prod (`enp5s0`)
and the dev box (`eno1`). Install on both: `sudo ./10gbe-link-watchdog.sh --install`.
Bouncing this NIC is safe on either host — it carries only the dev↔prod link (prod's
cluster/LAN and the dev box's LAN/SSH are on separate NICs). If flaps persist, the deeper
remedy is a shorter/better cable or pinning the link to 2.5G/5G (far more cable-tolerant than
10GBASE-T). Out-of-band path to the dev box while 10GbE is dark: `ssh vik@192.168.50.161` (LAN).

### Triggering Jenkins deploys from the dev box

Any app's Jenkins deploy job can be fired **directly from the dev box** — no operator
action on prod required. Unlike kube-API access above, this path does **not** use the
10GbE link: it goes to `https://jenkins.traderyolo.com` through NPM like any public
client (prod runs no sshd, so SSH-back is not an option; verified 2026-07-01).

```bash
# on the dev box — helper (on PATH; master copy is STEP0/devbox-jenkins-deploy.sh)
jenkins-deploy <app>                 # qcguy | predictonomy | bestrentaladmin | dyingpaleblue | ollama | yolo
jenkins-deploy <app> --dry-run       # print the job path without triggering

# equivalent raw curl
source ~/.jenkins-deploy-urls.env    # provides JENKINS_CRED (user:api-token), chmod 600
curl -X POST "https://$JENKINS_CRED@jenkins.traderyolo.com/job/<job>/<endpoint>?token=<build-token>"
```

- **Per-app `<job>/<endpoint>/<build-token>`** come from `jenkins-jobs.manifest` (this
  repo). All apps use `build` except yolo → job `trading-microservices` with
  `buildWithParameters` (omitting params uses the job's defaults).
- **`JENKINS_CRED`** lives canonically in gitignored `STEP0/.env` on prod; the dev-box
  copy at `/home/vik/.jenkins-deploy-urls.env` (chmod 600) was seeded 2026-07-01. If the
  token rotates (plan.md P0 #1), re-seed:
  `grep '^JENKINS_CRED=' ~/Ideaprojects/STEP0/.env | ssh vik@10.10.10.2 'cat > ~/.jenkins-deploy-urls.env && chmod 600 ~/.jenkins-deploy-urls.env'`
- On prod, `jenkins-deploy-url.sh <app>` prints the complete ready-to-curl URL and
  `trigger-app-builds.sh` fires all apps.
- End-to-end validated 2026-07-01: dyingpaleblue triggered from the dev box → HTTP 201 →
  build #68 `SUCCESS` → new `dyingpaleblue-web` pods rolled out.
- **Dev-box AI agents** learn this automatically from the global `/home/vik/.claude/CLAUDE.md`
  (created 2026-07-02): `jenkins-deploy <app>`, push-before-deploy, verify `result:SUCCESS`,
  live-sites caution. If the dev box is ever rebuilt, recreate that file (and re-copy
  `~/bin/jenkins-deploy` + re-seed `~/.jenkins-deploy-urls.env`) alongside `devbox-connect-prod.sh`.

### Dev-box from-scratch rebuild — `restore-scratch-dev.sh` (2026-07-22)

> Operator runbook (daily commands, break-glass inventory + prod recovery copies, DB
> seed, troubleshooting): **`docs/DEV_BOX.md` in the IG-Trading-Microservices repo**.

The dev-box analogue of prod's `restore-scratch.sh`: bootstraps a **fresh Ubuntu
workstation** to a working YOLO dev stack (`./dockerup-dev.sh` 20/20 verify-green) with
no manual steps beyond three break-glass items. Same conventions (set -u, ratcheting
phase marker `~/.yolo-dev-restore-phase`, `--dry-run`, `--from-phase N`); scope is
workstation-only — **no minikube/K8s on dev**. Phases: preflight → toolchain (docker +
compose v2, pinned Go 1.19 + protoc plugins go v1.28.1/go-grpc v1.3.0/gateway v2.11.3,
NodeSource node + grpc-tools, repo `.venv` grpcio-tools 1.81.1, sops + age, jq) →
repos + robin_stocks submodule → env materialisation (IG repo
`scripts/dev-env-sync.sh` decrypts committed `vault/dev/*.secret.sops.env` SOPS
manifests) → docker prep (`5million` network) → `dockerup-dev.sh` (codegen, builds,
postgres ledger auto-migrate, idempotent demo seed, `scripts/verify-dev.sh`) →
optional prod links (`~/bin/jenkins-deploy`) → verify + handoff checklist.
Break-glass (only unscriptables): ① GitHub auth; ② the **dev-box SOPS age key**
(`~/.config/sops/age/keys.txt`; without it env files fall back to `*.example`
placeholders — stack still boots); ③ optional `~/.jenkins-deploy-urls.env` (seed from
prod, see above). Tests: `tests/test-restore-scratch-dev.sh` (syntax, ensure_line
idempotency, mutation-free full dry-run).

**Dev-key recovery copy (2026-07-22):** the dev-box age key is backed up on prod at
`/mnt/minikube-mnt/keys-sops-dev-box.txt` (0600, sha256-verified at
write) — the same dir as `keys-sops-IMPORTANT.txt`, so it rides the weekly root backup
cron → WD Cloud archive and is restored by `restore-scratch.sh` phase 4b automatically.
Written from the dev box via a short-lived hostPath-`/mnt` busybox pod against
prod-minikube (prod runs no sshd); fetch it back the same way.

---

## 4. Bootstrap Flow — `start-scratch.sh`

Executed top to bottom (`set -e`, so any failure aborts the run):

1. **Docker network** – create `5million` if missing.
2. **Minikube** – if `kubectl version` fails (no cluster), `minikube start` with:
   `--cpus 12 --memory 32768 --disk-size 40g --driver=docker --network 5million
   --gpus all --mount /mnt/minikube-mnt:/mnt
   --insecure-registry 172.16.238.2:5000` plus kubelet/scheduler/controller webhook flags.
3. **Addons** – `registry`, `nvidia-gpu-device-plugin`, `metrics-server` (serves
   `kubectl top`/HPAs — see [Resource metrics](#resource-metrics--metrics-server-kubectl-top--hpas)).
4. **Monitoring** – apply `kube-prometheus` (`manifests/setup` → wait for CRDs → `manifests/`) into `monitoring` ns.
5. **Vault** – `cd ~/Ideaprojects/vault && bash start-vault.sh` (Helm install, init, unseal, policies, K8s auth, load per-app secrets from `/mnt`).
6. **Jenkins** – build the custom `jenkins-inbound-agent-vik:cloud` image if absent, push to `container-registry.traderyolo.com`, then `kubectl apply` Jenkins manifests.
6b. **vault-secrets-sync wiring** – after Jenkins is up, run `vault/scripts/setup-jenkins-pipeline.sh` to (re)create the `vault-secrets-sync` job and its credentials (`sops-age-key` + per-app `vault-approle-*`, from the AppRole secret_ids `start-vault.sh` just regenerated). Best-effort; idempotent.
7. **qcguy** – create `qcguy` ns + configmap from `~/Ideaprojects/qcguy-ghost/config`, apply `compiled.yaml`.
8. **predictonomy** – trigger Jenkins build via authenticated `curl` to `jenkins.traderyolo.com/job/predictonomy/build`.
8b. **ollama** – trigger the Jenkins `ollama` build (creates the `ollama` ns + `vault-secrets` SA and deploys ollama + webui, which fetch `kv/ollama/*` via the Vault injector). No build token — authenticated trigger.
9. **yolo** – `sleep 1m`, then trigger Jenkins `trading-microservices` build.
10. **Splunk (HSBC demo)** – apply namespace + `compiled.yaml`, `sleep 3m`, then deploy Splunk Connect for Kubernetes (SCK) via Helm with HEC token/index env vars.

`restart-minikube.sh` is the lighter-weight variant: it reuses an existing cluster,
calls `restart-vault.sh` (idempotent, skips re-init), and leaves monitoring / qcguy /
splunk **commented out**. Use it for a warm restart; use `start-scratch.sh` for a
cold rebuild.

**Automated restart recovery (host reboot).** As of 2026-06-16 the warm path is mostly
automatic: the `minikube` container runs with Docker `--restart=unless-stopped` (auto-resumes a
cluster that was running, respects an intentional `minikube stop`), plus host-cron `cluster-autostart.sh`
(reconcile k8s health) and `vault-auto-unseal.sh` (Vault boots sealed; re-unsealed in ~10s). A
**missing/corrupt** container is NOT auto-rebuilt — it alerts, leaving the cold `start-scratch.sh`
decision to a human. **Full boot sequence, the warm-vs-cold decision, and a symptom→fix triage table
are in [`RESTART-RECOVERY.md`](./RESTART-RECOVERY.md) — read it first when the cluster is unhealthy
after a reboot.**

---

## 5. Platform Services

### HashiCorp Vault (`~/Ideaprojects/vault/`)
STEP0 delegates **all** Vault setup to `bash start-vault.sh` in the vault repo; the
ordering (Vault before Jenkins/apps) is what matters here. The vault repo owns its own
`architecture.md` / `plan.md` / `CLAUDE.md` — defer to those for detail. Current shape:
- Installed via Helm into the `vault` namespace; images **pinned** (vault `2.0.2`,
  vault-k8s `1.7.4` — no longer `latest`).
- **Durable storage (2026-07-20):** the file backend lives on the pre-created
  `vault-data-pv` (Retain, hostPath `/mnt/vault-data` on the `minikube-data` shared mount (nvme0n1p6) —
  STEP0 `k8s/vault-backup/vault-data-pv.yaml`), which `start-scratch.sh` applies
  **before** `start-vault.sh` so the StatefulSet adopts the pinned `data-vault-0`
  PVC instead of dynamic-provisioning an ephemeral `/tmp` hostPath. (The old
  dynamic PV destroyed all runtime-written KV on the ~07-14 minikube rebuild —
  per-follower broker secrets, admin platform keys; see §7 + RESTART-RECOVERY.)
  A daily in-cluster snapshot CronJob (`vault/vault-data-backup`) is the
  consistent-copy layer on top.
- `start-vault.sh`: init 1 share / threshold 1, unseal, `admin` policy, `userpass`
  (user `privatecloud`) + `kubernetes` auth, KV-v2 at `kv/`.
- **Per-app least-privilege policies** (`<app>-policy.hcl`): each app role reads only
  `kv/data/<app>/*` (the old `kv/*` wildcards that let any app read everything were
  removed). K8s auth roles are bound to each app's **own** namespace, not `*`.
- Secret seeding (see vault `plan.md`): `start-vault.sh` seeds from the **declarative
  manifests** `apps/<app>/<service>.env` (config) + `*.secret.sops.env` (SOPS+age
  encrypted) via `vault-sync.sh --all` — the SAME source of truth the vault-secrets-sync
  pipeline uses, so a full refresh never reverts a pipeline-applied change. Legacy
  `*-env-variables.sh` from `/mnt` (+ `upload-file-secrets.sh`) is the automatic fallback
  only if sops / the age key / the manifests are unavailable.
- **Jenkins identity:** `start-vault.sh` provisions per-app AppRoles (`jenkins-<app>`,
  policy `jenkins-<app>-policy`, write only `kv/<app>/*`) via
  `scripts/setup-jenkins-approle.sh`. role_id/secret_id are written to
  `~/.vault/jenkins-approle/<app>.env` (0600) — paste into Jenkins credentials. The
  `vault-secrets-sync` pipeline (vault repo `ci/Jenkinsfile`) uses these instead of root.
- `cluster-keys.json` (root token + unseal key) now lives at **`~/.vault/cluster-keys.json`**
  (0600, outside any repo), written via `$VAULT_KEYS_FILE` — not in the vault repo dir.

### Monitoring — kube-prometheus (`~/Ideaprojects/kube-prometheus/`)
- Full Prometheus Operator + Grafana + Alertmanager stack in the `monitoring` ns.
- **Versions (upgraded 2026-08-04):** kube-prometheus **release-0.18** — Prometheus **3.13.2**,
  Grafana **13.1.1**, Alertmanager 0.33.1, prometheus-operator 0.92.0, prometheus-adapter 0.12.0,
  node-exporter 1.11.1, kube-state-metrics 2.19.0. Was ~release-0.12 (prometheus 2.41.0 /
  grafana 9.3.2 / operator 0.61.1), which predated this node's Kubernetes **1.35** by nine
  minor versions and was outside upstream's support matrix entirely. Grafana, Prometheus and
  Alertmanager are pinned one point release **ahead** of what 0.18 ships, at current latest
  stable; same major in each case, so the operator's generated config stays valid.
- **The Prometheus CR selects across ALL namespaces** (`serviceMonitorSelector: {}` and
  `serviceMonitorNamespaceSelector: {}`), so an app's ServiceMonitor is picked up with no
  change to this stack. But kube-prometheus only grants its `prometheus-k8s` ServiceAccount a
  namespace `Role` in `default`, `kube-system` and `monitoring` — **an app namespace must ship
  its own `prometheus-k8s` Role + RoleBinding** or the ServiceMonitor is accepted, appears in
  the operator's config, and simply never produces a target. No error, no event, nothing.
  `yolo` ships its own in `k8s/monitoring/servicemonitors.yaml`.
  ⚠️ **That Role must grant `discovery.k8s.io/endpointslices`.** Operator 0.92 moved Kubernetes
  service discovery off the deprecated core `Endpoints` API onto `EndpointSlice`, and
  kube-prometheus's own namespace Role now grants endpointslices and drops endpoints. During
  the 2026-08-04 upgrade this took every `yolo` target offline with the operator logging
  nothing — the only evidence was in the `prometheus-k8s` pod's log:
  `failed to list *v1.EndpointSlice: endpointslices.discovery.k8s.io is forbidden`.
  Check per namespace with:
  `kubectl auth can-i list endpointslices.discovery.k8s.io --as=system:serviceaccount:monitoring:prometheus-k8s -n <ns>`.
- **kube-state-metrics 2.19 parses CronJob schedules strictly and panics on an invalid one.**
  `yolo/delete-publisher` carried `*/120 * * * *` (a minutes-field step must be < 60);
  Kubernetes' lenient parser had accepted it and was running it hourly. On upgrade it
  crash-looped kube-state-metrics **cluster-wide** — one bad schedule in one namespace takes
  out kube-state metrics for every namespace. Fixed to `0 * * * *` (identical behaviour) in the
  yolo repo. Worth checking `kubectl get cronjob -A -o custom-columns=NS:.metadata.namespace,N:.metadata.name,S:.spec.schedule`
  before any future kube-state-metrics bump.
- **Grafana's admin login is pinned from Vault** — see "Grafana admin login" below. Its
  `/var/lib/grafana` is an `emptyDir`, so anything set in the UI (users, passwords, ad-hoc
  dashboards) is destroyed on every pod restart. Only *provisioned* content survives.
- **Ownership split with the apps** is documented in that repo's `manifests/YOLO-OWNERSHIP.md`
  (dashboards/alert rules/ServiceMonitors are the app repo's; the datasources, volume mounts,
  adapter and APIServices are kube-prometheus's). Don't ship a competing copy from an app repo —
  a routine `kubectl apply -f manifests/` would silently revert it.

### Resource metrics — `metrics-server` (`kubectl top` / HPAs)
> Updated 2026-06-16. This used to read "kube-prometheus replaces metrics-server
> (intentionally not enabled)" — that was wrong on this node and broke `kubectl top pod`.

- **What serves `metrics.k8s.io`:** the **`metrics-server`** addon (`kube-system`), not
  prometheus-adapter. It owns the `v1beta1.metrics.k8s.io` APIService and reads the kubelet
  **Summary API** (keyed by pod/namespace).
- **Why not prometheus-adapter:** on this minikube/docker node the kubelet's cAdvisor
  series (`/metrics/cadvisor`) are emitted **without `pod`/`namespace`/`container` labels**,
  so the adapter's pod resource-rules match nothing → `kubectl top pod` returned empty
  (`top node` worked because node rules don't need those labels). metrics-server's Summary-API
  path is unaffected by the missing cAdvisor labels.
- **Enabled in bootstrap:** `minikube addons enable metrics-server` in both `start-scratch.sh`
  and `restart-minikube.sh`. The addon flag also persists across `minikube stop/start`.
- **No re-claim conflict:** the kube-prometheus `manifests/prometheusAdapter-apiService.yaml`
  (which re-claimed `v1beta1.metrics.k8s.io` for the adapter on every `kubectl apply -f manifests/`)
  has been **removed from that repo**. So a full rebuild — addon enabled + `manifests/` applied —
  leaves metrics-server as the owner. prometheus-adapter still runs, and now serves the
  *custom* metrics API — a **different** APIService object (next section).
- **Verify:** `kubectl get apiservice v1beta1.metrics.k8s.io` (owner should be
  `kube-system/metrics-server`, `Available=True`) and `kubectl top pod -A`.
- **Background:** the root-cause investigation, durability layers, and watch-items are in
  [`HANDOFF-2026-06-16-metrics-server-and-rollout-fixes.md`](./HANDOFF-2026-06-16-metrics-server-and-rollout-fixes.md).

### Custom metrics — `custom.metrics.k8s.io` (prometheus-adapter) — added 2026-08-04

The two metrics APIs are **different singleton APIServices** and the distinction is the
whole story here — conflating them is what broke `kubectl top` in June:

| APIService | Served by | Serves | Consumed by |
|---|---|---|---|
| `v1beta1.metrics.k8s.io` | `kube-system/metrics-server` | node & pod cpu/memory | `kubectl top`, `type: Resource` HPAs |
| `v1beta1.custom.metrics.k8s.io` | `monitoring/prometheus-adapter` | app metrics out of Prometheus | `type: Pods`/`type: Object` HPAs |

- **What was missing:** the adapter's ConfigMap carried `resourceRules` only (inert here, see
  above) and **no `rules:`**, and `custom.metrics.k8s.io` was never registered. Prometheus was
  scraping yolo's metrics fine — but nothing could turn one into an HPA input, so an HPA
  pointing at `yolo_grpc_in_flight_requests` would have reported `<unknown>` forever.
- **What was added (in `~/Ideaprojects/kube-prometheus/`):**
  `manifests/prometheusAdapter-apiServiceCustomMetrics.yaml` (registers the API) and a `rules:`
  block in `manifests/prometheusAdapter-configMap.yaml`.
- **This does NOT re-open the June regression.** The file deleted in `88c88ce8` claimed
  `metrics.k8s.io`; this one claims `custom.metrics.k8s.io`. They are separate objects and both
  are expected to exist. Verified after the change: `kubectl top` still works.
- **Scope is an explicit allowlist** — the prefix group `^(yolo)_` in three `seriesQuery`
  regexes — not the upstream catch-all, which would have the adapter re-plan every series in
  Prometheus once a minute on a box that also runs the apps. Adding an app = extend the group.
- **HPA RBAC needs nothing extra.** The built-in `system:controller:horizontal-pod-autoscaler`
  ClusterRole already grants `custom.metrics.k8s.io/*` get/list/watch and is already bound.
  (`kubectl auth can-i` reports a misleading "no" here — it can't resolve these subresources in
  discovery. A `SubjectAccessReview` confirms `allowed: true`.) Do not add a redundant binding.
- **Verify:**
  ```bash
  kubectl get apiservice v1beta1.custom.metrics.k8s.io                       # Available=True
  kubectl get --raw /apis/custom.metrics.k8s.io/v1beta1 | jq -r '.resources[].name' | sort
  kubectl get --raw '/apis/custom.metrics.k8s.io/v1beta1/namespaces/yolo/pods/*/yolo_grpc_in_flight_requests' | jq
  ```
- **Full reference:** `~/Ideaprojects/kube-prometheus/manifests/CUSTOM-METRICS.md` — metric
  list, HPA snippet, the milliseconds/`resource.Quantity` gotcha, and how to onboard an app.
  HPAs themselves stay in the app repos; only the adapter is ours.

### Grafana public access — `root_url` and websockets — fixed 2026-08-04

Two independent faults, both silent in a desktop browser and both breaking other clients:

- **`root_url` was never set**, so Grafana fell back to its default and advertised itself as
  `http://localhost:3000/` — visible in `/api/frontend/settings` and handed to every caller.
  A browser survives that (it navigates with relative paths); a phone takes it literally and
  dials itself. The same bug was minting `localhost` links in **alert notifications** and
  **share/snapshot URLs**. Fixed in kube-prometheus `manifests/grafana-config.yaml`
  (`[server] domain` + `root_url = https://grafana.traderyolo.com/`). `enforce_domain` is
  deliberately **off** so direct NodePort access (`http://172.16.238.2:30330`) keeps working,
  and `protocol` stays `http` — NPM terminates TLS, the `https` is only what the client sees.
  Verify: `curl -s https://grafana.traderyolo.com/login | grep -o '"appUrl":"[^"]*"'`.
- **Websockets were disabled on the NPM proxy host**, so `/api/live/ws` returned 400 in a
  retry loop and Grafana Live (real-time streaming panels) never worked. Enabled on proxy
  host 15; `data/nginx/proxy_host/15.conf` now carries the `Upgrade`/`Connection`/
  `proxy_http_version` directives. Verify with a **forced HTTP/1.1** handshake — over HTTP/2
  a classic `Upgrade:` handshake is invalid by definition and returns 400 regardless:
  `curl -sD- -o/dev/null --http1.1 -u <admin> -H 'Connection: Upgrade' -H 'Upgrade: websocket'
  -H 'Sec-WebSocket-Version: 13' -H 'Sec-WebSocket-Key: dGhlIHNhbXBsZSBub25jZQ==' \
  https://grafana.traderyolo.com/api/live/ws` → expect `101 Switching Protocols`.

**Durability differs between the two.** `root_url` lives in `kube-prometheus/manifests/`, which
`start-scratch.sh` applies wholesale, so it is reproduced on any rebuild. The websocket setting
lives in **nginx-proxy-manager's own database**, not in any repo — it survives only because
`backup-minikube-mnt.sh` archives `/home/cloud/Ideaprojects/nginx` and `restore-scratch.sh`
restores it. That is by design (NodePort↔domain mapping is NPM's, not this repo's), but it
means a *manually rebuilt* NPM needs the toggle re-set by hand.

> **Footnote — the Grafana mobile app does not work here, and cannot.** The app is
> **Grafana IRM**, which requires the Cloud-only `grafana-irm-app` plugin; the access log shows
> it requesting `/api/plugins/grafana-irm-app/settings` → **404**. Its OSS predecessor
> (`grafana-oncall-app`) was archived in March 2026 along with the Cloud push relay. The
> `root_url` fix above was necessary but is not sufficient — no configuration on this box will
> make that app connect. Use the mobile web UI (Add to Home Screen) for dashboards, and ntfy
> for push (§7a/§7b).

### Grafana admin login — pinned from Vault (`sync-grafana-admin.sh`) — added 2026-08-04

- **The problem:** kube-prometheus mounts Grafana's `/var/lib/grafana` from an **emptyDir**.
  Grafana keeps its users in a SQLite DB in there, so the admin password set in the UI lasts
  exactly until the next pod restart, after which the login reverts to the built-in
  `admin`/`admin` — on a Grafana that NPM publishes to the internet.
- **The fix:** Grafana re-applies `GF_SECURITY_ADMIN_USER`/`GF_SECURITY_ADMIN_PASSWORD` to the
  admin account on **every** startup. `grafana-deployment.yaml` now reads both from the
  `monitoring/grafana-admin` Secret (`secretKeyRef`, `optional: true`).
- **Chain:** `Vault kv/grafana/admin` → `sync-grafana-admin.sh` → `monitoring/grafana-admin`
  Secret → Grafana env. **Vault is the source of truth**; the password is in no git repo.
  Seeded once from `GRAFANA_ADMIN_PASSWORD` in the gitignored `STEP0/.env` (captured by the
  weekly DR tar, restored by `restore-scratch.sh`), or randomly generated if that is absent.
  A later `.env` edit does **not** overwrite a live Vault value — use `--reseed` to force it.
- **Run by:** `start-scratch.sh` (after `start-vault.sh`, which is after the monitoring apply)
  and `restart-minikube.sh`. Idempotent, and only restarts Grafana when the password changed.
  `--status` reports the whole chain without touching anything.
- **Why Grafana does not read Vault directly:** the Vault agent injector's init container
  blocks until Vault answers, which would make the entire observability stack unable to boot
  whenever Vault is sealed or down — precisely when you need the dashboards. `optional: true`
  on the secretKeyRef exists for the same reason: a `kubectl apply -f manifests/` on a cluster
  where the sync hasn't run must still bring Grafana up, on its default login, rather than
  wedge the pod in `CreateContainerConfigError`.
- **Note the trade-off:** the password also lands in etcd as a Secret. On a single-node box
  where the operator already holds the Vault root token, that is not a meaningful widening.

### CI/CD — Jenkins (`~/Ideaprojects/jenkins/`)
- Custom `inbound-agent` image (kubectl + curl + wget pre-installed) pushed to the private registry.
- Pipelines triggered remotely by `curl -X POST` with basic-auth + job token:
  `predictonomy`, `trading-microservices` (yolo). Builds produce images that land in the registry and deploy to K8s.
- **`vault-secrets-sync` pipeline** (vault repo `ci/Jenkinsfile`) additionally needs
  **`vault`, `sops`, `age`, `jq`** on the agent image, the `sops-age-key` credential, and
  the per-app `vault-approle-id`/`vault-approle-secret` credentials. If you rebuild the
  inbound-agent image, add those CLIs (see vault `plan.md`).
  ⚠️ **That job is RETIRED** (disabled in Jenkins, `ci/Jenkinsfile` deleted from the vault
  repo on 2026-06-14, commit `64fe5a9`). Each app now owns its secrets in its own repo's
  `vault/` dir and refreshes Vault at deploy via the `vaultSync(app)` shared library. Do not
  re-enable it or add it to `jenkins-jobs.manifest`.

#### Agent workspace volume — the single biggest build-speed setting

Jenkins agent pods take their `/home/jenkins/agent` workspace from the pod template's
`workspaceVolume`. It shipped as **`DynamicPVCWorkspaceVolume`**, which provisions a *fresh
PVC per agent*. minikube's `standard` StorageClass is `volumeBindingMode: Immediate`, so the
pod cannot be scheduled until that PVC exists — every build paid

```
FailedScheduling: pod has unbound immediate PersistentVolumeClaims
```

plus the scheduler's **exponential back-off** between retries. Measured 2026-08-07, same job
and same stage, the only difference being whether an agent had to be provisioned:

| | `DynamicPVC` | `emptyDir` |
|---|---|---|
| `qcguy` end-to-end | 3.1 min | **0.3 min** (10x) |
| ⤷ Refresh Vault secrets | 102.5s | 14.6s |
| ⤷ Deploy K8s | 83.8s | 2.2s |
| `dyingpaleblue` end-to-end | ~1.5 min | 1.4 min |

Pipelines spawn 2–4 agents each, so this was **~98s of pure provisioning per agent** —
minutes per build, on builds with 1–3 minutes of real work. The PVC stored nothing worth
keeping: the workspace is recreated from a fresh clone every build and the reclaim policy was
`Delete`. Now `EmptyDirWorkspaceVolume` (+ `<memory>false</memory>`), which lands on the
node's NVMe anyway.

> **This is why the GM9000 appeared to make no difference to builds.** The disk was never the
> bottleneck — image pulls were already 1.77 GB in 0.147s. Roughly 70% of build time was the
> control plane waiting on PVCs. The NVMe upgrade is real and is what made the *databases*
> 31x faster (4K fsync 29.6ms → 0.96ms); builds needed this instead. Measure where the time
> actually goes (`/job/<name>/<n>/wfapi/describe`) before buying hardware for it.

**It has no declarative home.** There is no Jenkins Configuration-as-Code here: the setting
lives only in `JENKINS_HOME/config.xml`, i.e. persisted state on the `/mnt/jenkins` hostPath
PV. It survives pod restarts, `minikube delete`, and a DR restore — but **any archive taken
before 2026-08-07 still contains `DynamicPVC`**, so restoring one silently reverts it and
builds go 10x slower with nothing in any log to explain why. `verify-recovery.sh` therefore
checks the class explicitly. Editing it requires Jenkins to be **stopped first**
(`kubectl scale deploy/jenkins -n jenkins --replicas=0`) — Jenkins rewrites `config.xml` on
shutdown and will discard an edit made while it is running. Full procedure in
`RESTART-RECOVERY.md`.

### Image Registry
- Two mechanisms coexist: the Minikube `registry` addon (in-cluster, `172.16.238.2:5000`)
  and the externally-named `container-registry.traderyolo.com` (NPM → :5000).
- Maintenance: `delete-docker-reg-images.sh` garbage-collects orphaned registry blobs.

---

## 6. Applications

| App | Stack | Source dir | Notes |
|-----|-------|-----------|-------|
| **qcguy** | Ghost CMS | `~/Ideaprojects/qcguy-ghost` | Blog; deployed directly via `compiled.yaml` + configmap |
| **yolo / trading-microservices** | Java microservices | built by Jenkins | traderyolo.com; IG-Trading bots |
| **predictonomy** | (Jenkins-built) | built by Jenkins | Market prediction app |
| **helpmepdf** | API + web | (Jenkins/registry) | PDF tooling, helpmepdf.com |
| **ollama** | Ollama (multi-model) | `Modelfile` (standalone), `~/IdeaProjects/ollama` | Cluster serves `quantos:latest` (FROM `qwen2.5:7b-instruct`) + `qwen3-coder-private`; the STEP0 `Modelfile` is a **standalone** `deepseek-r1:32b` equities def, **not** what the apps consume. GPU-backed; streaming proxy. See §"Ollama model". |
| **splunk** | Splunk Enterprise | `~/IdeaProjects/splunk-hsbc-demo` | HSBC demo; SCK log forwarding; optional |
| **tatesremedies** | (legacy) | `~/Ideaprojects/tatesremedies` | Old kvm2 deployment, currently disabled |

### Ollama model (`Modelfile`)
`FROM deepseek-r1:32b` with a stock-market-research system prompt (temperature 0.4,
top_p 0.9, num_ctx 32768). At ~20 GB (Q4) it exceeds the 3080 Ti's 12 GB VRAM and
partial-offloads to system RAM — feasible after the 96 GB host upgrade. Served via
`ollama.traderyolo.com` with streaming-friendly Nginx config (buffering off, 600s timeouts).

> **Scope note (reconciled 2026-06-29):** this `Modelfile` is a **standalone / reference**
> equities-research definition; it is **not** built or served by the in-cluster Ollama.
> The live Ollama (built by the `~/IdeaProjects/ollama` Jenkins pipeline) serves
> **`quantos:latest`** (FROM `qwen2.5:7b-instruct`) and **`qwen3-coder-private:latest`**,
> plus pulled bases `qwen2.5:7b-instruct`, `qwen3-coder:latest`, `llama3.1:latest`.
> **App → model:** predictonomy & dyingpaleblue → `qwen2.5:7b-instruct`;
> yolo/trading-microservices → `quantos:latest` (+ `nomic-embed-text` embeddings) — all
> overridable via `OLLAMA_MODEL` (env/Vault) and, for the two TS apps, a DB
> `aiModel`/`ai.model` setting. **Authoritative source:**
> `~/IdeaProjects/ollama/docs/ollama/current-setup.md`.

---

## 7. Persistence & Backups

- **Shared volume:** `/mnt/minikube-mnt` (on `/dev/nvme0n1p6`, label `minikube-data`) is mounted into
  the Minikube node at `/mnt`. It carries per-app env/secret scripts and app data shared
  between host and cluster. Inside it, `container-registry-images/` is itself a **separate
  `/dev/nvme0n1p7` mount (label `Kachra`)** (the durable registry from commit R8) — `tar` descends into it
  normally, so it is captured by the backup.
- **Location history (important).** The shared volume used to live at
  `~/Ideaprojects/minikube-mnt` (on the `/home` disk, `/dev/sda6`). It was relocated to
  `/mnt/minikube-mnt` and `restart-minikube.sh` / `start-scratch.sh`
  mount the new path. On **2026-06-16** we found `backup-minikube-mnt.sh` was still pointing
  `backup_files` at the *old* `~/Ideaprojects/minikube-mnt` — so every weekly archive had
  silently been backing up a **stale** copy (months old, missing the live Postgres/Mongo
  data, durable registry, and current secrets). Fixed to the live path; the old stale tree
  was moved to **`/mnt/minikube-backups/old-minikube-mnt`** (kept as a just-in-case relic,
  not used by anything). If you ever see two `minikube-mnt`-ish dirs again, the live one is
  the one Minikube mounts — confirm against `restart-minikube.sh`.

### Weekly automated backup (cron)

A **`root` cron job runs weekly** (Mondays ~05:00) and executes
**`backup-minikube-mnt.sh`**. This is the disaster-recovery safety net: if anything
happens to the `private-cloud` host, these archives are what the stack is rebuilt from.
Every run produces a single compressed, dated archive
`private-cloud-<MM-DD-YY>.tgz` (≈5 GB) under **`/mnt/minikube-backups`** (root-owned).
The live entry is the **single** line in `root`'s crontab (`sudo crontab -l -u root`):
`0 5 * * 1 /bin/bash /home/cloud/Ideaprojects/STEP0/backup-minikube-mnt.sh >> /var/log/minikube-backup.log 2>&1`
— run output (including the prune) is appended to **`/var/log/minikube-backup.log`**, so
check there to confirm a run or debug a failure.

> **Must run as `root`.** The live mount contains root-owned data dirs
> (`predictonomy-postgres/pgdata`, the `trading-microservices` MongoDB WiredTiger files,
> the durable registry). A non-root run would *silently skip* those (tar only warns,
> `set -e` is off) and produce a false-confidence archive. Run/test it with `sudo`.

> **Single-instance guard (`flock`).** The archive name is deterministic per day, so two
> concurrent runs would `tar` into the same file and corrupt it. The script grabs a
> non-blocking `flock` on `/tmp/backup-minikube-mnt.lock` (fd 200) and a second runner
> exits 0 quietly. (Added 2026-06-16 after the crontab was found to contain a *duplicate*
> entry firing at the same minute — the duplicate has since been removed.)

> **`ollama/models` is excluded** from the tar (`--exclude='*/ollama/models'`). Those
> model weights are ~38 GB and **reproducible** (`ollama pull` / the `Modelfile`); without
> the exclude each weekly archive would balloon from ~5 GB to ~40 GB and fill the backup disk (`/dev/sda1`)
> under the retention policy. Ollama's identity key (`id_ed25519`) lives outside `models/`
> and **is** captured. On restore, re-fetch the model rather than expecting it in the tar.

> **`container-registry-images` is excluded too** (`--exclude='*/container-registry-images'`,
> added 2026-08-06). The kachra blob store is bind-mounted *inside* `minikube-mnt`
> (`ensure-registry-store.sh`, R8), so from June the tar had been **silently swallowing
> it** — 34 GB of the 41 GB 2026-08-03 archive (~83%), already-gzipped blobs that
> compress ~1:1 — even though this document already stated the blobs are not in the
> archive. The exclude restores that contract before the backup disk filled (at +4–6 GB/week the
> retention math ran out of disk before the September prune relief). In its place the
> script refreshes **`minikube-mnt/registry-catalog.txt`** (every repo + its tags,
> best-effort — a quiesced cluster keeps the previous snapshot) so a bare-metal restore
> knows exactly what Jenkins must rebuild. To shrink the store itself, prune old yolo
> `bNNNN` build tags with `prune-registry.sh` (dry-run by default; deletes by digest
> keep-set, then `garbage-collect --delete-untagged` + a registry restart). all weekly backups for the
**current and previous month** are kept; for any **older month** only that month's
**most recent** backup is kept and the rest are deleted. So recent history stays
weekly-granular while older months collapse to one archive each (≈4–5 GB/month saved
per pruned week).

The script `tar -czf`s **five** trees — `minikube-mnt`, `~/Ideaprojects/nginx`,
`~/Ideaprojects/STEP0`, `~/Ideaprojects/qcguy-ghost`, and **`~/.vault`** (the *only* copy
of Vault's unseal key + root token, in `cluster-keys.json`, plus the Jenkins AppRole
secret_ids under `jenkins-approle/`) — but the bulk of the value is inside the
**`minikube-mnt`** shared volume, which captures everything that **can't live in GitHub**:

- **Per-app secrets / Vault seed material** — `yolo-`, `helpmepdf-`, `predictonomy-`,
  `ollama-env-variables.sh`, the SOPS age key (`keys-sops-IMPORTANT.txt`) and
  `phase-file-secrets-kv.txt`. (Before archiving, the script refreshes all four live env
  scripts — yolo, helpmepdf, predictonomy, ollama — from `~/Ideaprojects/vault/` into
  `minikube-mnt`.)
- **Database snapshots** (for restoring app state) — `yolo-db-snapshots`,
  `predictonomy-backups` + `predictonomy-postgres`, and the MongoDB `storage.bson`
  dumps under `trading-microservices/` and `helpmepdf/`.
- **Vault data snapshots** — `vault-backups/vault-data-MM-DD-YY.tgz`, written daily
  (04:30 UTC, 30 min before the Monday weekly tar) by the in-cluster CronJob
  `vault/vault-data-backup` (STEP0 `k8s/vault-backup/`, applied by start-scratch.sh).
  ⚠️ This existed because the Helm-provisioned Vault PV was a **dynamic hostPath
  in the VM's `/tmp` with reclaimPolicy Delete** — NOT on this shared mount — so a
  minikube rebuild silently destroyed Vault's file backend. **Fixed 2026-07-20:**
  Vault now runs on the pre-created `vault-data-pv` (Retain, `/mnt/vault-data` on
  this shared mount — `k8s/vault-backup/vault-data-pv.yaml`, applied before
  start-vault.sh); the daily snapshot stays as the consistent-copy layer. That is exactly how all
  runtime-written Vault data (per-follower broker secrets `kv/yolo/followers/*`,
  admin platform keys `kv/yolo/platform-data-sources`) was lost in the ~2026-07-14
  rebuild: apps' vaultSync re-seeded only the declarative per-service paths.
  Restore: see RESTART-RECOVERY.md "Vault KV data missing". Root-cause fix (durable
  Retain PV under the shared mount) is tracked in plan.md.
- **App data & platform state** — `qcguy-ghost` (Ghost content), `ollama`, `jenkins`,
  `container-registry`, `splunk-hsbc`, `tatesremedies`.
- **Ingress + bootstrap config** — the NPM tree (`nginx/`) and the STEP0 scripts.

To restore, unpack the relevant tree from the latest `private-cloud-*.tgz` back into
place, then re-bootstrap via `start-scratch.sh` (which re-seeds Vault from the recovered
`/mnt` secret scripts and redeploys the apps).

### Off-site copy — WD Cloud (LAN, NFS)

After the local archive + prune, the **same script** copies that run's `.tgz` **off-site**
to the **WD Cloud 6TB NAS on the LAN** (`192.168.50.169`) over **NFS**. The dedicated export is
**`/nfs/private-cloud`** (device-side path `/mnt/HD/HD_a2/private-cloud`), mounted at
**`/mnt/wdcloud`**; archives land at the **mount root** (`/mnt/wdcloud/private-cloud-<date>.tgz`),
since the share is dedicated to these backups. This is the off-host leg of disaster recovery — a
disk-loss that takes out the backup disk (`/dev/sda1`) no longer takes out every backup. (This replaced the earlier
GCS Coldline mirror; the GCS code is retained **commented-out** in `backup-minikube-mnt.sh` as a
re-enable-able fallback.)

- **No re-zip** — the local `.tgz` is already compressed; it is copied as-is.
- **No credentials** — NFS on the trusted LAN needs none in the script (unlike the old GCS
  service-account key). Writes are permitted (`sec=sys`, no root_squash); the export maps them
  to the share owner **uid 501** on the device — harmless, files stay readable.
- **`hard` mount, not `soft`** — the persistent `/etc/fstab` entry is
  `192.168.50.169:/nfs/private-cloud /mnt/wdcloud nfs _netdev,nofail,hard,timeo=600,retrans=3,x-systemd.automount 0 0`.
  `hard` was chosen deliberately: a live 21 GB copy-test on a `soft,timeo=150` mount returned
  `Input/output error` on `close()` when the WD's fsync outran the soft timeout — a `soft` mount
  can **truncate/corrupt a backup**. `hard` retries instead (re-verified byte-perfect, md5 match).
  `nofail` + `x-systemd.automount` keep a dark NAS from ever blocking boot — it mounts on first
  access, so the mount survives reboots/crashes without wedging startup.
- **One-time manual setup (dashboard, not scripted)** — the WD is a network appliance, so two
  steps are done **once, by hand in the WD My Cloud web dashboard** and then persist on the device:
  (1) **format** the 6 TB volume (Settings → Utilities → Format Volume / Full Factory Restore) —
  the host cannot `mkfs` a NAS; (2) **create the private `private-cloud` share with NFS access on**.
  These are not automatable in practice: the OS3 dashboard login *is* scriptable
  (`POST /nas/v1/auth`, JSON `{"username","password":<base64>}`), but the share-management CGIs use
  per-request rotating/replay-protected tokens and the admin account **locks after 5 failed logins**,
  so a one-time hand-click is safer than scripting it. Confirm the export with
  `showmount -e 192.168.50.169`.
- **Share prune mirrors the local retention** (current + previous month, one per older month)
  with **no age floor** — it is our own disk, so deletes are always free (the 90-day floor
  only ever existed to dodge Coldline's minimum-storage early-deletion fee). Dates are read
  from the **filename**, reusing the local prune's YYMM parsing.
- **Fully additive + guarded** — if `/mnt/wdcloud` is not mounted or not writable the step
  only `WARN`s to `/var/log/minikube-backup.log`; it never aborts or affects the local backup.

**Restoring from the off-site copy.** `restore-scratch.sh` is the documented inverse: on a bare Ubuntu
box (phase 1 installs `nfs-common`) it **mounts the WD NFS share** (`hard,timeo=600,retrans=3`) and
picks the newest `private-cloud-*.tgz` from `/mnt/wdcloud/` (date parsed from the filename, like the
prune) — no cloud auth needed on the LAN. Two things are not in the archive and are reconstructed on
restore: the **registry blobs** (they live on `/mnt/kachra` (nvme0n1p7), re-pushed by Jenkins on a single-disk
rebuild — enforced by an explicit `--exclude` since 2026-08-06, after the `Kachra` bind inside `minikube-mnt`
had silently pulled them back into the tar; `registry-catalog.txt` in the archive lists what to rebuild)
and the **ollama models** (`*/ollama/models` excluded, re-pulled). See
`docs/superpowers/specs/2026-06-30-restore-scratch-design.md`.

### Backup retention convention — apply to **every** backup cron job

**Standard for all backup cron jobs in this setup** (new ones must replicate it):

> Keep **all** periodic backups for the **current month and the previous month**. For
> any **older month**, keep only that month's **most recent** backup and delete the rest.

This keeps recent history fine-grained (weekly) while older months collapse to one
archive each, bounding disk use on `/mnt/minikube-backups`. The rules every backup
script must follow so the prune works:

- **Name each archive with its date** as `<name>-MM-DD-YY.<ext>` (e.g.
  `private-cloud-06-15-26.tgz`). The prune reads the date from the **filename**, not mtime.
- **Group by calendar month** using a numeric `YYMM` key (e.g. `2606`) so comparisons
  sort correctly across year boundaries (Jan 2026 `2601` > Dec 2025 `2512`).
- **"Current + previous month"** is the calendar window `date +%y%m` and
  `date -d "$(date +%Y-%m-01) -1 month" +%y%m` — anything `>=` the previous month is kept.
- Run the prune **at the end of the backup**, after the new archive is written.

Reference implementation (copy into any new backup script — set `dest` and `prefix`):

```bash
# --- retention prune: keep weekly for current+previous month, one per older month ---
prefix="private-cloud"          # archive name stem; files are $prefix-MM-DD-YY.tgz
prev_ym=$(date -d "$(date +%Y-%m-01) -1 month" +%y%m)   # numeric YYMM cutoff

declare -A latest_day latest_file
for f in "$dest/$prefix"-*.tgz; do          # pass 1: newest backup per older month
    [ -e "$f" ] || continue
    [[ "$(basename "$f")" =~ ^${prefix}-([0-9]{2})-([0-9]{2})-([0-9]{2})\.tgz$ ]] || continue
    dd="${BASH_REMATCH[2]}"; ym="${BASH_REMATCH[3]}${BASH_REMATCH[1]}"
    [ "$ym" -ge "$prev_ym" ] && continue
    if [ -z "${latest_day[$ym]}" ] || [ "$dd" -gt "${latest_day[$ym]}" ]; then
        latest_day[$ym]="$dd"; latest_file[$ym]="$f"
    fi
done
for f in "$dest/$prefix"-*.tgz; do           # pass 2: delete the non-latest old ones
    [ -e "$f" ] || continue
    [[ "$(basename "$f")" =~ ^${prefix}-([0-9]{2})-([0-9]{2})-([0-9]{2})\.tgz$ ]] || continue
    ym="${BASH_REMATCH[3]}${BASH_REMATCH[1]}"
    [ "$ym" -ge "$prev_ym" ] && continue
    [ "$f" != "${latest_file[$ym]}" ] && rm -f "$f"
done
```

`backup-minikube-mnt.sh` is the canonical example of this convention.

### Tenant job — WD My Cloud 8TB → 16TB backup (nightly 02:00, not cluster-related)

This host also runs a backup job with **nothing to do with the cluster**: a nightly
rsync-over-CIFS **delta** backup of the **8TB WD My Cloud** (`192.168.50.68`,
`MYCLOUD-JGN6VM`) to the **16TB WD My Cloud** (`192.168.50.251`, `MYCLOUD-320969`).
Neither of these is the DR NAS used above (`192.168.50.169`). It lives at
`/home/cloud/wd-backup/` (script + config + own README) and runs as root from
`/etc/cron.d/wd-backup` at 02:00, logging to `/home/cloud/wd-backup/logs/`.

**Moved here from the dev box (`vik@10.10.10.2`) on 2026-07-12** because the dev box is
not always powered on, so its cron was unreliable; prod is up 24/7 and reaches both NAS
on the same 192.168.50.x LAN. The backup is **additive** (no `--delete` — the 16TB only
grows), i.e. a mirror rather than dated archives, so the retention convention above does
not apply to it. To redeploy or update it, pull the directory from the dev box over the
10GbE link and re-run the idempotent installer — see the header of
`/home/cloud/wd-backup/install-on-prod.sh`.

---

## 7a. Push notifications — ntfy channels

Everything on this host runs unattended: the weekly DR backup fires from a `root` cron at
05:00 on a Monday, the WD mirror at 02:00 nightly, the resource watcher every 5 minutes.
Nobody reads a cron log until something has already been lost, so each of those jobs pushes
to a **[ntfy.sh](https://ntfy.sh) topic** you can subscribe to from a phone.

**Numbered like §11a in the yolo repo because a half-wired alert channel is invisible** —
a dead channel and a healthy system look identical. yolo lost that argument four times; the
mechanical causes (an unregistered topic, a non-latin1 byte in an HTTP header, a publisher
whose push was never actually reachable) are all removed by construction here.

### The channels

| Topic | Publisher | When it speaks |
|---|---|---|
| `yolo-private-cloud-backup` | `backup-minikube-mnt.sh` (Mon 05:00, root cron) | Every run. Status + tar rc, this archive's size and duration, how many backups exist locally and on the WD Cloud with totals and free space, and any warning collected along the way (empty `cluster-keys.json`, NAS dark, off-site copy failed). |
| `yolo-wd-cloud-backup` | `~/wd-backup/wd-backup.sh run` (02:00, `/etc/cron.d/wd-backup`) | Every run. Bytes copied this run (summed from rsync's own `stats2` blocks) and bytes on the wire, used/free on the 16TB destination, duration. Also on any FATAL *before* rsync starts — a NAS that is off, a mount that won't authenticate — which is precisely when the end-of-run summary would never fire. |
| `yolo-private-cloud-start-scratch` | `start-scratch.sh` | STARTED at the top, then COMPLETED (with duration and whether app builds were triggered or skipped) or FAILED. `set -e` is on, so an ERR trap names the aborting line and command; the EXIT trap guarantees exactly one closing message either way. |
| `yolo-private-cloud-restore-scratch` | `restore-scratch.sh` | STARTED, then COMPLETE (with the DNS → `trigger-app-builds.sh` steps that still remain) or FAILED via `die()` with the `--from-phase` resume hint. An EXIT trap catches a run that stops *without* either — a Ctrl-C or a killed session at 03:00. **`--dry-run` sends nothing**: it exists to be re-read repeatedly. |
| `yolo-private-cloud-platform` | **Alertmanager** (kube-prometheus `manifests/alertmanager-secret.yaml`) | Every kube-prometheus infrastructure alert that reaches the `Default` or `Critical` receiver — node CPU/memory/disk, PVs filling, pod crashloops, `TargetDown`, plus this box's CPU/GPU temperature rules from `manifests/platform-hardware-prometheusRule.yaml`. Not a bash publisher: Alertmanager POSTs the webhook itself, and ntfy's `?tpl=yes` templating renders the title/message/priority from the payload. See §7b. |
| `yolo-grafana` | **Grafana alerting** (the yolo repo's `grafana-alerting-yolo` ConfigMap) | yolo APP alerts only. A separate, deliberately independent alerting system — see §7b. |
| `yolo-private-cloud-resource-crunch` | `alerting-pipeline-watch.sh` (`*/5`, cloud crontab) | Only when the **alerting pipeline itself** is broken, and only after it has *stayed* that way. See below. |

Topics are **not secrets** — ntfy.sh topics are world-readable *and* world-writable, which is
why they are committed in the clear and why **no message body may carry a secret, token or
PII**. ntfy allows `[-_A-Za-z0-9]{1,64}` with no hierarchy, so the `yolo-` prefix is a naming
convention, not a namespace.

> The separate, private `NTFY_URL` in the gitignored `.env` is **not** part of this registry.
> It is a single random topic used by `cluster-autostart.sh` / `vault-auto-unseal.sh` for
> cluster up/down alerts, predates the registry, and is deliberately left alone.

### `ntfy-lib.sh` — one publisher, one registry

Every publisher sources it; nothing hand-rolls a `curl`. It provides:

* the five `NTFY_TOPIC_*` variables and `NTFY_TOPICS` — **the source of truth**;
* `ntfy_topic_valid` — rejects both malformed *and* unregistered topics, so a typo like
  `…-backups` (a perfectly legal topic nobody is subscribed to) cannot silently swallow alerts;
* `ntfy_header_safe` — folds em dashes, smart quotes and ellipses to ASCII and strips
  newlines. HTTP headers are latin1; a `—` in a Title is a hard client-side failure *before
  the request is sent*, and this repo's prose is full of them;
* `ntfy_push` — **always returns 0 and never writes stdout**. A notification must never abort
  a backup, a bootstrap or a two-hour DR run. `NTFY_DRY_RUN=1` prints instead of sending;
  `NTFY_ENABLED=0` disables the lot.

Every publisher sources it *defensively* — if the lib is missing, stub functions make pushes
a silent no-op and the job runs exactly as it did before. `wd-backup.sh` lives outside this
repo and does this deliberately: it is a NAS-to-NAS job with no other STEP0 dependency.

**`./ntfy-topic-check.sh` is the gate.** It fails if a registered publisher stops sourcing the
lib, if a topic is hardcoded as a bare URL outside the registry, or if a `ntfy_push` call uses
a string literal instead of a `$NTFY_TOPIC_*` variable. Run it after touching any of this.
Unit tests: `tests/test-ntfy-lib.sh`, `tests/test-backup-notification.sh`,
`tests/test-run-notifications.sh`, `tests/test-alerting-pipeline-watch.sh` — all offline.

### `alerting-pipeline-watch.sh` — and why it is not just a set of `if`s

**This file used to be `resource-crunch-watch.sh`** and used to read node CPU/memory, GPU,
temperatures and disks itself. On 2026-08-04 all of that moved into Alertmanager (§7b), which
notifies ntfy directly — keeping both would have meant two notifications for every condition.

What replaced it answers a question Alertmanager structurally cannot: **is the alerting itself
working?** Moving alerting into the cluster creates a hole that cannot be closed from inside
it. If Prometheus stops evaluating or Alertmanager stops delivering, the symptom is *silence*,
which is indistinguishable from a healthy machine. Alertmanager cannot page you about being
down. This script keeps its cron slot and its independence precisely so that something on this
box still speaks when the cluster is what broke. Probed every 5 minutes:

| Probe | Breach | Source |
|---|---|---|
| `prometheus-down` | not 2xx | `GET /-/healthy` on the NodePort. No Prometheus = no rule evaluation = all ~138 rules silently inert |
| `alertmanager-down` | not 2xx | `GET /-/healthy`. Rules can fire perfectly and still reach nobody if the router is gone |
| `watchdog-missing` | alert absent | `ALERTS{alertname="Watchdog",alertstate="firing"}`. The **strong** check: a process can answer `/-/healthy` while its rule evaluation is wedged. `Watchdog` is kube-prometheus's always-firing rule, so its absence proves evaluation stopped |
| `notify-failures` | ≥ 1 in 15m | `alertmanager_notifications_failed_total`. Catches everything being up while the ntfy webhook itself fails — DNS, egress, a typo'd topic |

Endpoints and limits are env-overridable (`AP_PROM_URL`, `AP_ALERTMANAGER_URL`,
`AP_NEED_CONSEC`, …). Reached over the **NodePort**, not the ClusterIP — running outside the
cluster network is the entire point.

Three rules keep the channel worth reading — a channel you mute is worse than none:

1. **Sustained.** A probe must fail `AP_NEED_CONSEC` runs in a row (default 3 = **15
   minutes**) before it says anything. A rollout restart is not an outage.
2. **Cooldown.** While it stays failed it repeats at most every `AP_COOLDOWN` (default 1h),
   not every 5 minutes.
3. **Recovery.** One "cleared" note when it ends, so an alert never leaves you guessing.

One aggregated push per run, not one per probe — when the cluster goes down several probes
trip together and they are the same event. State lives in `logs/.alerting-pipeline-state`;
deleting that file just re-arms everything.

Two deliberate non-alerts: **the cluster being down** as a whole is `cluster-autostart.sh`'s
channel; and **a probe that cannot run is never a breach** — if Prometheus is unreachable the
two Prometheus-derived probes are *skipped* rather than reported, because `prometheus-down`
already says so and three alerts describing one outage is exactly the noise this avoids.

If this channel speaks, **treat silence on `yolo-private-cloud-platform` as unknown rather
than healthy** until it clears.

Inspect without sending anything: `./alerting-pipeline-watch.sh --status`.

---

## 7b. Infrastructure alerting — Alertmanager → ntfy

**The rules were always there; nothing was listening.** kube-prometheus ships ~138 alerting
rules as `PrometheusRule` CRs (`node-exporter-rules`, `kubernetes-monitoring-rules`,
`kube-state-metrics-rules`, …). Until 2026-08-04 Alertmanager's four receivers —
`Default`, `Watchdog`, `Critical`, `null` — were **bare names with no configuration**, so every
one of those rules evaluated, fired, reached Alertmanager and was silently discarded. Six
alerts were firing when this was found, two of them `critical`, and nothing had ever been sent.

| Receiver | Wired to |
|---|---|
| `Default` | ntfy `yolo-private-cloud-platform`, `max_alerts: 5`, priority 3 |
| `Critical` | same topic, priority 5 (urgent) |
| `Watchdog` | **deliberately still a no-op** — it fires continuously by design; its *absence* is the signal, checked from outside by `alerting-pipeline-watch.sh` |
| `null` | `InfoInhibitor`, plus the two minikube false positives below |

**ntfy does the formatting.** Alertmanager's webhook payload is a fixed JSON document — unlike
Grafana's webhook contact point there is no title/message template to hand it. So the URLs
carry ntfy's own `?tpl=yes` templating, which renders Go templates in `t=`, `m=` and `p=`
against the posted JSON. That is why they are unreadable; the decoded templates are in a
comment at the top of `manifests/alertmanager-secret.yaml`. ASCII only — the rendered title
becomes an HTTP header, and headers are latin1 (the same constraint as `ntfy_header_safe`).

**Two rules are routed to `null` on purpose.** `KubeSchedulerDown` and
`KubeControllerManagerDown` fire permanently on this cluster while both components are
perfectly healthy: minikube binds them to `127.0.0.1`, so they have no Service, kube-prometheus's
ServiceMonitors find no targets, and the rules — `absent(up{job=...} == 1)` — never clear.
Deleting the ServiceMonitors makes it *worse*, not better. The real fix is a minikube restart
with `--extra-config=scheduler.bind-address=0.0.0.0` (and the same for the controller manager)
plus Services for both; until then the route suppresses two guaranteed false pages. **If you
ever make them scrapable, delete that route** or you will have muted two genuine alerts.

**This box's own hardware** is the one thing upstream cannot know about, so
`manifests/platform-hardware-prometheusRule.yaml` adds CPU package temperature (90 °C warning
/ 95 °C critical), GPU temperature (85 / 90 °C) and GPU framebuffer (90 % full). Thresholds are
copied from the old `RC_*` defaults so the move did not silently change *when* you get told,
and `for: 15m` reproduces the old 3-sample debounce. Note **CPU temp is
`node_thermal_zone_temp{type="x86_pkg_temp"}`**: node-exporter runs with
`--no-collector.hwmon`, so `node_hwmon_temp_celsius` does not exist here and a rule using it
would never fire.

**Grafana alerting is a separate system and stays that way.** The yolo app repo owns
`grafana-alerting-yolo` (→ topic `yolo-grafana`); this is Alertmanager (→
`yolo-private-cloud-platform`). Grafana can *see* these alerts — kube-prometheus adds an
`Alertmanager` datasource (uid `platform-alertmanager`) with a matching NetworkPolicy ingress
rule — but `handleGrafanaManagedAlerts: false` stops Grafana forwarding its own rules here,
which would hijack the yolo app alerts away from their contact point.

---

## 8. Maintenance Scripts

| Script | Purpose |
|--------|---------|
| `start-scratch.sh` | Cold bootstrap of the whole stack |
| `restart-minikube.sh` | Warm restart (reuse cluster, idempotent vault, apps commented out) |
| `minikube-delete-and-upgrade.sh` | Delete cluster, reinstall latest Minikube (kvm2 + GPU addons) |
| `backup-minikube-mnt.sh` | **Weekly `root` cron** (Mon ~05:00): compress shared volume (secrets + DB snapshots) + nginx + STEP0 + qcguy → dated `.tgz` in `/mnt/minikube-backups`, prune (keep weekly for current+previous month, one per older month), then copy the archive **off-site to the WD Cloud NAS** (`192.168.50.169`, NFS at `/mnt/wdcloud`) with the same month-retention prune (no age floor). See §7 "Off-site copy". |
| `ntfy-lib.sh` | Sourceable push-notification library: the seven-channel registry, latin1-safe header sanitising, fail-soft `ntfy_push`. See §7a. |
| `ntfy-topic-check.sh` | Read-only gate over §7a — unregistered topics, publishers that stopped sourcing the lib, hardcoded URLs, and (check 5) the **non-bash** publishers: the Alertmanager secret and the Grafana alerting ConfigMap. Exit 1 on a violation. |
| `alerting-pipeline-watch.sh` | `*/5` cloud cron: Prometheus up, Alertmanager up, `Watchdog` alert firing, notification failures → ntfy when sustained. Runs **outside** the cluster; renamed from `resource-crunch-watch.sh` 2026-08-04 when the resource thresholds moved into Alertmanager. `--status` prints everything without sending. See §7a/§7b. |
| `reduce-docker-minikube-space.sh` | apt/journal clean + `docker system prune` on host **and** inside Minikube |
| `reduce-node-docker-cache.sh` | **Daily 04:30 cloud cron — what keeps `/var` flat.** Caps buildkit on the node (3GB) AND the host (2GB), and removes orphaned named build-cache volumes via an ALLOWLIST. Added host-side 2026-08-04 after `/var` hit 90% and the kubelet declared `DiskPressure=True`, tainting the node so Prometheus itself sat Pending — the script had been running daily but only pruned the node, while the 11GB sat in host Jenkins cache volumes. ⚠️ Never replace the allowlist with `docker volume prune`: the unused-volume list also holds `nginx_npm_data`, `letsencrypt` and a DB volume. `--dry-run` available. |
| `reduce-var-space.sh` | Truncate logs, vacuum journald, prune docker |
| `delete-docker-reg-images.sh` | GC orphaned blobs in the registry |
| `remove-old-snaps.sh` | Remove disabled snap revisions |
| `test.sh` | Ad-hoc check of `yolo` pod status |

---

## 9. Important Quirk — Two `Ideaprojects` Directories

The host has **two near-identical directories that differ only by case**:

- `/home/cloud/Ideaprojects` (lowercase `p`) — STEP0, vault, jenkins, qcguy-ghost, nginx, kube-prometheus, ollama.
- `/home/cloud/IdeaProjects` (capital `P`) — the **populated** `splunk-hsbc-demo`.

`start-scratch.sh` references both casings (`$HOME/Ideaprojects/...` for most steps,
`$HOME/IdeaProjects/splunk-hsbc-demo/...` for Splunk). On case-sensitive Linux these
are **different paths**, and the script only works because both directories happen to
exist. This is fragile — see `plan.md`.

---

## 10. Deploying a NEW app onto the cluster (dev → prod scaffolding)

This is the playbook for onboarding a brand-new project onto `private-cloud`. The whole
platform is **convention over configuration**: copy the patterns below and your app gets
secrets, CI/CD, a public HTTPS domain, and weekly backups "for free". The two reference
apps to copy from are **qcguy-ghost** (simplest: public image + Vault-injected config)
and **ollama** (GPU + Vault). Real file paths are given so you can lift the skeletons.

### 10.1 The mental model

```
GitHub repo (your app)
  ├─ Dockerfile                         → image
  ├─ compiled.yaml                      → Namespace + ServiceAccount + Deployment + NodePort Service
  ├─ Jenkinsfile                        → vaultSync → docker build/push → kubectl apply → rollout status
  └─ vault/<svc>.env, <svc>.secret.sops.env  → config + SOPS-encrypted secrets

Jenkins build  ──push──▶  registry (container-registry.traderyolo.com → 172.16.238.2:5000, blobs on `Kachra`)
               ──apply─▶  K8s ns "<app>"  ──Service type:NodePort 30XXX on 172.16.238.2
Vault agent injector  ──reads kv/<app>/*──▶  renders /vault/secrets/* into the pod
nginx-proxy-manager   ──<app>.com (TLS) ──▶  172.16.238.2:30XXX
```

Each app owns exactly **one Kubernetes namespace**, **one NodePort**, **one Vault KV path
`kv/<app>/*`** + policy + K8s-auth role + `jenkins-<app>` AppRole, **one Jenkins job**, and
**one (or more) NPM proxy host(s)**. Persistent data goes under the shared mount so it is
backed up (§10.7).

### 10.2 Dev vs prod — what each means here

The two environments are **not** two namespaces on the cluster. The convention is:

| | Where it runs | How it gets config/secrets | Ingress |
|---|---|---|---|
| **dev**  | **Local, OFF the cluster** — on the host/laptop (e.g. `docker-compose up`, or running the binary/process directly). Minikube is not involved. | Source the same repo files: `vault/<svc>.env` for config + `sops -d vault/<svc>.secret.sops.env` to decrypt secrets locally. No Vault server needed. | `localhost:<port>` |
| **prod** | **The minikube cluster only** — `compiled.yaml` applied into namespace `<app>`, image from the private registry. | Vault agent injector renders `kv/<app>/*` into the pod at runtime. | NPM domain (TLS) → NodePort `30XXX` on `172.16.238.2` |

So **everything from §10.3 onward (NodePort, namespace, Vault role/AppRole, Jenkins, NPM) is
PROD** — the steps to put an app on the cluster. **Dev needs none of it**: clone the repo,
provide the env (the un-encrypted `.env` plus a local `sops -d` of the secrets file), and run
it on your machine. The same `vault/*.env` + `*.secret.sops.env` files are the single source
of truth for both — dev reads them directly; prod gets them via `vaultSync` → `kv/<app>/*` →
the injector. Keep the **dev port and the prod NodePort distinct in your head**: dev binds a
local port on the host; prod publishes a cluster NodePort.

### 10.3 Step-by-step checklist (PROD / on-cluster)

1. **Pick a free NodePort** in `30000–32767`. The authoritative list of what's already
   taken is the **NPM routing table in §3** (and `grep -rn 'nodePort:' ~/Ideaprojects/*/compiled.yaml`).
   Record your new one back into §3 when you add the proxy host.
2. **Write `compiled.yaml`** — Namespace, `vault-secrets` ServiceAccount, Deployment, and a
   `type: NodePort` Service (skeleton in §10.4).
3. **Write `Dockerfile`** and confirm the image name `container-registry.traderyolo.com/<app>:<tag>`.
4. **Write `vault/<svc>.env` (config) + `vault/<svc>.secret.sops.env` (SOPS+age encrypted)**
   in the app repo. These are the source of truth for `kv/<app>/*`.
5. **Provision Vault for the app** (§10.5) — policy, K8s-auth role, `jenkins-<app>` AppRole;
   paste the AppRole creds into Jenkins credentials.
6. **Write `Jenkinsfile`** (§10.6): `vaultSync(app:'<app>')` → build/push → `kubectl apply`
   → `kubectl rollout status`.
7. **Create the Jenkins job** pointing at the repo, then add a trigger line to
   `start-scratch.sh` so a cold rebuild redeploys it:
   `curl -X POST https://private-cloud:<JENKINS_TOKEN>@jenkins.traderyolo.com/job/<app>/build?token=<jobtoken>`
8. **Add an NPM proxy host** in `~/Ideaprojects/nginx` (admin UI :81): `<app>.com` (HTTPS,
   Let's Encrypt) → forward to `172.16.238.2:30XXX`. Update §3.
9. **Point DNS** for the domain at the host's public IP.

### 10.4 `compiled.yaml` skeleton (copy from `qcguy-ghost/compiled.yaml`)

```yaml
apiVersion: v1
kind: Namespace
metadata: { name: myapp }
---
apiVersion: v1
kind: ServiceAccount
metadata: { name: vault-secrets, namespace: myapp }   # bound to the Vault K8s-auth role
---
apiVersion: apps/v1
kind: Deployment
metadata: { name: myapp, namespace: myapp, labels: { app: myapp } }
spec:
  selector: { matchLabels: { app: myapp } }
  template:
    metadata:
      labels: { app: myapp }
      annotations:
        vault.hashicorp.com/agent-inject: 'true'
        vault.hashicorp.com/role: 'myapp-role'                 # matches the K8s-auth role
        vault.hashicorp.com/agent-pre-populate-only: 'true'    # render once at startup, no sidecar
        vault.hashicorp.com/agent-inject-secret-app.env: 'kv/myapp/config'
        vault.hashicorp.com/agent-inject-template-app.env: |
          {{- with secret "kv/myapp/config" -}}
          {{- range $k, $v := .Data.data }}{{ $k }}={{ $v }}
          {{ end -}}{{- end -}}
    spec:
      serviceAccountName: vault-secrets
      # nodeSelector / "nvidia.com/gpu: 1" resource limits ONLY if you need the RTX 3080 Ti (see ollama)
      containers:
        - name: myapp
          image: container-registry.traderyolo.com/myapp:latest
          imagePullPolicy: IfNotPresent
          # secrets rendered to /vault/secrets/app.env — source it in your entrypoint
---
apiVersion: v1
kind: Service
metadata: { name: myapp, namespace: myapp, labels: { app: myapp } }
spec:
  type: NodePort
  selector: { app: myapp }
  ports:
    - { port: 80, targetPort: 8080, nodePort: 30XXX }   # 30XXX = your chosen free port
```

### 10.5 Vault provisioning for the app (in the **vault** repo)

1. `vault/<app>-policy.hcl` — least privilege:
   ```hcl
   path "kv/data/<app>/*"     { capabilities = ["read"] }
   path "kv/metadata/<app>/*" { capabilities = ["read","list"] }
   ```
2. K8s-auth role (add to `start-vault.sh` so cold bootstrap recreates it):
   ```bash
   vault write auth/kubernetes/role/<app>-role \
     bound_service_account_names=vault-secrets \
     bound_service_account_namespaces=<app> \
     policies=<app>-policy
   ```
3. Jenkins AppRole for the sync pipeline:
   ```bash
   ~/Ideaprojects/vault/scripts/setup-jenkins-approle.sh <app>
   # writes role_id/secret_id to ~/.vault/jenkins-approle/<app>.env (0600)
   ```
4. In Jenkins, add credentials `vault-approle-id-<app>` / `vault-approle-secret-<app>` from
   that file, and ensure the shared `sops-age-key` credential exists.

Secrets then flow: app repo `vault/*.env` + `*.secret.sops.env` → `vaultSync(app:'<app>')`
merges them into `kv/<app>/*` (never clobbering sibling keys) → the agent injector renders
them into the pod. See vault repo `vault-sync.sh` / `vars/vaultSync.groovy`.

### 10.6 `Jenkinsfile` skeleton (copy from `qcguy-ghost/Jenkinsfile`)

```groovy
pipeline {
  agent none
  stages {
    stage('Refresh Vault secrets') {
      agent { kubernetes { cloud 'kubernetes'; label 'kubeagent'; defaultContainer 'jnlp' } }
      steps {
        checkout scm
        script {
          library identifier: 'vault-tools@main', retriever: modernSCM([
            $class: 'GitSCMSource', remote: 'https://github.com/wiqram/vault.git',
            credentialsId: '<vault-repo-cred-id>'])
          vaultSync(app: 'myapp')          // ./vault/*.env (+ sops) → kv/myapp/*
        }
      }
    }
    stage('Build & push') {
      agent { kubernetes { cloud 'kubernetes'; label 'kubeagent'; defaultContainer 'jnlp' } }
      steps {
        checkout scm
        sh 'docker build -t container-registry.traderyolo.com/myapp:latest .'
        sh 'docker push container-registry.traderyolo.com/myapp:latest'
      }
    }
    stage('Deploy') {
      agent { kubernetes { cloud 'kubernetes'; label 'kubeagent'; defaultContainer 'jnlp' } }
      steps {
        checkout scm
        sh 'kubectl apply -f compiled.yaml'
        sh 'kubectl rollout status deployment -n myapp myapp --timeout=240s'
      }
    }
  }
}
```

The build runs on the custom **`jenkins-inbound-agent-vik:cloud`** agent image
(`~/Ideaprojects/jenkins/inbound-agent/`), which already has `kubectl`, `vault`, `sops`,
`age`, `jq`, `docker`. If your build needs more tooling, extend that image and re-push it.

### 10.7 Persistence & backups for the new app

Anything the app must **not lose** (DB data dirs, uploads, generated keys) should live under
the shared mount `/mnt/minikube-mnt/<app>/` (appears as `/mnt/<app>` inside
the cluster — use a `hostPath`/`local` PV pointing there). It is then captured by the weekly
backup automatically (§7). **Do not** rely on backing up reproducible artifacts (container
images, downloadable model weights — cf. the `ollama/models` exclude); back up only the
irreplaceable state. If the app needs a *consistent* DB snapshot, add a `mongodump`/`pg_dump`
CronJob that writes into `minikube-mnt/<app>-backups/` rather than trusting the hot file copy.

### 10.8 Don't forget

- **NodePort uniqueness** — a clash silently breaks routing; check §3 first, update it after.
- **Image pull** — manifests use `imagePullPolicy: IfNotPresent` against the insecure
  registry `172.16.238.2:5000`; the cluster trusts it via `--insecure-registry` (already set).
- **GPU** — only request `nvidia.com/gpu` if you truly need it; there is exactly one RTX
  3080 Ti shared across the node (ollama is the heavy user).
- **No secrets in Git or manifests** — config goes in `*.env`, secrets in `*.secret.sops.env`
  (SOPS+age), everything else is read from Vault at runtime.
- **Wire it into `start-scratch.sh`** — otherwise a cold rebuild won't bring your app back.
