# CLAUDE.md — STEP0 (Private-Cloud Bootstrap)

Guidance for Claude Code when working in this repository. See `architecture.md` for
the full system design and `plan.md` for the improvement backlog.

## What this repo is

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
| `backup-minikube-mnt.sh` | **Weekly disaster-recovery backup** (run by a `root` cron, Mondays ~05:00). Compresses the `minikube-mnt` shared volume — per-app secrets (qcguy, vault/SOPS keys, ollama, predictonomy, yolo, helpmepdf) and DB snapshots — plus nginx + STEP0 + qcguy into a dated `private-cloud-<date>.tgz` in `/mnt/minikube-backups`, then prunes for space (keeps weekly backups for the current + previous month; for older months keeps only the latest backup of each). |
| `reduce-*.sh`, `delete-docker-reg-images.sh`, `remove-old-snaps.sh` | Disk/space maintenance. |
| `Modelfile` | Ollama model def (`deepseek-r1:14b`, equities-research prompt). |
| `5million.xml`, `default.xml` | Legacy libvirt/KVM network defs (kvm2 era). |

## Conventions & facts to respect

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
docker ps                       # nginx-proxy-manager + minikube container
docker network inspect 5million # fixed-IP layout
```
