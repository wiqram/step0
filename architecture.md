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
| **prod** (`private-cloud`) | runs Docker + minikube + everything in this repo | `enp4s0` → `10.10.10.1/30` | `enp6s0` (192.168.50.x) |
| **dev** (`vik@10.10.10.2`) | developer workstation (IntelliJ, builds); **not** part of the cluster | `eno1` → `10.10.10.2/30` | `eno2` (192.168.50.x) |

The dev box has **direct `kubectl` access to the prod Kubernetes API** (`172.16.238.2:8443`)
across this link — used from the CLI and from **IntelliJ Services → Kubernetes**. Scope is
**API-only** (no registry/NodePort/pod-network reachability). How it's wired:

- **Prod host firewall** — the API lives on the `5million` docker bridge, so traffic from
  `enp4s0` into it is *forwarded* traffic that Docker's `FORWARD` chain drops by default.
  `enable-devbox-kube-access.sh` inserts two `DOCKER-USER` ACCEPT rules
  (`10.10.10.2 → 172.16.238.2:8443` + established return), matched on **dest IP/port** (never
  the `br-<id>` name, which changes when `5million` is recreated). Persisted by the
  `devbox-kube-access.service` systemd unit (`After=docker.service`; `DOCKER-USER` is wiped on
  docker restart) and re-armed by `start-scratch.sh` / `restart-minikube.sh`.
- **Dev box route** — a persistent NetworkManager route `172.16.238.2/32 via 10.10.10.1`
  on `eno1` (NM connection `"Wired connection 1"`) forces API traffic over the 10GbE link
  instead of the LAN gateway.
- **Dev box kubeconfig** — a flattened, cert-embedded copy of prod's admin kubeconfig, with
  its cluster/user/context renamed to **`prod-minikube`** so it coexists with the dev box's
  own local `minikube` context. The API cert already carries `IP Address:172.16.238.2` in its
  SANs, so TLS validates unchanged.
- From-scratch rebuild: prod side is `enable-devbox-kube-access.sh --install`; dev side is
  `devbox-connect-prod.sh` (this repo). The exported kubeconfig is **cluster-admin** —
  acceptable over the single-peer /30 cable.

> Note the `minikube` / `minikube-private-cloud.com` NPM entry above (→ `8443`) is a
> *public/DNS* path to the API; the dev box instead reaches `172.16.238.2:8443` **directly**
> over 10GbE, bypassing NPM.

### Triggering Jenkins deploys from the dev box

Any app's Jenkins deploy job can be fired **directly from the dev box** — no operator
action on prod required. Unlike kube-API access above, this path does **not** use the
10GbE link: it goes to `https://jenkins.traderyolo.com` through NPM like any public
client (prod runs no sshd, so SSH-back is not an option; verified 2026-07-01).

```bash
# on the dev box
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

---

## 4. Bootstrap Flow — `start-scratch.sh`

Executed top to bottom (`set -e`, so any failure aborts the run):

1. **Docker network** – create `5million` if missing.
2. **Minikube** – if `kubectl version` fails (no cluster), `minikube start` with:
   `--cpus 12 --memory 32768 --disk-size 40g --driver=docker --network 5million
   --gpus all --mount /mnt/minikube-backups/minikube-mnt:/mnt
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
  leaves metrics-server as the owner. prometheus-adapter still runs for *custom* metrics
  (separate APIService).
- **Verify:** `kubectl get apiservice v1beta1.metrics.k8s.io` (owner should be
  `kube-system/metrics-server`, `Available=True`) and `kubectl top pod -A`.
- **Background:** the root-cause investigation, durability layers, and watch-items are in
  [`HANDOFF-2026-06-16-metrics-server-and-rollout-fixes.md`](./HANDOFF-2026-06-16-metrics-server-and-rollout-fixes.md).

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

- **Shared volume:** `/mnt/minikube-backups/minikube-mnt` (on `/dev/sdb1`) is mounted into
  the Minikube node at `/mnt`. It carries per-app env/secret scripts and app data shared
  between host and cluster. Inside it, `container-registry-images/` is itself a **separate
  `/dev/sdb2` mount** (the durable registry from commit R8) — `tar` descends into it
  normally, so it is captured by the backup.
