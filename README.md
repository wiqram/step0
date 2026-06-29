# STEP0 — Private-Cloud Bootstrap

Bootstrap layer for a **single-node, GPU-accelerated private cloud** running on one Ubuntu
workstation (`private-cloud`). This repo is a collection of bash scripts + manifests — not
an application. It brings the whole stack up from a clean machine and keeps it alive.

> **Cluster unhealthy after a reboot/crash?** → read **[`RESTART-RECOVERY.md`](./RESTART-RECOVERY.md)** first.
> **Building a brand-new app on the cluster?** → read **[architecture.md §10](./architecture.md#10-deploying-a-new-app-onto-the-cluster-dev--prod-scaffolding)** (new-app scaffolding).

---

## What this is, in one diagram

```
HOST: private-cloud  (i9-12900K · 48GB · RTX 3080 Ti · Ubuntu 6.8)
  Docker  ── network "5million" (172.16.0.0/16, gw .238.1)
    ├─ nginx-proxy-manager @ 172.16.238.10   (TLS / Let's Encrypt; domain → NodePort)
    └─ minikube node       @ 172.16.238.2    (driver=docker, --gpus all)
         mount /mnt/minikube-backups/minikube-mnt → /mnt ;  insecure-registry :5000
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
| Shared/persistent mount | `/mnt/minikube-backups/minikube-mnt` (on `/dev/sdb1`) → `/mnt` in-cluster |
| Durable registry blobs | `container-registry-images/` (separate `/dev/sdb2` mount) |
| Private registry | `container-registry.traderyolo.com` → `172.16.238.2:5000` |
| Vault keys (only copy) | `~/.vault/cluster-keys.json` (0600, outside any repo) |
| Weekly DR backup | `root` cron, **Mon 05:00** → `private-cloud-<date>.tgz` in `/mnt/minikube-backups`, log `/var/log/minikube-backup.log`; then off-site to **GCS Coldline** `gs://private_cloud_backup` |
| One-app conventions | one namespace · one NodePort · `kv/<app>/*` + policy + role + `jenkins-<app>` AppRole · one Jenkins job · one NPM host |

## Documentation map

| Doc | When to read it |
|---|---|
| **[architecture.md](./architecture.md)** | The full system design — host, network, bootstrap flow, platform services, apps, persistence/backups, **and §10 "deploy a new app"**. The single source of truth. |
| **[RESTART-RECOVERY.md](./RESTART-RECOVERY.md)** | Cluster down/unhealthy after reboot — warm-vs-cold decision, what auto-recovers, symptom→fix triage. **Read first in an incident.** |
| **[plan.md](./plan.md)** | The improvement backlog (P0/P1…), including known fragilities and tech debt. |
| **[CLAUDE.md](./CLAUDE.md)** | Conventions/guardrails for Claude Code working in this repo. |
| **[VAULT-SECRETS.md](./VAULT-SECRETS.md)** | Vault secret handling notes. |
| `HANDOFF-*.md` | Point-in-time incident handoffs. |

## Key scripts

| Script | Role |
|---|---|
| `start-scratch.sh` | **Master cold bootstrap** (order matters: network → minikube → addons → monitoring → vault → jenkins → apps → splunk). |
| `restart-minikube.sh` | Warm restart (reuse cluster, idempotent vault, most apps commented out). |
| `cluster-autostart.sh` / `vault-auto-unseal.sh` | Host crons that auto-heal the cluster + keep Vault unsealed after a reboot. |
| `backup-minikube-mnt.sh` | **Weekly `root` cron** DR backup (see [architecture.md §7](./architecture.md#7-persistence--backups)). |
| `minikube-delete-and-upgrade.sh`, `reduce-*.sh`, `delete-docker-reg-images.sh`, `remove-old-snaps.sh` | Rebuild / disk-space maintenance. |

## Quick orientation

```bash
minikube status                 # is the cluster up?
kubectl get ns                  # monitoring, vault, jenkins, qcguy, yolo, ...
kubectl get po -A               # all workloads
docker ps                       # nginx-proxy-manager + minikube container
docker network inspect 5million # fixed-IP layout
sudo crontab -l -u root         # the weekly backup + (host) cron jobs
```

## Common operations

- **Cold rebuild from scratch:** `bash start-scratch.sh` (mutates live infra — be sure).
- **Warm restart after reboot:** usually automatic; otherwise see RESTART-RECOVERY.md.
- **Run a backup now:** `sudo bash backup-minikube-mnt.sh` (must be root; flock-guarded).
- **Onboard a new app:** follow the checklist in [architecture.md §10](./architecture.md#10-deploying-a-new-app-onto-the-cluster-dev--prod-scaffolding); copy `qcguy-ghost/` (simple) or `ollama` (GPU) as templates.

> ⚠️ These scripts act on **real running infrastructure and public websites**. Confirm
> before anything that mutates the live cluster (`minikube`, `kubectl apply`, `docker push`,
> Jenkins triggers, `vault operator`). **Never commit secrets** — config → `*.env`, secrets
> → SOPS-encrypted `*.secret.sops.env`, everything else read from Vault at runtime.
