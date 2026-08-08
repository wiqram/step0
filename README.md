# STEP0 — Private-Cloud Bootstrap

Bootstrap layer for a **single-node, GPU-accelerated private cloud** running on one Ubuntu
workstation (`private-cloud`). This repo is a collection of bash scripts + manifests — not
an application. It brings the whole stack up from a clean machine and keeps it alive.

> **Cluster unhealthy after a reboot/crash?** → read **[`docs/RESTART-RECOVERY.md`](./docs/RESTART-RECOVERY.md)** first.
> **Building a brand-new app on the cluster?** → read **[docs/architecture.md §10](./docs/architecture.md#10-deploying-a-new-app-onto-the-cluster-dev--prod-scaffolding)** (new-app scaffolding).

---

## What this is, in one diagram

```
HOST: private-cloud  (i9-12900K · 48GB · RTX 3080 Ti · Ubuntu 6.8)
  Docker  ── network "5million" (172.16.0.0/16, gw .238.1)
    ├─ nginx-proxy-manager @ 172.16.238.10   (TLS / Let's Encrypt; domain → NodePort)
    └─ minikube node       @ 172.16.238.2    (driver=docker, --gpus all)
         mount /mnt/minikube-mnt → /mnt ;  insecure-registry :5000
         Kubernetes (single node):
           platform: vault · jenkins · kube-prometheus · registry
           apps:     qcguy(Ghost) · yolo/trading-microservices · predictonomy ·
                     helpmepdf · ollama(quantos/qwen2.5; deepseek-r1:32b def, GPU) · splunk
```

Everything is co-located on one box. "Private cloud" = Docker + one Minikube + Nginx.
Public traffic enters via nginx-proxy-manager, which TLS-terminates each domain and
forwards it to a Kubernetes NodePort on `172.16.238.2`.

## Foundational facts (memorize these)

| Thing | Value |
|---|---|
| Host | `private-cloud` (single node, no multi-node K8s) |
| Docker network | `5million`, bridge `172.16.0.0/16`, gateway `172.16.238.1` |
| Minikube node IP | `172.16.238.2` (Kube API + NodePorts + registry `:5000`) |
| nginx-proxy-manager | `172.16.238.10` (admin UI `:81`) |
| Shared/persistent mount | `/mnt/minikube-mnt` (on `/dev/nvme0n1p6`, label `minikube-data`) → `/mnt` in-cluster |
| Durable registry blobs | `container-registry-images/` (separate `/dev/nvme0n1p7` mount, label `Kachra`) |
| Private registry | `container-registry.traderyolo.com` → `172.16.238.2:5000` |
| Vault keys (only copy) | `~/.vault/cluster-keys.json` (0600, outside any repo) |
| Weekly DR backup | `root` cron, **Mon 05:00** → `private-cloud-<date>.tgz` in `/mnt/minikube-backups`, log `/var/log/minikube-backup.log`; then off-site to the **WD Cloud NAS** `192.168.50.169:/nfs/private-cloud` (NFS, mounted `/mnt/wdcloud`) |
| Nightly WD NAS backup | **Not cluster-related.** `/etc/cron.d/wd-backup`, **02:00 daily** — rsync delta of the **8TB WD My Cloud** (`192.168.50.68`) → **16TB** (`192.168.50.251`), additive (never deletes). Lives at `/home/cloud/wd-backup/` (own README; moved from the dev box 2026-07-12 — prod is always on), logs in `/home/cloud/wd-backup/logs/` |
| One-app conventions | one namespace · one NodePort · `kv/<app>/*` + policy + role + `jenkins-<app>` AppRole · one Jenkins job · one NPM host |

## Documentation map

| Doc | When to read it |
|---|---|
| **[docs/architecture.md](./docs/architecture.md)** | The full system design — host, network, bootstrap flow, platform services, apps, persistence/backups, **and §10 "deploy a new app"**. The single source of truth. |
| **[docs/RESTART-RECOVERY.md](./docs/RESTART-RECOVERY.md)** | Cluster down/unhealthy after reboot — warm-vs-cold decision, what auto-recovers, symptom→fix triage. **Read first in an incident.** |
| **[docs/plan.md](./docs/plan.md)** | The improvement backlog (P0/P1…), including known fragilities and tech debt. |
| **[CLAUDE.md](./CLAUDE.md)** | Conventions/guardrails for Claude Code working in this repo. |
| **[docs/VAULT-SECRETS.md](./docs/VAULT-SECRETS.md)** | Vault secret handling notes. |
| `HANDOFF-*.md` | Point-in-time incident handoffs. |

## Key scripts

| Script | Role |
|---|---|
| `start-scratch.sh` | **Master cold bootstrap** (order matters: network → minikube → addons → monitoring → vault → jenkins → apps → splunk). |
| `restart-minikube.sh` | Warm restart (reuse cluster, idempotent vault, most apps commented out). |
| `cluster-autostart.sh` / `vault-auto-unseal.sh` | Host crons that auto-heal the cluster + keep Vault unsealed after a reboot. |
| `backup-minikube-mnt.sh` | **Weekly `root` cron** DR backup (see [docs/architecture.md §7](./docs/architecture.md#7-persistence--backups)). |
| `k8s/vault-backup/` | Vault durability (2026-07-20): the durable Retain PV/PVC for Vault's file backend + the daily in-cluster snapshot CronJob (`vault/vault-data-backup`, 04:30 UTC → `minikube-mnt/vault-backups/`). Applied by `start-scratch.sh` **before** `start-vault.sh`. |
| `minikube-delete-and-upgrade.sh`, `reduce-*.sh`, `delete-docker-reg-images.sh`, `remove-old-snaps.sh` | Rebuild / disk-space maintenance. |

## Quick orientation

```bash
minikube status                 # is the cluster up?
kubectl get ns                  # monitoring, vault, jenkins, qcguy, yolo, ...
kubectl get po -A               # all workloads
docker ps                       # nginx-proxy-manager + minikube container
docker network inspect 5million # fixed-IP layout
sudo crontab -l -u root         # the weekly backup + (host) cron jobs
cat /etc/cron.d/wd-backup       # nightly 02:00 WD My Cloud 8TB→16TB backup (/home/cloud/wd-backup)
```

## Common operations

- **Cold rebuild from scratch:** `bash start-scratch.sh` (mutates live infra — be sure).
- **Warm restart after reboot:** usually automatic; otherwise see docs/RESTART-RECOVERY.md.
- **Run a backup now:** `sudo bash backup-minikube-mnt.sh` (must be root; flock-guarded).
- **Onboard a new app:** follow the checklist in [docs/architecture.md §10](./docs/architecture.md#10-deploying-a-new-app-onto-the-cluster-dev--prod-scaffolding); copy `qcguy-ghost/` (simple) or `ollama` (GPU) as templates.

> ⚠️ These scripts act on **real running infrastructure and public websites**. Confirm
> before anything that mutates the live cluster (`minikube`, `kubectl apply`, `docker push`,
> Jenkins triggers, `vault operator`). **Never commit secrets** — config → `*.env`, secrets
> → SOPS-encrypted `*.secret.sops.env`, everything else read from Vault at runtime.
