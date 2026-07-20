# CLAUDE.md — STEP0 (Private-Cloud Bootstrap)

Guidance for Claude Code when working in this repository. See `README.md` for the
human-facing front door, `architecture.md` for the full system design (incl. **§10 "deploy
a new app" scaffolding**), and `plan.md` for the improvement backlog.

> **Creating a NEW website/app to deploy here? → read [`base-architecture-scaffold.md`](./base-architecture-scaffold.md) FIRST.**
> It's the copy-paste contract for what files a new project needs (Dockerfile/.production,
> docker-compose dev+prod, Jenkinsfile, namespace.yaml, deployment.yaml with Vault injector
> annotations, `vault/` SOPS secrets) and the exact platform touch-points to register (Vault
> policy/role, Jenkins job + build token, a free NodePort, the NPM proxy host, the cold-boot
> trigger line). Don't re-discover the pattern — start there.

## What this repo is

> **Cluster unhealthy after a reboot/crash? → read [`RESTART-RECOVERY.md`](./RESTART-RECOVERY.md) FIRST**
> (warm-vs-cold decision, what auto-recovers — auto-start + Vault auto-unseal — and a symptom→fix triage).

STEP0 is the **bootstrap layer** for a single-node, GPU-accelerated private cloud
running on one Ubuntu workstation (`private-cloud`: i9-12900K / 48 GB / RTX 3080 Ti /
ASUS ProArt Z690). It is a collection of bash scripts — **not** an application
codebase. The flagship file is `start-scratch.sh`, which brings the entire stack up
from a clean machine.

The stack: Docker → single-node **Minikube** (driver=docker, GPU passthrough) →
Kubernetes platform (Vault, Jenkins, kube-prometheus, registry) → apps (qcguy/Ghost,
yolo/trading-microservices, predictonomy, helpmepdf, ollama, splunk). Public traffic
enters through **nginx-proxy-manager**, which TLS-terminates and forwards each domain
to a Kubernetes NodePort on `172.16.238.2`.

## Key files