- **Location history (important).** The shared volume used to live at
  `~/Ideaprojects/minikube-mnt` (on the `/home` disk, `/dev/sda6`). It was relocated to
  `/mnt/minikube-backups/minikube-mnt` and `restart-minikube.sh` / `start-scratch.sh`
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
> the exclude each weekly archive would balloon from ~5 GB to ~40 GB and fill `/dev/sdb1`
> under the retention policy. Ollama's identity key (`id_ed25519`) lives outside `models/`
> and **is** captured. On restore, re-fetch the model rather than expecting it in the tar.

**Retention (space-saving prune, at the end of each run):** all weekly backups for the
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
- **App data & platform state** — `qcguy-ghost` (Ghost content), `ollama`, `jenkins`,
  `container-registry`, `splunk-hsbc`, `tatesremedies`.
- **Ingress + bootstrap config** — the NPM tree (`nginx/`) and the STEP0 scripts.

To restore, unpack the relevant tree from the latest `private-cloud-*.tgz` back into
place, then re-bootstrap via `start-scratch.sh` (which re-seeds Vault from the recovered
`/mnt` secret scripts and redeploys the apps).

### Off-site copy — Google Cloud Storage Coldline

After the local archive + prune, the **same script** pushes that run's `.tgz` **off-site**
to **`gs://private_cloud_backup`** (storage class **Coldline**, **asia** multi-region,
project `igtrader-296013`). This is the off-host leg of disaster recovery — a
fire/theft/disk-loss that takes out `/dev/sdb1` no longer takes out every backup. (The
existing local archives were backfilled to the bucket when this was first set up.)

- **No re-zip** — the local `.tgz` is already compressed; it is uploaded as-is.
- **Auth** — a dedicated GCP service account
  `step0-backup@igtrader-296013.iam.gserviceaccount.com` (role `roles/storage.objectAdmin`
  on the bucket — needs object create **and** delete for the prune), via a key at
  **`~/.gcp/step0-backup-key.json`** (0600, outside every repo, readable by the root cron).
  The script activates it into an isolated `CLOUDSDK_CONFIG=~/.gcp/cloudsdk-config`.
- **gcloud is a no-root (home) install** at `~/google-cloud-sdk`; the script calls it by
  **absolute path** (`GCLOUD_BIN`) because the root cron's `PATH` won't include it.
- **Bucket prune mirrors the local retention** (current + previous month, one per older
  month) **plus a 90-day age floor** (`GCS_MIN_AGE_DAYS=93`). Coldline has a **90-day
  minimum storage duration**, so deleting earlier incurs an early-deletion fee; a
  delete-candidate younger than the floor is left until a later weekly run prunes it for
  free. Object age is read from the **date in the filename** (uploaded the same day), so the
  prune makes **no** extra GCS metadata/API calls.
- **Fully additive + guarded** — a missing `gcloud`/key or any network failure only `WARN`s
  to `/var/log/minikube-backup.log`; it never aborts or affects the local backup.

One-time setup (create bucket → service account → `objectAdmin` binding → key) is documented
verbatim in the script's header comment.

**Restoring from the off-site copy.** `restore-scratch.sh` is the documented inverse: on a bare Ubuntu
box it picks the newest `private-cloud-*.tgz` from the bucket (date parsed from the filename, like the
prune) via an interactive `gcloud auth login` — note the SA key (`~/.gcp/step0-backup-key.json`) is
**not** in the bucket or the tar, so the first pull uses your own Google identity. Two things are not in
the archive and are reconstructed on restore: the **registry blobs** (they live on sdb2/`/mnt/kachra`,
re-pushed by Jenkins on a single-disk rebuild) and the **ollama models** (`*/ollama/models` excluded,
re-pulled). See `docs/superpowers/specs/2026-06-30-restore-scratch-design.md`.

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
| `backup-minikube-mnt.sh` | **Weekly `root` cron** (Mon ~05:00): compress shared volume (secrets + DB snapshots) + nginx + STEP0 + qcguy → dated `.tgz` in `/mnt/minikube-backups`, prune (keep weekly for current+previous month, one per older month), then push the archive **off-site to GCS Coldline** (`gs://private_cloud_backup`) with a 90-day-floor prune. See §7 "Off-site copy". |
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

Jenkins build  ──push──▶  registry (container-registry.traderyolo.com → 172.16.238.2:5000, blobs on sdb2)
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
the shared mount `/mnt/minikube-backups/minikube-mnt/<app>/` (appears as `/mnt/<app>` inside
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
