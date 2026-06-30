# Design: `restore-scratch.sh` — bare-metal disaster recovery from GCS Coldline

**Date:** 2026-06-30
**Status:** Approved (design), pending implementation plan
**Repo:** STEP0 (`/home/cloud/Ideaprojects/STEP0`)

## 1. Purpose

The prod host (`private-cloud`) has crashed unrecoverably. Starting from a **brand-new,
bare Ubuntu machine**, bring the entire private cloud back to life from the latest
off-site backup so that all base infrastructure is wired and every web project
(yolo, predictonomy, qcguy, ollama, dyingpaleblue, bestrentaladmin, …) can be
deployed and served behind its nginx reverse-proxy host exactly as today.

`restore-scratch.sh` is the **cold disaster-recovery path**. It is the inverse of
`backup-minikube-mnt.sh` (which pushes the weekly archive off-site) feeding into a
controlled re-run of `start-scratch.sh` (the existing cold-bootstrap).

## 2. Scope decisions (confirmed with the operator)

| Decision | Choice |
|---|---|
| Host-level setup | **Install everything** — docker, minikube, kubectl, helm, jq, NVIDIA driver + container-toolkit, gcloud SDK |
| Storage layout of new box | **Single disk** — `/mnt/minikube-backups` and `/mnt/kachra` are plain directories, not separate disks |
| GCS auth | **Interactive `gcloud auth login`** as the operator (no service-account key shipped to the box) |
| App deploy depth | **Stop after infra**, clone all app repos, then PAUSE for DNS before triggering Jenkins app builds |
| Architecture | **Approach C** — reuse `start-scratch.sh` for cluster bring-up via a `SKIP_APP_BUILDS` guard + extracted `trigger-app-builds.sh` |

## 3. Background — what the backup contains (and does not)

`backup-minikube-mnt.sh` tars five trees into `private-cloud-MM-DD-YY.tgz`, pushed to
`gs://private_cloud_backup` (project `igtrader-296013`, Coldline, multi-region `asia`):

| Source tree | Holds |
|---|---|
| `/mnt/minikube-backups/minikube-mnt` | Vault storage (PVC data), per-app secrets (`*-env-variables.sh`, SOPS age key `keys-sops-IMPORTANT.txt`), DB snapshots (predictonomy postgres `pgdata`, yolo/helpmepdf mongo dumps), app data (qcguy-ghost, ollama, jenkins, splunk), and the nested `container-registry-images/` |
| `/home/cloud/Ideaprojects/nginx` | NPM tree — its MariaDB (`data/mysql/` = **all 23 proxy hosts**), generated confs, and `letsencrypt/` (TLS certs) |
| `/home/cloud/Ideaprojects/STEP0` | This bootstrap repo |
| `/home/cloud/Ideaprojects/qcguy-ghost` | Ghost CMS content |
| `/home/cloud/.vault` | `cluster-keys.json` (**only copy** of Vault unseal key + root token) + `jenkins-approle/` |

**Excluded from the tar:** `*/ollama/models` (~38 GB — re-pull post-restore).

**NOT in the backup at all — restore must source elsewhere:**
- Host binaries (docker/minikube/kubectl/helm/jq), NVIDIA stack, the gcloud SDK itself.
- The GCS credential (we use interactive `gcloud auth login`, so no key file needed).
- **App source repos** — only STEP0/nginx/qcguy-ghost are tarred; `vault`, `jenkins`,
  `kube-prometheus`, and every app repo must be **git-cloned** from `github.com/wiqram/*`.
- **Registry image blobs** physically live on the second disk (`/mnt/kachra`); on a
  single-disk restore they are gone → images are rebuilt + re-pushed by Jenkins.

### What `start-scratch.sh` assumes already exists (a fresh box lacks all of it)
Binaries (docker, minikube, kubectl, helm, jq); NVIDIA drivers + container-toolkit;
the `/mnt/minikube-backups` and `/mnt/kachra` directories; both case-variant trees
`~/Ideaprojects` (infra) and `~/IdeaProjects` (apps); secrets `~/.vault/cluster-keys.json`,
`~/.vault/jenkins-approle/`, `~/.config/sops/age/keys.txt`; the `5million` docker network
(it creates this itself); and external DNS/NPM so `*.traderyolo.com` resolves.

## 4. Architecture (Approach C)

### 4.1 Refactor to `start-scratch.sh` (the only change to the proven script)
- Extract the six Jenkins build-trigger `curl`s (qcguy, predictonomy, bestrentaladmin,
  dyingpaleblue, ollama, trading-microservices — including the preceding `sleep 1m`)
  into a new **`trigger-app-builds.sh`**.
