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

---

## 5. Platform Services

### HashiCorp Vault (`~/Ideaprojects/vault/`)
STEP0 delegates **all** Vault setup to `bash start-vault.sh` in the vault repo; the
ordering (Vault before Jenkins/apps) is what matters here. The vault repo owns its own
`architecture.md` / `plan.md` / `CLAUDE.md` — defer to those for detail. Current shape:
- Installed via Helm into the `vault` namespace; images **pinned** (vault `2.0.2`,
  vault-k8s `1.7.4` — no longer `latest`).
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
- Replaces the `metrics-server` addon (intentionally not enabled).

### CI/CD — Jenkins (`~/Ideaprojects/jenkins/`)
- Custom `inbound-agent` image (kubectl + curl + wget pre-installed) pushed to the private registry.
- Pipelines triggered remotely by `curl -X POST` with basic-auth + job token:
  `predictonomy`, `trading-microservices` (yolo). Builds produce images that land in the registry and deploy to K8s.
- **`vault-secrets-sync` pipeline** (vault repo `ci/Jenkinsfile`) additionally needs
  **`vault`, `sops`, `age`, `jq`** on the agent image, the `sops-age-key` credential, and
  the per-app `vault-approle-id`/`vault-approle-secret` credentials. If you rebuild the
  inbound-agent image, add those CLIs (see vault `plan.md`).

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

### Weekly automated backup (cron)

A **`root` cron job runs weekly** (Mondays ~05:00) and executes
**`backup-minikube-mnt.sh`**. This is the disaster-recovery safety net: if anything
happens to the `private-cloud` host, these archives are what the stack is rebuilt from.
Every run produces a single compressed, dated archive
`private-cloud-<MM-DD-YY>.tgz` (≈4–5 GB) under **`/mnt/minikube-backups`** (root-owned).

**Retention (space-saving prune, at the end of each run):** all weekly backups for the
**current and previous month** are kept; for any **older month** only that month's
**most recent** backup is kept and the rest are deleted. So recent history stays
weekly-granular while older months collapse to one archive each (≈4–5 GB/month saved
per pruned week).

The script `tar -czf`s four trees — `minikube-mnt`, `~/Ideaprojects/nginx`,
`~/Ideaprojects/STEP0`, and `~/Ideaprojects/qcguy-ghost` — but the bulk of the value is
inside the **`minikube-mnt`** shared volume, which captures everything that **can't live
in GitHub**:

- **Per-app secrets / Vault seed material** — `yolo-`, `helpmepdf-`, `predictonomy-`,
  `ollama-env-variables.sh`, the SOPS age key (`keys-sops-IMPORTANT.txt`) and
  `phase-file-secrets-kv.txt`. (Before archiving, the script refreshes all four live env
  scripts — yolo, helpmepdf, predictonomy, ollama — from `~/Ideaprojects/vault/` into
  `minikube-mnt`.)
- **Database snapshots** (for restoring app state) — `yolo-db-snapshots`,
  `predictonomy-backups` + `predictonomy-postgres`, and the MongoDB `storage.bson`
  dumps under `trading-microservices/` and `helpmepdf/`.
- **App data & platform state** — `qcguy-ghost` (Ghost content), `ollama`, `jenkins`,
  `container-registry`, `splunk-hsbc`, `tatesremedies`.
- **Ingress + bootstrap config** — the NPM tree (`nginx/`) and the STEP0 scripts.

To restore, unpack the relevant tree from the latest `private-cloud-*.tgz` back into
place, then re-bootstrap via `start-scratch.sh` (which re-seeds Vault from the recovered
`/mnt` secret scripts and redeploys the apps).

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

---

## 8. Maintenance Scripts

| Script | Purpose |
|--------|---------|
| `start-scratch.sh` | Cold bootstrap of the whole stack |
| `restart-minikube.sh` | Warm restart (reuse cluster, idempotent vault, apps commented out) |
| `minikube-delete-and-upgrade.sh` | Delete cluster, reinstall latest Minikube (kvm2 + GPU addons) |
| `backup-minikube-mnt.sh` | **Weekly `root` cron** (Mon ~05:00): compress shared volume (secrets + DB snapshots) + nginx + STEP0 + qcguy → dated `.tgz` in `/mnt/minikube-backups`, then prune (keep weekly for current+previous month, one per older month) |
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