| File | Role |
|------|------|
| `start-scratch.sh` | **Master cold-bootstrap.** Order matters: network → minikube → addons → monitoring → vault → jenkins → qcguy → app builds → splunk. |
| `restart-minikube.sh` | Warm restart; reuses cluster, idempotent vault, most apps commented out. |
| `minikube-delete-and-upgrade.sh` | Nuke + reinstall latest Minikube. |
| `backup-minikube-mnt.sh` | **Weekly disaster-recovery backup** (run by a `root` cron, Mondays ~05:00). Compresses the `minikube-mnt` shared volume — per-app secrets (qcguy, vault/SOPS keys, ollama, predictonomy, yolo, helpmepdf) and DB snapshots — plus nginx + STEP0 + qcguy + the `~/wd-backup` toolkit (script, config **and** its non-git SMB creds, so a restore can re-arm the nightly WD My Cloud job without the dev box; `logs/` excluded) into a dated `private-cloud-<date>.tgz` in `/mnt/minikube-backups`, then prunes for space (keeps weekly backups for the current + previous month; for older months keeps only the latest backup of each). Finally copies the archive **off-site to the WD Cloud 6TB NAS on the LAN** (`192.168.50.169:/nfs/private-cloud`, mounted `/mnt/wdcloud` over NFS — a **`hard`** mount, not `soft`, so a slow fsync can't EIO/truncate the backup; `nofail`+automount keep boot safe) and prunes that share the same way (no age floor — our own disk, deletes are free). Archives land at the share root. No credentials: NFS on the trusted LAN needs none. **One-time manual setup** (WD is an appliance): format the 6TB volume + create the `private-cloud` NFS share in the WD dashboard — its OS3 share-management API resists scripting (rotating tokens; account locks after 5 bad logins). GCS Coldline path retained **commented-out** as a fallback. See `architecture.md` §7 "Off-site copy". |
| `restore-scratch.sh` | **Cold disaster recovery from a bare Ubuntu box** (inverse of `backup-minikube-mnt.sh`). Installs host tooling (incl. `nfs-common`), mounts the WD Cloud NFS share and copies the latest backup from it, restores Vault keys/data + nginx proxy-hosts/certs + secrets + the `~/wd-backup` toolkit, mounts the dedicated backup disk (labels `minikube-backups`/`Kachra`; **non-destructive** — warns with format steps if absent), clones every `wiqram/*` repo, reproduces host config the archive can't carry (`/etc/docker/daemon.json`, the 10GbE `/30` NM profile, the `10gbe-link-watchdog`/`devbox-kube-access` systemd units, the WD Cloud NFS fstab automount, hostname), runs `SKIP_APP_BUILDS=1 start-scratch.sh`, re-arms cron (the weekly DR backup, the canonical cloud crontab **and** the nightly WD My Cloud job via `install-on-prod.sh`), runs `verify-recovery.sh`, then **pauses before app deploys** (manual steps remain: GitHub/`gh` auth before clone, `docker login`, per-box `/etc/hosts`, and wiring any app not in the auto-deploy path — see the handoff) (repoint DNS, then run `trigger-app-builds.sh`). Resumable (`--from-phase N`), inspectable (`--dry-run`). Single-disk restore: registry blobs are rebuilt via Jenkins. See `docs/superpowers/specs/2026-06-30-restore-scratch-design.md`. |
| `trigger-app-builds.sh` | The per-app Jenkins build triggers (qcguy, predictonomy, bestrentaladmin, dyingpaleblue, ollama, trading-microservices), extracted from `start-scratch.sh`. Reads the Jenkins credential from gitignored `.env` (`JENKINS_CRED`). Run after a restore once DNS points at the host; or set `SKIP_APP_BUILDS=1` to make `start-scratch.sh` skip it. Deploys can also be fired from the **dev box** (seeded `~/.jenkins-deploy-urls.env` on `vik@10.10.10.2`) — see `architecture.md` §3 "Triggering Jenkins deploys from the dev box". |
| `enable-devbox-kube-access.sh` | **Prod-host side** of dev-box → prod-cluster access over 10GbE. Inserts `DOCKER-USER` allow rules so the dev box (`10.10.10.2`) can reach the kube API `172.16.238.2:8443`; `--install` adds the `devbox-kube-access.service` systemd unit (re-applies on boot); `--emit-kubeconfig` writes a `prod-minikube` kubeconfig for the dev box. Called best-effort by `start-scratch.sh`/`restart-minikube.sh`. See `architecture.md` §3 "Dev box ↔ prod cluster over 10GbE". |
| `devbox-connect-prod.sh` | **Dev-box side** counterpart (run on `vik@10.10.10.2`): adds the persistent NetworkManager route to the API over 10GbE and merges the emitted kubeconfig as the `prod-minikube` context. `route` / `kubeconfig <file>` / `all <file>` / `test`. `install-unit` installs **`devbox-connect-prod.service`** — a boot-time oneshot running `boot-check` that self-heals the route, verifies the dev **ollama** endpoint (`10.10.10.2:11434`, consumed by prod **yolo**) is serving, and logs a `kubectl get ns` health check to the journal (advisory — never fails the boot). See `architecture.md` §3. |
| `10gbe-link-watchdog.sh` | **Keeps the dev↔prod 10GbE link alive.** Both NICs are `atlantic` (Aquantia/Marvell) 10GBASE-T and the point-to-point link intermittently *wedges* (carrier up, 0 frames, ARP fails both ways) — a link/PHY fault, **not** a kube-access config fault (route/firewall/kubeconfig all survive reboots and work whenever the link is up). Runs as a `systemd` service on **both** ends: pings the peer across the /30 and bounces the local NIC to re-train after a few failed probes. Auto-detects the local 10GbE iface + NM connection, so the same script installs on prod (`enp4s0`) and dev (`eno1`): `sudo ./10gbe-link-watchdog.sh --install`. See `architecture.md` §3 "Link stability". OOB to dev box while 10GbE is dark: `ssh vik@192.168.50.161`. |
| `devbox-jenkins-deploy.sh` | **Dev-box helper** (installed as `~/bin/jenkins-deploy` on `vik@10.10.10.2`): `jenkins-deploy <app>` fires that app's Jenkins deploy via `jenkins.traderyolo.com` using the seeded `~/.jenkins-deploy-urls.env` credential. App mapping mirrors `jenkins-jobs.manifest` — keep in sync. See `architecture.md` §3. |
| `verify-recovery.sh` | **Read-only post-restore survey** (mutates nothing). Confirms the facts a fresh box can silently get wrong: fixed cluster IPs (minikube node `172.16.238.2`, NPM `.10`, 5million subnet `172.16.0.0/16`), backup-NAS reachability + exports (WD Cloud DR `.169` NFS, WD My Cloud `.68`/`.251` SMB), the dev↔prod 10GbE `/30` link + watchdog, and host/DNS/service/cron state (hostname, public IP vs `jenkins.traderyolo.com` A-record, Vault unsealed, both backup crons + cloud crontab). Prints PASS/WARN/FAIL + a "detected values" digest of the env-specific facts; exit 1 on any FAIL. Expected values are env-overridable constants at the top. Called best-effort by `restore-scratch.sh` phase 9; run by hand anytime after a reboot/crash. |
| `reduce-*.sh`, `delete-docker-reg-images.sh`, `remove-old-snaps.sh` | Disk/space maintenance. |
| `Modelfile` | Ollama model def (`deepseek-r1:14b`, equities-research prompt). |
| `5million.xml`, `default.xml` | Legacy libvirt/KVM network defs (kvm2 era). |

## Conventions & facts to respect

- **Vault storage is a pre-created durable PV — never let it go dynamic again.**
  `k8s/vault-backup/vault-data-pv.yaml` (Retain, hostPath `/mnt/vault-data` =
  host `/mnt/minikube-backups/minikube-mnt/vault-data`) MUST be applied before
  `start-vault.sh` (start-scratch does this) so the `data-vault-0` PVC binds it.
  The pre-2026-07-20 dynamic `/tmp` PV silently destroyed all runtime-written KV
  (follower broker secrets, admin platform keys) on a minikube rebuild. Daily
  snapshot CronJob `vault/vault-data-backup` → `minikube-mnt/vault-backups/`
  (swept by the weekly DR tar + WD off-site). Old Retained PV `pvc-cca2a54b-…`
  is the rollback copy — safe to delete after a clean week (~2026-07-27).
- **Single host, single node.** No multi-node K8s. "private cloud" = Docker + one
  Minikube + Nginx, all co-located on `172.16.238.x`.
- **Fixed IPs:** Minikube node `172.16.238.2` (API/NodePorts/registry:5000),
  nginx-proxy-manager `172.16.238.10`, gateway `172.16.238.1`, network `5million`.
- **Two `Ideaprojects` dirs differing only by case** —
  `/home/cloud/Ideaprojects` (lowercase, most things) and
  `/home/cloud/IdeaProjects` (capital P, the populated `splunk-hsbc-demo`).
  `start-scratch.sh` depends on both. **Always preserve the exact casing** already in
  the script; do not "normalize" a path without confirming which directory it resolves to.
- **NodePort ↔ domain mapping** is owned by Nginx Proxy Manager (`~/Ideaprojects/nginx`),
  not by this repo. If you change a service's NodePort, the NPM proxy host must change too.
- **Resource metrics (`kubectl top` / HPAs) come from the `metrics-server` addon**, NOT
  prometheus-adapter. The adapter can't serve pod metrics on this node — the kubelet's
  cAdvisor series lack `pod`/`namespace`/`container` labels, so `top pod` returns empty.
  `start-scratch.sh` and `restart-minikube.sh` both `minikube addons enable metrics-server`,
  and it owns `v1beta1.metrics.k8s.io`. Do **not** re-add kube-prometheus's
  `manifests/prometheusAdapter-apiService.yaml` (removed there) — applying it re-claims that
  API for the adapter and silently re-breaks `top`. Full rationale: `architecture.md` →
  "Resource metrics — metrics-server". Verify with `kubectl get apiservice v1beta1.metrics.k8s.io`
  (owner should be `kube-system/metrics-server`).
- **Secrets are owned by the vault repo, not STEP0.** STEP0 just calls `start-vault.sh`
  in the right order. Apps authenticate to Vault via Kubernetes ServiceAccount auth.
  Seeding is mid-transition: legacy `*-env-variables.sh` on `/mnt` → declarative
  `apps/<app>/*.env` + SOPS-encrypted secrets reconciled by `vault-sync.sh`. `start-vault.sh`
  also provisions per-app Jenkins AppRoles (`jenkins-<app>`) for the sync pipeline. The
  Vault root token + unseal key now live at `~/.vault/cluster-keys.json` (outside any repo).
  See the vault repo's `architecture.md` / `plan.md` for detail.
- `set -e` is on in the main scripts — a single failing command aborts the whole run.
  Be deliberate about ordering and idempotency when editing.
- **Backup retention is a standard convention.** *Every* backup cron job must follow the
  same rule: keep all backups for the current + previous month, and for any older month
  keep only that month's most recent backup (delete the rest). Name archives
  `<name>-MM-DD-YY.<ext>` and prune at the end of the run. `backup-minikube-mnt.sh` is the
  canonical implementation; see `architecture.md` §7 ("Backup retention convention") for
  the reusable snippet to copy into any new backup script.
  - **Off-site mirror (WD Cloud, NFS):** `backup-minikube-mnt.sh` also copies each archive to
    the WD Cloud NAS (`192.168.50.169`, mounted `/mnt/wdcloud`) and applies the **same** month
    rule to that share — with **no age floor** (our own disk, so deletes are free). The 90-day
    floor only ever mattered for GCS Coldline's minimum-storage duration and is gone; if a
    future off-site target is cloud storage with the same constraint, restore that floor.
    Details: `architecture.md` §7 ("Off-site copy — WD Cloud").
  - **Separate nightly WD NAS job (not cluster-related):** this host also runs the
    8TB→16TB WD My Cloud rsync backup nightly at 02:00 via `/etc/cron.d/wd-backup`
    (script + README in `/home/cloud/wd-backup/`; moved from the dev box 2026-07-12
    because prod is always on). It is an **additive mirror** — no dated archives — so
    the retention convention above does not apply. Its two NAS (`.68` → `.251`) are
    **not** the DR NAS (`.169`). Its toolkit — including the non-git `.smb-cred-*`
    files — is now captured in the weekly DR archive and re-armed on a bare-metal
    rebuild by `restore-scratch.sh` phase 8 (`install-on-prod.sh`, with a direct
    `install-cron` fallback if the NAS is momentarily dark). See `architecture.md`
    §7 ("Tenant job — WD My Cloud").

## Working norms

- **Confirm before running anything that mutates the live cluster** (`minikube`,
  `kubectl apply`, `docker push`, Jenkins build triggers, `vault operator`). These
  scripts act on real running infrastructure and public websites.
- These scripts are **not idempotent end-to-end.** `vault operator init`, `minikube
  start`, and the fixed `sleep` waits will behave differently on a warm vs cold
  machine. Prefer `restart-minikube.sh` for an already-running host.
- Prefer **`kubectl wait` / `kubectl rollout status`** over fixed `sleep` when adding
  new steps.
- **Never commit secrets.** This repo still contains live tokens/passwords inline
  (Jenkins API token, Vault userpass password, Splunk HEC token) — see `plan.md` P0 #1 to
  move + rotate them. (The vault repo already relocated `cluster-keys.json` to
  `~/.vault/`, outside any repo.) Do not add more; move such lines to env/Vault.
- This is a personal/home setup with no CI on the repo itself. Keep changes small,
  readable, and match the existing bash style (heavy inline `#` comments, alternative
  commands left commented for reference).

## Quick orientation commands

```bash
minikube status                 # is the cluster up?
kubectl get ns                  # monitoring, vault, jenkins, qcguy, yolo, ...
kubectl get po -A               # all workloads
kubectl top po -A               # resource usage (served by metrics-server addon)
docker ps                       # nginx-proxy-manager + minikube container
docker network inspect 5million # fixed-IP layout
```
