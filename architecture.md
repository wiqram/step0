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
│         mount: /mnt/minikube-backups/minikube-mnt → /mnt              │
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
│         │             ollama (deepseek-r1:14b, GPU)                │  │
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

---

## 4. Bootstrap Flow — `start-scratch.sh`

Executed top to bottom (`set -e`, so any failure aborts the run):

1. **Docker network** – create `5million` if missing.
2. **Minikube** – if `kubectl version` fails (no cluster), `minikube start` with:
   `--cpus 12 --memory 32768 --disk-size 40g --driver=docker --network 5million
   --gpus all --mount /mnt/minikube-backups/minikube-mnt:/mnt
   --insecure-registry 172.16.238.2:5000` plus kubelet/scheduler/controller webhook flags.
3. **Addons** – `registry`, `nvidia-gpu-device-plugin`.
4. **Monitoring** – apply `kube-prometheus` (`manifests/setup` → wait for CRDs → `manifests/`) into `monitoring` ns.
5. **Vault** – `cd ~/Ideaprojects/vault && bash start-vault.sh` (Helm install, init, unseal, policies, K8s auth, load per-app secrets from `/mnt`).
6. **Jenkins** – build the custom `jenkins-inbound-agent-vik:cloud` image if absent, push to `container-registry.traderyolo.com`, then `kubectl apply` Jenkins manifests.
7. **qcguy** – create `qcguy` ns + configmap from `~/Ideaprojects/qcguy-ghost/config`, apply `compiled.yaml`.
8. **predictonomy** – trigger Jenkins build via authenticated `curl` to `jenkins.traderyolo.com/job/predictonomy/build`.
9. **yolo** – `sleep 1m`, then trigger Jenkins `trading-microservices` build.
10. **Splunk (HSBC demo)** – apply namespace + `compiled.yaml`, `sleep 3m`, then deploy Splunk Connect for Kubernetes (SCK) via Helm with HEC token/index env vars.

`restart-minikube.sh` is the lighter-weight variant: it reuses an existing cluster,
calls `restart-vault.sh` (idempotent, skips re-init), and leaves monitoring / qcguy /
splunk **commented out**. Use it for a warm restart; use `start-scratch.sh` for a
cold rebuild.

---

## 5. Platform Services

### HashiCorp Vault (`~/Ideaprojects/vault/`)
- Installed via Helm into the `vault` namespace.
- `start-vault.sh`: init with 1 key share / threshold 1, unseal, write `admin` policy,
  enable `userpass` (user `privatecloud`) and `kubernetes` auth, enable KV-v2 at `kv/`.
- Per-app secrets loaded from `/mnt/.../minikube-mnt/*-env-variables.sh` (yolo, helpmepdf, ollama, predictonomy).
- Per-app K8s auth roles + policies (`yolo-policy.hcl`, etc.) so pods authenticate by ServiceAccount.
- `cluster-keys.json` holds the **root token + unseal key** (see security notes in `plan.md`).

### Monitoring — kube-prometheus (`~/Ideaprojects/kube-prometheus/`)
- Full Prometheus Operator + Grafana + Alertmanager stack in the `monitoring` ns.
- Replaces the `metrics-server` addon (intentionally not enabled).

### CI/CD — Jenkins (`~/Ideaprojects/jenkins/`)
- Custom `inbound-agent` image (kubectl + curl + wget pre-installed) pushed to the private registry.
- Pipelines triggered remotely by `curl -X POST` with basic-auth + job token:
  `predictonomy`, `trading-microservices` (yolo). Builds produce images that land in the registry and deploy to K8s.

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
| **ollama** | Ollama + DeepSeek | `Modelfile`, `~/Ideaprojects/ollama` | `deepseek-r1:14b` equities research model, GPU-backed; streaming proxy |
| **splunk** | Splunk Enterprise | `~/IdeaProjects/splunk-hsbc-demo` | HSBC demo; SCK log forwarding; optional |
| **tatesremedies** | (legacy) | `~/Ideaprojects/tatesremedies` | Old kvm2 deployment, currently disabled |

### Ollama model (`Modelfile`)
`FROM deepseek-r1:14b` with a stock-market-research system prompt (temperature 0.4,
top_p 0.9, num_ctx 8192). Served via `ollama.traderyolo.com` with streaming-friendly
Nginx config (buffering off, 600s timeouts).

---

## 7. Persistence & Backups

- **Shared volume:** `/mnt/minikube-backups/minikube-mnt` is mounted into the Minikube
  node at `/mnt`. It carries per-app env/secret scripts and app data shared between host and cluster.
- **`backup-minikube-mnt.sh`:** copies the live yolo/helpmepdf Vault env scripts into
  `minikube-mnt`, then `tar`s `minikube-mnt`, `nginx`, `STEP0`, and `qcguy-ghost` into a
  dated `.tgz` under `/mnt/minikube-backups`.

---

## 8. Maintenance Scripts

| Script | Purpose |
|--------|---------|
| `start-scratch.sh` | Cold bootstrap of the whole stack |
| `restart-minikube.sh` | Warm restart (reuse cluster, idempotent vault, apps commented out) |
| `minikube-delete-and-upgrade.sh` | Delete cluster, reinstall latest Minikube (kvm2 + GPU addons) |
| `backup-minikube-mnt.sh` | Backup shared volume + nginx + STEP0 + qcguy |
| `reduce-docker-minikube-space.sh` | apt/journal clean + `docker system prune` on host **and** inside Minikube |
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
