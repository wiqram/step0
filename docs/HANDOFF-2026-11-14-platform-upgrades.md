# HANDOFF 2026-11-14 — platform upgrade pass (STEP0 session → next agent)

Written at the end of a two-day STEP0 session (2026-11-13 → 14) so the next agent can take
over cold. **The platform is healthy and nothing is mid-flight**: every change below is
applied, verified, committed and pushed; no background job, paused cron line or held
deploy is outstanding. Last `verify-recovery.sh`: **60 PASS / 3 WARN / 0 FAIL** (WARNs =
dev box off, one stale yolo `pg-restore-verify` Error pod).

## 1. State of the box

| Layer | Now | Notes |
|---|---|---|
| Ubuntu 26.04, kernel 7.0.0-43 | current | root/sudo password was given in chat — **operator should rotate it** |
| Docker 29.9.3 (host) / node runtime 29.7.2 | **held** (`apt-mark hold`) | `docker-runtime-upgrade` timer disabled permanently; containerd/buildx/compose updates intentionally not applied |
| minikube 1.39.0, **Kubernetes v1.37.0** | pinned in `start-scratch.sh` (`K8S_VERSION`, `--container-runtime=docker`) | host kubectl 1.37.2 (apt `v1.37` channel) |
| kube-prometheus 0.19 | Prometheus 3.14 (durable TSDB 20GB/30d), Alertmanager 0.34.1, Grafana 13.2.2 | |
| Vault **2.2.2** (file storage), vault-k8s **1.7.7**, chart 0.34.0 | pins in vault repo `values.yaml` | `override-values.yml` (tags `latest`) is UNUSED — candidate for deletion |
| Jenkins **2.580.2 LTS**, strategy Recreate | jenkins repo `compiled.yaml` | DinD sidecar `docker:29.9.3` lives in `JENKINS_HOME/config.xml`, not git. 61/121 plugins have updates (not applied) |
| Registry **3.1.2** (digest-pinned) | STEP0 `k8s/registry/20-registry.yaml` | |
| nginx-proxy-manager **2.17.0** | nginx repo `docker-compose.yml` | all 22 certs are webroot (certbot DNS-plugin changes irrelevant) |
| ollama-router HAProxy **3.4** | ollama repo (branch `Claude-agent-update`) | |
| Self-hosted **ntfy** v2.37.2 | `ntfy-server.sh`, `ntfy/` | all alerts; ntfy.sh is the fallback only |
| qcguy: **MySQL 8.4.13**, **Ghost 6.77.0** | qcguy-ghost repo `compiled.yaml` | see §3 |

## 2. Things that bit — read before you repeat them

1. **A Kubernetes version change is a COLD REBUILD.** `minikube start --kubernetes-version=<newer>`
   on the live cluster (13 Nov 21:05Z) printed "Unable to restart control-plane node(s), will
   reset cluster" and wiped etcd. hostPath data survived; `start-scratch.sh` rebuilt everything
   in ~25 min. Next time: fresh logical dumps → pause cloud cron (stdin install) → `start-scratch.sh`.
   The `inspect gateway ... no entry for key "Gateway"` error is harmless (warm starts log it too).
2. **Coordinate every blip with the yolo session `master-prod`** (another Claude session on this
   box; `SendMessage` to it). Protocol that worked: ask it to hold pushes → do the change →
   send "<THING> DONE". It owns everything in `IG-Trading-Microservices`; STEP0 owns host cron
   (`cron/cloud-crontab` is the source of truth — hand-added lines are wiped by `install-cron.sh`).
3. **Jenkins quiet-down pauses running Pipeline builds** ("Pausing (Preparing for shutdown)"); they
   never finish on their own. Restart resolves them (resume or ABORTED).
4. **Ghost upgrades run DB migrations at boot and a failed one leaves partial schema** despite
   "Rollback was successful". Rehearse on an isolated copy (`docker network create --internal`,
   dump + content copy, no egress so no newsletter can send) before any Ghost bump.
5. **MySQL 8.4 removed** `--default-authentication-plugin`, `default_collation_for_utf8mb4` and has no
   `character_set_collations` (that is 9.x). Accounts use `mysql_native_password` → `--mysql-native-password=ON`.

## 3. qcguy upgrade record (2026-11-14 09:05–09:07Z, ~90s down)

MySQL 8.0.46 → 8.4.13 in place, all 89 ghost tables converted `utf8mb4_general_ci` →
`utf8mb4_0900_ai_ci` (session `sql_mode=''` to keep legacy zero-dates), then Ghost 6.47 → 6.77.
Proof: per-article MD5 fingerprint of all 40 posts identical before/after, every content table
count unchanged, 28/28 published articles 200 on www.qcguy.com, 0 newsletters sent (3 stuck
2023–2026 sends flipped to failed). Ghost keeps `RollingUpdate` on purpose (no 502s on routine
deploys) — for a Ghost *version* bump, scale it to 0 first. Runbook note in qcguy-ghost `RESTORE.md`.

## 4. Open items, in priority order

1. **Ollama 0.30.8 → 0.40.16** (digest pin in `~/IdeaProjects/ollama/ollama-deployment.yaml`, Recreate,
   GPU). Do it when the **dev box is booted into Ubuntu** (`curl 10.10.10.2:11434/api/version`) — the
   router prefers dev and fails over to it, so the swap is invisible. Smoke-test each model
   (quantos, qwen2.5:14b/7b, predictonomy, dyingpaleblue, nomic-embed-text) via `ollama-router`.
   Warn master-prod first. If the dev box stays off, ask the operator about a 1–2 min AI outage.
2. **Jenkins plugin updates** (61 pending) — quiet-down window, back up `JENKINS_HOME` first.
3. **dcgm-exporter** 4.1.1 (kube-prometheus `manifests/dcgmExporter.yaml`) — check nvcr for latest.
4. **yolo-owned (master-prod has them):** Loki 3.0 → 3.7, Promtail (EOL) → Alloy with
   `legacy_positions_file`; its build #2469 failed on its own gates (absentclose Go test,
   netpol-store-client-check, BACKLOG size) — not platform.
5. **Deferred majors:** Postgres 16 → 18 (4 apps), Mongo 8.2 → 9, Redis 7 → 8 — each a dump/restore.
6. prop-investech fails its own `npm audit` gate (app-side).
7. **Cleanup after ~2026-11-28** (rollback copies on `/mnt/minikube-backups`, 609G free):
   `jenkins-home-pre-lts-20261114-0833.tgz`, `vault-data-pre-2.2.2-20261114-0839.tgz`,
   `npm-pre-2.17.0-20261114-0850/`, `qcguy-pre-upgrade-20261114-0905/`, `grafana-data-pre-0.19-20261113-1419.tgz`.

## 5. Health check to run first

```bash
cd ~/Ideaprojects/STEP0
./verify-recovery.sh | tail -5            # expect 0 FAIL
./install-cron.sh --status                # expect IN SYNC
./yolo-uptime-probe.sh --status           # ui/api 0
./alerting-pipeline-watch.sh --status
kubectl get po -A | grep -vE 'Running|Completed'
```