- In `start-scratch.sh`, replace that block with:
  ```bash
  if [ -z "${SKIP_APP_BUILDS:-}" ]; then
    "$(dirname "$SCRIPT_PATH")/trigger-app-builds.sh"
  else
    echo "SKIP_APP_BUILDS set — skipping Jenkins app-build triggers (run ./trigger-app-builds.sh after DNS is confirmed)."
  fi
  ```
- **Behaviour preserved:** with the variable unset, `start-scratch.sh` runs exactly as
  today. `trigger-app-builds.sh` is independently runnable (same inline Jenkins creds /
  job tokens it has now).

### 4.2 `restore-scratch.sh` structure
- Runs as user `cloud` with sudo available.
- **Not** blanket `set -e`. A ~100 GB DR run must not die silently on a transient
  hiccup. Each phase validates its own critical steps and aborts loudly with context.
- **Resumable:** a phase marker (`/mnt/minikube-backups/.restore-phase`) records the
  last completed phase; re-running skips completed phases (notably the large pull).
- Phases are individually **idempotent** (mkdir -p, `docker network inspect` guards,
  `helm upgrade --install`, etc.).

## 5. Phase-by-phase flow

| Phase | Action | Key commands / notes |
|---|---|---|
| **0 Preflight** | Verify user=`cloud`, `$HOME`, sudo, internet; print the §6 prerequisites; require explicit confirmation to proceed | abort if run as root or repo not freshly cloned |
| **1 Host tooling** | Install docker (+ `usermod -aG docker cloud`), kubectl, minikube, helm, jq, git, curl; NVIDIA driver + `nvidia-container-toolkit`; gcloud SDK → `~/google-cloud-sdk` | Ubuntu-version-aware official installers; **warn that GPU may require a reboot** before `--gpus all` works |
| **2 Pull backup** | `gcloud auth login` (interactive) → `gcloud config set project igtrader-296013` → list `gs://private_cloud_backup/private-cloud-*.tgz`, pick newest by parsing `MM-DD-YY`→`YYYYMMDD` → `gcloud storage cp` to `/mnt/minikube-backups/` | not lexical sort; replicate the backup script's date parse |
| **3 Storage layout** | `mkdir -p` the former mount points: `/mnt/minikube-backups{,/minikube-mnt}`, `/mnt/kachra/container-registry-images`, `/mnt/predictonomy-postgres`, `/mnt/predictonomy-backups` | single-disk → directories |
| **4 Extract** | Untar in place. Restore `~/.vault` **first and verify** `cluster-keys.json` non-empty. Restore `minikube-mnt`, `qcguy-ghost`, `nginx` (incl. MariaDB + `letsencrypt`). For STEP0: keep the git-cloned code, overlay only backed-up runtime files (`.env` with `NTFY_URL`, `logs/`). **Place the SOPS age key**: `minikube-mnt/keys-sops-IMPORTANT.txt` → `~/.config/sops/age/keys.txt` (0600) — `start-scratch.sh`'s `setup-jenkins-credentials.sh` and per-app `vaultSync` need it to decrypt secrets | extract to staging, then place selectively to avoid clobbering fresh STEP0 code |
| **5 Clone repos** | Clone `github.com/wiqram/*` into case-correct trees and check out the **recorded branch** (manifest below). nginx repo supplies compose; backup supplies its data | needs operator GitHub auth |
| **6 Cluster bring-up** | `SKIP_APP_BUILDS=1 ./start-scratch.sh` → 5million net, cold minikube (single-disk mounts), durable registry, metrics-server + nvidia plugin, kube-prometheus, `start-vault.sh` (restored storage + keys → **unseals, no re-init**), Jenkins, vault→Jenkins cred sync; stops before app builds | reuses proven script |
| **7 nginx** | `cd ~/Ideaprojects/nginx && docker compose up -d` → all 23 proxy hosts + certs restored | 5million network exists from phase 6 |
| **8 Re-arm automation** | `docker update --restart=unless-stopped minikube`; reinstall **cloud crontab** verbatim (preserve `CRON_TZ` ordering); reinstall **single root backup cron** line; launch `vault-auto-unseal.sh` now via `setsid` | crontab is host state, in no repo |
| **9 Pause + handoff** | Print verification commands, **DNS reminder** (point app domains at new host IP), and the next step: `./trigger-app-builds.sh` | deliberate stop |

### 5.1 Repo → branch manifest (captured 2026-06-30)
Infra (→ lowercase `~/Ideaprojects`): `vault`(main), `jenkins`(master),
`kube-prometheus`(main), `nginx`(master), `qcguy-ghost`(main), `STEP0`(master).
Apps (→ capital `~/IdeaProjects`): `bestrentaladmin`(main),
`dyingpaleblue`(**fix-migrate-postgres-readiness**), `ollama`(main),
`Predictonomy`(master), `IG-Trading-Microservices`(**Claude-agent-update**),
`qcx`(main), `radcliffe`(main).
> The two bold feature branches are what prod runs today; the manifest must be
> updatable as those change. Jenkins jobs own their own deploy branches independently.

### 5.2 Cron to reinstall
**cloud crontab** (verbatim, ordering matters for `CRON_TZ`): vault-auto-unseal
(`@reboot` + `*/5`), cluster-autostart (`@reboot sleep 30` + `*/10`),
reduce-node-docker-cache (`30 4 * * *`, `CRON_TZ=Europe/London`), plus the app-owned
predictonomy/yolo agent lines (only if those repos are restored).
**root crontab** (single line): `0 5 * * 1 /bin/bash /home/cloud/Ideaprojects/STEP0/backup-minikube-mnt.sh >> /var/log/minikube-backup.log 2>&1`.

## 6. Operator prerequisites (checked in Phase 0; not derivable from backup)
1. **GitHub auth** for cloning private `wiqram/*` repos (SSH key or token). STEP0 must
   be cloned by hand first to obtain this script — inherent chicken-and-egg.
2. **Google identity** with read on `gs://private_cloud_backup` for the interactive login.
3. **DNS control** to repoint app domains / `*.traderyolo.com` at the new host's public
   IP — the Phase-9 pause exists precisely so app-build webhooks land correctly.

## 7. Known limitations (surfaced, not hidden)
- **Registry blobs gone** (single disk) → registry starts empty; first
  `trigger-app-builds.sh` rebuilds + re-pushes each image. Transient `ImagePullBackOff`
  until then is expected and normal.
- **Ollama models** excluded (~38 GB) → re-`ollama pull` post-restore (identity key restored).
- **~100 GB pull** from Coldline → real time + egress cost; phase marker makes it resumable.
- **Vault** boots sealed, auto-unseals from restored keys; existing secrets preserved.
- **Jenkins jobs/pipelines + API-token** restore with `JENKINS_HOME`. `JENKINS_HOME` is the
  hostPath PV `/mnt/jenkins` (node) = `minikube-mnt/jenkins` (host), captured by the backup and
  laid back down in phase 4; `start-scratch.sh`'s `kubectl apply -f jenkins/compiled.yaml` then
  boots Jenkins on top of it, so all job definitions, the `private-cloud` user, `credentials.xml`,
  and the **hashed API token** return. Webhook auth works because the `.env` plaintext
  `JENKINS_CRED` and the `JENKINS_HOME` token-hash are captured in the **same** backup → consistent.
  **Caveat:** a backup taken *before* `JENKINS_CRED` was added to `.env` (or a token rotated *after*
  that backup) leaves the two out of sync → webhooks 401. Phase 9 pre-flights the credential against
  the restored Jenkins and prints a fix (set a valid `JENKINS_CRED` / regenerate the token) before
  the operator runs `trigger-app-builds.sh`.
- **Per-app SOPS age keys** restore with Vault storage (`kv/age-keys/<app>` is on the restored
  `minikube-mnt` Vault PVC). On a *fresh* Vault, `start-vault.sh` re-seeds them from the offline
  mirror `~/.vault/age-keys/` (restored with `~/.vault` in phase 4a) via `seed-age-keys.sh`. Phase 3
  pre-creates that dir. The **master** age key (`~/.config/sops/age/keys.txt`, restored from
  `keys-sops-IMPORTANT.txt`) is the recovery anchor that can decrypt every app regardless.
- **GPU** may need a reboot after driver install before minikube `--gpus all` works.

## 8. Verification end-state (printed by Phase 9)
```bash
minikube status                                   # Host/Kubelet/APIServer Running
kubectl -n vault exec vault-0 -- vault status     # Sealed = false
kubectl get po -A                                 # platform pods Running
docker compose ls                                 # nginx-proxy-manager up
kubectl get apiservice v1beta1.metrics.k8s.io     # owner kube-system/metrics-server
curl -sI https://<app-domain>                     # 200 once DNS + app deploy complete
```

## 9. Out of scope
- Multi-disk / RAID reconstruction (single-disk chosen).
- Re-securing/rotating the inline secrets still in the repo (tracked separately in `plan.md` P0).
- Splunk (already not deployed by `start-scratch.sh`).
- Automatic DNS repointing (operator-controlled, external).

## 10. Deliverables
1. `trigger-app-builds.sh` (extracted from `start-scratch.sh`).
2. `start-scratch.sh` edit — `SKIP_APP_BUILDS` guard around the extracted call.
3. `restore-scratch.sh` (phases 0–9, resumable, non-`set -e`).
4. `RESTART-RECOVERY.md` / `architecture.md` cross-references to the cold DR path.
5. This design doc.
