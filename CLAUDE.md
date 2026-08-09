# CLAUDE.md — STEP0 (Private-Cloud Bootstrap)

Guidance for Claude Code when working in this repository. See `README.md` for the
human-facing front door, `docs/architecture.md` for the full system design (incl. **§10 "deploy
a new app" scaffolding**), and `docs/plan.md` for the improvement backlog.

> **Where the documentation lives (moved 2026-08-08).** Every long-form document is in
> **`docs/`** — `architecture.md`, `plan.md`, `RESTART-RECOVERY.md`, `GM9000-MIGRATION.md`,
> `DEVBOX-9100PRO-MIGRATION.md`, `UBUNTU-UPGRADE.md`, `base-architecture-scaffold.md`,
> `VAULT-SECRETS.md`, the two `HANDOFF-2026-06-16-*.md`, plus the `docs/superpowers/`
> plans+specs. `docs/README.md` indexes them.
> Only **`CLAUDE.md`** and **`README.md`** stay at the repo root, and they must: Claude Code
> loads project instructions from the root `CLAUDE.md`, and GitHub renders the root `README`
> as the landing page. Don't "tidy" either into `docs/` — it silently breaks both.
> If you are following an older note, a commit message or a memory that says
> `STEP0/architecture.md` or `STEP0/plan.md`, the file is not missing — it is under `docs/`.

> **Creating a NEW website/app to deploy here? → read [`docs/base-architecture-scaffold.md`](./docs/base-architecture-scaffold.md) FIRST.**
> It's the copy-paste contract for what files a new project needs (Dockerfile/.production,
> docker-compose dev+prod, Jenkinsfile, namespace.yaml, deployment.yaml with Vault injector
> annotations, `vault/` SOPS secrets) and the exact platform touch-points to register (Vault
> policy/role, Jenkins job + build token, a free NodePort, the NPM proxy host, the cold-boot
> trigger line). Don't re-discover the pattern — start there.

## What this repo is

> **Cluster unhealthy after a reboot/crash? → read [`docs/RESTART-RECOVERY.md`](./docs/RESTART-RECOVERY.md) FIRST**
> (warm-vs-cold decision, what auto-recovers — auto-start + Vault auto-unseal — and a symptom→fix triage).

> **Swapping the boot disk / fresh OS install? → [`docs/GM9000-MIGRATION.md`](./docs/GM9000-MIGRATION.md)**
> (the 2026-08 OS-disk → 4TB NVMe migration runbook: what's actually in the box, partition
> plan, the pre-shutdown quiesced backup, and a phase-by-phase `restore-scratch.sh` walkthrough).
> The **dev box's** equivalent (Samsung 9100 PRO, dual-boot Windows/Ubuntu, ollama + 10GbE
> rewiring) is [`docs/DEVBOX-9100PRO-MIGRATION.md`](./docs/DEVBOX-9100PRO-MIGRATION.md).

STEP0 is the **bootstrap layer** for a single-node, GPU-accelerated private cloud
running on one Ubuntu workstation (`private-cloud`: i9-12900K / 96 GB / RTX 3080 Ti /
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
| `start-scratch.sh` | **Master cold-bootstrap.** Order matters: network → minikube → addons → monitoring → vault → jenkins → qcguy → app builds → splunk. Pushes STARTED / COMPLETED / FAILED to ntfy `yolo-private-cloud-start-scratch`; because `set -e` is on, an ERR trap names the aborting line and the EXIT trap guarantees exactly one closing message. |
| `restart-minikube.sh` | Warm restart; reuses cluster, idempotent vault, most apps commented out. |
| `minikube-delete-and-upgrade.sh` | Nuke + reinstall latest Minikube. |
| `backup-minikube-mnt.sh` | **Weekly disaster-recovery backup** (run by a `root` cron, Mondays ~05:00). Compresses the `minikube-mnt` shared volume — per-app secrets (qcguy, vault/SOPS keys, ollama, predictonomy, yolo, helpmepdf) and DB snapshots; registry blobs + ollama models are **excluded** (Jenkins / `ollama pull` rebuild them; a `registry-catalog.txt` snapshot records repos+tags instead — see §7) — plus nginx + STEP0 + qcguy + the `~/wd-backup` toolkit (script, config **and** its non-git SMB creds, so a restore can re-arm the nightly WD My Cloud job without the dev box; `logs/` excluded) into a dated `private-cloud-<date>.tgz` in `/mnt/minikube-backups`, then prunes for space (keeps weekly backups for the current + previous month; for older months keeps only the latest backup of each). Finally copies the archive **off-site to the WD Cloud 6TB NAS on the LAN** (`192.168.50.169:/nfs/private-cloud`, mounted `/mnt/wdcloud` over NFS — a **`hard`** mount, not `soft`, so a slow fsync can't EIO/truncate the backup; `nofail`+automount keep boot safe) and prunes that share the same way (no age floor — our own disk, deletes are free). Archives land at the share root. No credentials: NFS on the trusted LAN needs none. Pushes a weekly note to ntfy `yolo-private-cloud-backup` (status + tar rc, this archive's size, local and off-site backup counts/totals/free space, and any warning — see `docs/architecture.md` §7a). **One-time manual setup** (WD is an appliance): format the 6TB volume + create the `private-cloud` NFS share in the WD dashboard — its OS3 share-management API resists scripting (rotating tokens; account locks after 5 bad logins). GCS Coldline path retained **commented-out** as a fallback. See `docs/architecture.md` §7 "Off-site copy". |
| `restore-scratch.sh` | **Cold disaster recovery from a bare Ubuntu box** (inverse of `backup-minikube-mnt.sh`). Installs host tooling (incl. `nfs-common`), mounts the WD Cloud NFS share and copies the latest backup from it, restores Vault keys/data + nginx proxy-hosts/certs + secrets + the `~/wd-backup` toolkit, mounts the dedicated backup disk (labels `minikube-backups`/`Kachra`; **non-destructive** — warns with format steps if absent), clones every `wiqram/*` repo, reproduces host config the archive can't carry (`/etc/docker/daemon.json`, the 10GbE `/30` NM profile, the `10gbe-link-watchdog`/`devbox-kube-access` systemd units, the WD Cloud NFS fstab automount, hostname), runs `SKIP_APP_BUILDS=1 start-scratch.sh`, re-arms cron (the weekly DR backup, the canonical cloud crontab **and** the nightly WD My Cloud job via `install-on-prod.sh`), runs `verify-recovery.sh`, then **pauses before app deploys** (manual steps remain: GitHub/`gh` auth before clone, `docker login`, per-box `/etc/hosts`, and wiring any app not in the auto-deploy path — see the handoff) (repoint DNS, then run `trigger-app-builds.sh`). Resumable (`--from-phase N`), inspectable (`--dry-run`). Pushes STARTED / COMPLETE / FAILED (with the `--from-phase` resume hint) to ntfy `yolo-private-cloud-restore-scratch`, plus an EXIT-trap note if a run dies without either — **`--dry-run` sends nothing**. Single-disk restore: registry blobs are rebuilt via Jenkins. See `docs/superpowers/specs/2026-06-30-restore-scratch-design.md`. |
| `trigger-app-builds.sh` | The per-app Jenkins build triggers (qcguy, predictonomy, bestrentaladmin, dyingpaleblue, ollama, trading-microservices), extracted from `start-scratch.sh`. Reads the Jenkins credential from gitignored `.env` (`JENKINS_CRED`). Run after a restore once DNS points at the host; or set `SKIP_APP_BUILDS=1` to make `start-scratch.sh` skip it. Deploys can also be fired from the **dev box** (seeded `~/.jenkins-deploy-urls.env` on `vik@10.10.10.2`) — see `docs/architecture.md` §3 "Triggering Jenkins deploys from the dev box". |
| `install-cron.sh` + `cron/cloud-crontab` + `cron/root-crontab` | **The single source of truth for BOTH host crontabs.** `cron/cloud-crontab` = STEP0 automation (vault-auto-unseal, cluster-autostart, reduce-node-docker-cache, alerting-pipeline-watch, prune-registry) + the per-project autonomous agents. `cron/root-crontab` = the weekly DR backup ONLY — root because `backup-minikube-mnt.sh` must read 0700 per-container datastore dirs and 0600 SMB creds, and because `tar` only records true numeric owners when it runs as root (which is what makes the archive a valid restore source at all). Edit the committed file and run `./install-cron.sh`; never `crontab -e` / `sudo crontab -e`. ⚠️ **Root's line was brought under version control on 2026-08-08** — before that it existed only in the live crontab and as a duplicated string literal inside `restore-scratch.sh` phase 8, so there was nothing to diff the live schedule against and the two copies could drift silently. That is a bad line to reproduce from memory: it schedules the platform's **only off-disk** insurance (the nightly DB snapshots sit on `/mnt/minikube-mnt`, the *same* nvme partition as the live stores, so one disk failure takes both). `--status` diffs both live crontabs against both canonical files; `verify-recovery.sh` FAILs when the root backup job is absent and WARNs on drift. Installing REPLACES the target crontab wholesale — a hand-added line never written back here is destroyed on the next install or DR restore. |
| `loki-nodeport-guard.sh` | **Keeps Loki's NodePort 30310 host-only (SEC-LOKI-NODEPORT).** Loki holds 30 days of the signal→trade pipeline's logs, incl. follower emails, and answers LogQL with **no credential in any configuration** (`auth_enabled` is its multi-tenancy switch, not an auth control). The port can't just be deleted: the host-side agent loop runs *outside* the cluster and pushes OTLP to it, which a ClusterIP can't serve — so reachability is narrowed instead. Two design points that look like style and are not: (1) the rule goes in **`DOCKER-USER`, never `INPUT`** — nothing listens on 30310 on the host (it's on the minikube container at `172.16.238.2`), so that traffic is *forwarded*; an `INPUT` rule matches nothing and looks like protection while providing none. The same asymmetry is what keeps the agent working: host-originated traffic takes `OUTPUT` and never enters `FORWARD`. (As with `enable-devbox-kube-access.sh`, a `curl` from prod proves nothing either way.) (2) a **systemd unit with `PartOf=docker.service`, never `iptables-persistent`** — the latter snapshots Docker's dynamic chains and fights the daemon, and since Docker rebuilds its chains on every daemon restart, a boot-only unit leaves the port open from that restart until the next reboot with nothing to say so. `--install` (called by `restore-scratch.sh` phase 8) / `--remove` / `--status`. Rationale + verification table: `docs/security/network-hardening.md` §3a in the IG-Trading-Microservices repo. |
| `enable-devbox-kube-access.sh` | **Prod-host side** of dev-box → prod-cluster access over 10GbE. Inserts `DOCKER-USER` allow rules **plus a `raw`/PREROUTING ACCEPT** so the dev box (`10.10.10.2`) can reach the kube API `172.16.238.2:8443`. ⚠️ **The raw rule is not optional on Docker ≥28** (here 29.7.2): Docker's "direct routing" protection drops off-host traffic to container IPs in `raw`/PREROUTING at priority −300, *before* `FORWARD`, so `DOCKER-USER` alone is silently bypassed — SYNs show in `tcpdump`, `DOCKER-USER` counters stay 0, `kubectl` just times out. Diagnose with `iptables -t raw -L PREROUTING -n -v`, not by re-checking the route/link. A `curl` from prod proves nothing (local traffic skips the forward path). `--install` adds the `devbox-kube-access.service` systemd unit (re-applies on boot); `--emit-kubeconfig` writes a `prod-minikube` kubeconfig for the dev box. Called best-effort by `start-scratch.sh`/`restart-minikube.sh`. ⚠️ **`--emit-kubeconfig` must be re-run whenever `~/.minikube` is recreated** (fresh OS install, `minikube delete --purge`, wiping the dir — *not* a plain `minikube delete`/cold rebuild, which reuses `~/.minikube/ca.crt`; verified 2026-08-07): the certs are embedded, so a CA change silently invalidates the dev box's copy — it fails as `x509: certificate signed by unknown authority` / `Unauthorized`, which looks like a firewall or link fault and wastes an hour there. Compare CA fingerprints before touching the network. See `docs/architecture.md` §3 "Dev box ↔ prod cluster over 10GbE". |
| `devbox-connect-prod.sh` | **Dev-box side** counterpart (run on `vik@10.10.10.2`): adds the persistent NetworkManager route to the API over 10GbE and merges the emitted kubeconfig as the `prod-minikube` context. `route` / `kubeconfig <file>` / `all <file>` / `test`. `install-unit` installs **`devbox-connect-prod.service`** — a boot-time oneshot running `boot-check` that self-heals the route, verifies the dev **ollama** endpoint (`10.10.10.2:11434`, consumed by prod **yolo**) is serving, and logs a `kubectl get ns` health check to the journal (advisory — never fails the boot). See `docs/architecture.md` §3. |
| `10gbe-link-watchdog.sh` | **Keeps the dev↔prod 10GbE link alive.** Both NICs are `atlantic` (Aquantia/Marvell) 10GBASE-T and the point-to-point link intermittently *wedges* (carrier up, 0 frames, ARP fails both ways) — a link/PHY fault, **not** a kube-access config fault (route/firewall/kubeconfig all survive reboots and work whenever the link is up). Runs as a `systemd` service on **both** ends: pings the peer across the /30 and bounces the local NIC to re-train after a few failed probes. Auto-detects the local 10GbE iface + NM connection, so the same script installs on prod (`enp5s0` — was `enp4s0` until the 2026-08-07 GM9000 NVMe install renumbered PCI; LAN likewise `enp6s0`→`enp7s0`) and dev (`eno1`): `sudo ./10gbe-link-watchdog.sh --install`. See `docs/architecture.md` §3 "Link stability". OOB to dev box while 10GbE is dark: `ssh vik@192.168.50.161`. |
| `devbox-jenkins-deploy.sh` | **Dev-box helper** (installed as `~/bin/jenkins-deploy` on `vik@10.10.10.2`): `jenkins-deploy <app>` fires that app's Jenkins deploy via `jenkins.traderyolo.com` using the seeded `~/.jenkins-deploy-urls.env` credential. App mapping mirrors `jenkins-jobs.manifest` — keep in sync. See `docs/architecture.md` §3. |
| `sync-grafana-admin.sh` | **Pins Grafana's admin login, with Vault as the source of truth.** Grafana's `/var/lib/grafana` **was** an emptyDir, so its SQLite user DB — and the admin password with it — was destroyed on every pod restart and the login reverted to the built-in `admin`/`admin`. That volume is now a durable PV (kube-prometheus `manifests/grafana-dataVolume.yaml`), so the DB persists — but this script is still the source of truth and still worth having: Vault, not a SQLite file on a hostPath, is where the credential belongs. The chain is `Vault kv/grafana/admin` → this script → `monitoring/grafana-admin` Secret → `GF_SECURITY_ADMIN_USER`/`GF_SECURITY_ADMIN_PASSWORD` (`secretKeyRef`, `optional: true` in kube-prometheus's `grafana-deployment.yaml`). ⚠️ **Those env vars are NOT enough, and this doc claimed otherwise until 2026-08-09.** Grafana honours them only when it **creates** the admin user — i.e. against an empty user DB. On every later start it finds user id 1 already present and ignores them completely, so on any cluster that has booted once, changing Vault + the Secret + restarting the pod pins *nothing*: Vault, the Secret and the pod env all read the new password while the **old** one still logs in, with no error anywhere. It only ever appeared to work because the emptyDir destroyed the DB on each restart — making the volume durable fixed the data loss and silently made the env-var mechanism inert. The script therefore **probes a real login and, on mismatch, resets the password directly with `grafana cli admin reset-admin-password`** (needs no existing credential, so it also recovers a Grafana nobody can log into). The password is in **no git repo**: seeded once from `GRAFANA_ADMIN_PASSWORD` in the gitignored `.env` (or randomly generated), after which Vault wins and a stale `.env` never reverts a rotation (`--reseed` forces it). Run by `start-scratch.sh` (after `start-vault.sh`) and `restart-minikube.sh`; idempotent, restarts Grafana only when the Secret actually changed and reruns the reset only when the live login is actually wrong. `--status` reports the whole chain read-only. Grafana deliberately does **not** use the Vault agent injector — that would make the observability stack unable to boot whenever Vault is sealed. See `docs/architecture.md` §5 "Grafana admin login". |
| `restore-lib.sh` | Shared helpers for the DR path, incl. **`restore_repo_manifest`** — the `<dir> <url> <branch>` list `restore-scratch.sh` clones. ⚠️ **A stale branch here is the quietest failure in the whole restore**: the clone succeeds, the app builds and deploys, and it is simply missing whatever prod actually runs — no error at any point. `ollama` was pinned to `main` while prod had been deploying `Claude-agent-update` (found 2026-08-04); a bare-metal restore would have come back with no ollama metrics shim, no router metrics and no ServiceMonitors. `verify-recovery.sh` now diffs this manifest against every cloned repo's actual branch. |
| `verify-recovery.sh` | **Read-only post-restore survey** (mutates nothing). Confirms the facts a fresh box can silently get wrong: fixed cluster IPs (minikube node `172.16.238.2`, NPM `.10`, 5million subnet `172.16.0.0/16`), backup-NAS reachability + exports (WD Cloud DR `.169` NFS, WD My Cloud `.68`/`.251` SMB), the dev↔prod 10GbE `/30` link + watchdog, and host/DNS/service/cron state (hostname, public IP vs `jenkins.traderyolo.com` A-record, Vault unsealed, both backup crons + cloud crontab). Prints PASS/WARN/FAIL + a "detected values" digest of the env-specific facts; exit 1 on any FAIL. Expected values are env-overridable constants at the top. Called best-effort by `restore-scratch.sh` phase 9; run by hand anytime after a reboot/crash. |
| `ntfy-lib.sh` | **The push-notification registry + publisher.** Sourced (never executed) by every job that alerts. Owns the seven channels — `yolo-private-cloud-backup`, `yolo-wd-cloud-backup`, `yolo-private-cloud-start-scratch`, `yolo-private-cloud-restore-scratch`, `yolo-private-cloud-resource-crunch`, plus two published by things that are **not bash** and so never call `ntfy_push`: `yolo-private-cloud-platform` (Alertmanager's webhook, kube-prometheus `manifests/alertmanager-secret.yaml`) and `yolo-grafana` (Grafana's contact point, the yolo repo's `grafana-alerting-yolo` ConfigMap) — plus `ntfy_topic_valid` (rejects unregistered topics), `ntfy_header_safe` (HTTP headers are latin1: an em dash in a Title fails *before* the request is sent) and `ntfy_push` (**always returns 0**, never writes stdout — a notification must never abort a backup or a DR run). `NTFY_DRY_RUN=1` prints instead of sending. Topics are **not secrets** (ntfy.sh topics are world-readable/writable) — so no message body may carry a secret or PII. The private `NTFY_URL` in `.env` is a *separate*, pre-registry topic used by `cluster-autostart.sh`/`vault-auto-unseal.sh`; leave it alone. See `docs/architecture.md` §7a. |
| `ntfy-topic-check.sh` | **Gate for the above** — fails on an unregistered/typo'd topic, a publisher that stopped sourcing the lib, a hardcoded `https://ntfy.sh/...`, or a `ntfy_push` called with a string literal instead of `$NTFY_TOPIC_*`. Run it after touching any notification code. |
| `alerting-pipeline-watch.sh` | **`*/5` cloud cron** → `yolo-private-cloud-resource-crunch`. **Was `resource-crunch-watch.sh` until 2026-08-04**; all the resource thresholds it used to own (node CPU/mem, GPU, temps, disk, kubelet pressure, unschedulable pods) moved into **Alertmanager**, which now notifies ntfy directly — keeping both would mean two notifications per condition. What it watches now is the **alerting pipeline itself**: Prometheus reachable, Alertmanager reachable, the always-firing `Watchdog` alert actually present (proves rule *evaluation* is live, not merely that the process answers), and `alertmanager_notifications_failed_total` not climbing (proves the ntfy webhook works). **This is the only alerting on the box that runs OUTSIDE the cluster** — the hole Alertmanager structurally cannot close, because it cannot page you about being down. If Prometheus is unreachable the two Prometheus-derived probes are **skipped**, not reported: three alerts for one outage is noise. Debounce/cooldown/recovery state machine unchanged (3 consecutive samples = 15 min, then hourly at most, plus one "cleared" note); knobs renamed `RC_*` → `AP_*`; state in `logs/.alerting-pipeline-state` (delete to re-arm). `--status` prints every probe without sending. |
| `reduce-node-docker-cache.sh` | **Daily 04:30 cloud cron — the script that keeps `/var` from filling.** Caps the buildkit cache on the **node** (`--reserved-space 3GB`) *and*, since 2026-08-04, on the **host** (2GB), plus removes **orphaned named build-cache volumes**. That last part closed a real gap: it had been running daily throughout while `/var` hit 90% and the kubelet declared `DiskPressure=True` — tainting the node so Prometheus itself sat `Pending` — because everything it pruned was on the *node* and the 11 GB was on the *host*, in Jenkins build-cache volumes (`yolo-gomod`, `yolo-pipcache`, …) that nothing ever reclaimed. ⚠️ **The volume removal is an ALLOWLIST (`VOL_ALLOW`/`VOL_DENY`), never `docker volume prune` — do not "simplify" it.** On this box the *unused* volume list also contains `nginx_npm_data` (proxy-host + TLS config for every public domain), `letsencrypt` and `radcliffe_radcliffe-db-data`; a blanket prune destroys the public site config and a database. A volume is removed only if docker reports it dangling **and** the name matches a build-tool cache **and** it does not match the deny-list. `--dry-run` prints without removing. |
| other `reduce-*.sh`, `prune-registry.sh`, `remove-old-snaps.sh` | Disk/space maintenance. `reduce-docker-minikube-space.sh` is the **emergency hammer** (`docker system prune -a`, host + node) — never schedule it; it forces a re-pull/rebuild of everything. `prune-registry.sh` prunes old yolo `bNNNN` tags from the in-cluster registry and GCs the blob store — **dry-run by default**, deletes by digest keep-set so a `latest` sharing a digest with an old build tag is never lost; run with Jenkins idle. `delete-docker-reg-images.sh` is a Registry-**v1** relic (walks `ancestry` files) — it does NOT work on the registry:3 store; don't reach for it. |
| `desktop-settings.sh` | **The declarative record of this box's GNOME desktop preferences** — the one piece of state nothing else rebuilds. Per-user dconf (`~/.config/dconf/user`) is a binary blob in no git repo and, unlike everything in `/mnt`, is **not** swept by the weekly DR archive, so a boot-disk swap returns a working cluster and a desktop that has forgotten every setting. Currently: Super+E → Files, Super+R → terminal (Ctrl+Alt+T kept alongside), Super+Shift+S → area screenshot (Print kept); night light 20:00–06:00 @ 2700K; Ubuntu Dock auto-hide. Two traps are documented inline because both present as "the setting is on and nothing happens": night light's schedule is pinned **manual** (the stock `schedule-automatic` needs a geoclue fix, and location services are off here — `night-light-last-coordinates` is still the out-of-range sentinel `(91.0, 181.0)`, so automatic would never fire); and dock auto-hide needs **two** keys, neither named what you'd guess — `dock-fixed=false` (it reads backwards: `true` = pinned open, and while it is `true` the `autohide`/`intellihide` keys are inert, which is the usual wasted hour) **plus** `intellihide=false`, because `intellihide=true` means "hide only when a window would overlap", leaving the dock permanently visible on an empty desktop. Values are declared in full (not deltas) so `--status` can report drift; `--dry-run` prints the `gsettings` calls. Deliberately **not** called by `restore-scratch.sh`: dconf writes need a live D-Bus session bus, which a headless/over-SSH restore does not have — the script refuses in that case rather than silently no-op. It is a post-install manual step, and both migration runbooks say so (GM9000 §7 sign-off, DEVBOX §6.5). Per-user only — no sudo, no `/etc`. |
| `Modelfile` | Ollama model def (`deepseek-r1:14b`, equities-research prompt). |
| `5million.xml`, `default.xml` | Legacy libvirt/KVM network defs (kvm2 era). |

## Conventions & facts to respect

- **Host storage layout (as-built 2026-08-07).** Everything I/O-heavy is on the 4TB
  GM9000 NVMe; the 1TB WD10EZEX (`sda`) is backup staging only.

  | Mount | Device | Label | Holds |
  |---|---|---|---|
  | `/` · `/var` · `/home` · `/var/lib/docker` | nvme p2/p3/p4/p5 | — · `ubuntu-var` · `ubuntu-home` · `docker-data` | OS, logs, home, docker graph |
  | `/mnt/minikube-mnt` | nvme **p6** | `minikube-data` | the shared cluster volume — every app DB, Jenkins, Vault, Grafana |
  | `/mnt/kachra` | nvme **p7** | `Kachra` | registry blobs (bind-mounted into `minikube-mnt/container-registry-images`) |
  | `/mnt/minikube-backups` | **sda1** | `minikube-backups` | weekly `private-cloud-*.tgz` staging + salvage dirs |
  | `/mnt/wdcloud` | NFS 192.168.50.169 | — | off-site archive mirror |

  Two things that bite if forgotten: the shared volume is **`/mnt/minikube-mnt`**, no
  longer nested under `/mnt/minikube-backups/` (the in-node path is still `/mnt`, so no
  manifest changed); and `sda1` is a *staging tier*, needing ~2× the largest archive free
  (~85 G) because `backup-minikube-mnt.sh` writes there before copying to the NAS.
  Details and the 31× fsync measurement: `docs/GM9000-MIGRATION.md` §1.2/§8.

- **Every PVC that holds data MUST declare `storageClassName: manual` and bind an explicit
  hostPath PV.** Omitting it falls through to minikube's default `standard` class, a dynamic
  provisioner writing to `/tmp/hostpath-provisioner` INSIDE the minikube container — a path
  that is **not** under `/mnt/minikube-mnt`, so `minikube delete` destroys it and the weekly
  DR archive never contained it. This is silent: the app redeploys, migrations recreate the
  schema, everything looks healthy, and you find out only when you try to restore. Found
  2026-08-07 on bestrentaladmin's postgres (the only DB on the box with no backup, while all
  four siblings were durable) and open-webui's 890 MB of chat history. Copy the pattern from
  `dyingpaleblue-postgres-pv`: `storageClassName: manual`, `persistentVolumeReclaimPolicy:
  Retain`, `hostPath: /mnt/<name>` (in-node `/mnt` = host `/mnt/minikube-mnt`), and pin the
  PVC with `volumeName`. `verify-recovery.sh` FAILs on any new offender; genuinely
  disposable config volumes go in its `PVC_EPHEMERAL_OK` list.

- **Never copy a running database.** Every restore/migration must scale the workload to 0
  first. MongoDB is the unforgiving case — WiredTiger writes are not atomic across files, so
  a live copy restores faithfully and then fails its own checksums
  (`WiredTiger.wt: potential hardware corruption`); Postgres and MySQL survive only because
  they replay a WAL/binlog. This is why `backup-minikube-mnt.sh`'s raw datastore dirs are
  **not** a valid Mongo restore source and the `db-snapshot` CronJob's logical dumps in
  `minikube-mnt/yolo-db-snapshots/` are. Recovery procedure: `docs/RESTART-RECOVERY.md`.

- **The DB snapshot tree lives INSIDE the mount a restore overwrites — and on the SAME disk as
  the live stores.** `minikube-mnt/yolo-db-snapshots/` (the `db-snapshot` CronJob's logical
  dumps — the only valid Mongo restore source) is on `/mnt/minikube-mnt` = `nvme0n1p6`, the
  same partition as every live datastore, so a disk failure takes the data and its snapshots
  together. The weekly `private-cloud-*.tgz` on the WD NAS is the only copy that survives that,
  which is why the root cron scheduling it is not an ordinary line. The snapshot tree is also
  *in* that archive, so a restore replays it as of backup day: on 2026-08-07 the
  rebuild-and-restore left all five stores at their 08-03 state with the 08-04/05/06 dumps
  gone. `restore-scratch.sh` phase 4 now **side-copies any existing snapshot tree** to
  `/mnt/minikube-backups/pre-restore-db-snapshots-<stamp>` (the other disk) before merging the
  archive over the mount, and never auto-deletes it. Don't rely on `cp -a` merging: it happens
  to preserve newer differently-named dumps today, but it doesn't stop a same-named overwrite
  and it doesn't survive an operator who clears the mount first.

- **Datastore directories are owned by their container's UID, not by `cloud`** —
  vault `100`, loki `10001`, postgres `70`/`999`, mysql/mongo `999`. They cannot be
  normalised to one owner: PostgreSQL refuses to start unless pgdata is `0700`/`0750`,
  which grants access to the owner alone. Restores MUST use `tar --numeric-owner`, or the
  user *names* get resolved against the new box's `/etc/passwd` and the data lands on the
  wrong UID (see `docs/UBUNTU-UPGRADE.md` §0a #8). `verify-recovery.sh` §5 guards both.

- **Vault storage is a pre-created durable PV — never let it go dynamic again.**
  `k8s/vault-backup/vault-data-pv.yaml` (Retain, hostPath `/mnt/vault-data` =
  host `/mnt/minikube-mnt/vault-data`) MUST be applied before
  `start-vault.sh` (start-scratch does this) so the `data-vault-0` PVC binds it.
  The pre-2026-07-20 dynamic `/tmp` PV silently destroyed all runtime-written KV
  (follower broker secrets, admin platform keys) on a minikube rebuild. Daily
  snapshot CronJob `vault/vault-data-backup` → `minikube-mnt/vault-backups/`
  (swept by the weekly DR tar + WD off-site).
  **Proven under the real failure condition (verified 2026-08-04):** the minikube
  container was rebuilt on 2026-07-29 — exactly what wiped Vault on 07-14 — and the
  KV survived intact. Snapshots run unbroken Jul 22 → Aug 4 with no size dip across
  the rebuild (21.4 → 23.2 → 25.3 MB), 14 kept, prune working, and `kv/` still holds
  every app path including the runtime-written `age-keys/`. The rollback PV
  `pvc-cca2a54b-…` is **gone** — it lived in the VM's `/tmp` and went with the old
  cluster's etcd on that rebuild. Nothing left to clean up; don't go looking for it.
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
  API for the adapter and silently re-breaks `top`. Full rationale: `docs/architecture.md` →
  "Resource metrics — metrics-server". Verify with `kubectl get apiservice v1beta1.metrics.k8s.io`
  (owner should be `kube-system/metrics-server`).
- **`custom.metrics.k8s.io` is a DIFFERENT APIService and IS served by prometheus-adapter.**
  Registered by kube-prometheus's `manifests/prometheusAdapter-apiServiceCustomMetrics.yaml`
  (added 2026-08-04) and fed by the `rules:` block in `manifests/prometheusAdapter-configMap.yaml`.
  Adding it does **not** re-open the June `kubectl top` regression — that was
  `metrics.k8s.io`; these are separate singleton objects and both are expected to exist.
  Scope is an explicit prefix allowlist (`^(yolo)_`), not the upstream catch-all, so the
  adapter isn't re-planning every series once a minute on a box that also runs the apps;
  onboarding an app means extending that group in all three `seriesQuery` regexes. The
  built-in `system:controller:horizontal-pod-autoscaler` ClusterRole already grants the HPA
  controller access — do not add a redundant binding (`kubectl auth can-i` misleadingly says
  "no" because it can't resolve these subresources in discovery; a `SubjectAccessReview`
  says `allowed: true`). Full reference: kube-prometheus `manifests/CUSTOM-METRICS.md`.
- **An app namespace must ship its own `prometheus-k8s` Role + RoleBinding, and it MUST grant
  `discovery.k8s.io/endpointslices`.** The Prometheus CR selects ServiceMonitors across all
  namespaces, but kube-prometheus grants that Role only in `default`, `kube-system` and
  `monitoring`. Without it the ServiceMonitor is accepted, shows up in the operator's config,
  and **never produces a target — with no error anywhere**.
  ⚠️ **As of the 2026-08-04 upgrade to kube-prometheus 0.18 / prometheus-operator 0.92,
  service discovery uses `EndpointSlice`, not the deprecated core `Endpoints`.** A Role that
  still lists only `services/endpoints/pods` silently yields ZERO targets — this is exactly
  what happened to `yolo` during the upgrade. The only evidence is in the `prometheus-k8s`
  pod's own log (`failed to list *v1.EndpointSlice: ... forbidden`), not the operator's.
  Verify per namespace with:
  `kubectl auth can-i list endpointslices.discovery.k8s.io --as=system:serviceaccount:monitoring:prometheus-k8s -n <ns>`
  ServiceMonitors, dashboards, alert rules and HPAs belong to the app repos; the adapter,
  APIServices, datasources and Grafana mounts belong to kube-prometheus (see that repo's
  `manifests/YOLO-OWNERSHIP.md`). Never ship a competing copy from an app repo.
- **Secrets are owned by the vault repo, not STEP0.** STEP0 just calls `start-vault.sh`
  in the right order. Apps authenticate to Vault via Kubernetes ServiceAccount auth.
  Seeding is mid-transition: legacy `*-env-variables.sh` on `/mnt` → declarative
  `apps/<app>/*.env` + SOPS-encrypted secrets reconciled by `vault-sync.sh`. `start-vault.sh`
  also provisions per-app Jenkins AppRoles (`jenkins-<app>`) for the sync pipeline. The
  Vault root token + unseal key now live at `~/.vault/cluster-keys.json` (outside any repo).
  See the vault repo's `docs/architecture.md` / `docs/plan.md` for detail.
- `set -e` is on in the main scripts — a single failing command aborts the whole run.
  Be deliberate about ordering and idempotency when editing.
- **A change only survives a rebuild if it is on one of three paths.** Both bootstrap
  scenarios reduce to the same question — *is this file reachable?* — and the answer is one
  of: (a) it lives in `kube-prometheus/manifests/`, which `start-scratch.sh` applies
  wholesale; (b) a STEP0 script that `start-scratch.sh` invokes creates it; or (c) it is in
  an app repo **and that repo's Jenkinsfile explicitly applies it**, on the branch
  `restore-lib.sh` clones. `restore-scratch.sh` calls `start-scratch.sh`, so (a) and (b)
  are inherited by the bare-metal path for free — (c) is the one that silently fails.
  Committing a manifest to an app repo does **not** deploy it: the ollama Jenkinsfile
  applies an explicit file list, so three files added on 2026-08-04 were live on the
  cluster but would have vanished on the next rebuild. When adding a manifest to an app
  repo, add it to that repo's Jenkinsfile **in every deploy branch** (ollama has two: one
  for namespace-exists, one for namespace-absent — the latter is the one a from-scratch
  bootstrap takes).
- **Infrastructure alerting is ALERTMANAGER's job, not Grafana's, and not a bash script's.**
  kube-prometheus ships ~138 alerting rules as `PrometheusRule` CRs. Until 2026-08-04 they
  all fired into a void: Alertmanager's `Default`/`Watchdog`/`Critical`/`null` receivers were
  bare names with no configuration, so six live alerts (two `critical`) had never reached
  anyone. `manifests/alertmanager-secret.yaml` now wires `Default` and `Critical` to ntfy
  (`yolo-private-cloud-platform`). Adding a platform alert = adding a rule to a
  `PrometheusRule` in `manifests/`, **not** a new cron script and **not** a Grafana alert.
  - `manifests/platform-hardware-prometheusRule.yaml` holds the only rules upstream cannot
    provide — CPU package temp, GPU temp/memory. Everything else (node CPU/mem/disk, PVs,
    crashloops, `TargetDown`) is already upstream; a duplicate means two pages per event.
  - **CPU package temp is `node_thermal_zone_temp{type="x86_pkg_temp"}`.** ⚠️ **Changed
    2026-08-09: `node_hwmon_temp_celsius` now DOES exist.** Until then node-exporter ran
    with upstream's `--no-collector.hwmon` and this file warned that any rule using hwmon
    would never fire. The collector is now deliberately enabled in
    kube-prometheus `manifests/nodeExporter-daemonset.yaml`, because hwmon is the **only**
    source of NVMe drive temperature — and the 4TB GM9000 in slot M.2_1 holds every app
    database, Jenkins, Vault and Grafana. It also adds per-core `coretemp`. The drive
    figure is `node_hwmon_temp_celsius{chip="nvme_nvme0"}` selected to the `Composite`
    sensor via `node_hwmon_sensor_label` (`Sensor 1` is the controller, ~9 °C hotter).
    Costs ~26 series on this box — it is scoped by the hardware present, not by workload,
    so it is nothing like the per-mountpoint filesystem explosion below.
  - **`KubeSchedulerDown` / `KubeControllerManagerDown` are routed to `null` on purpose.**
    Both components are healthy; minikube binds them to `127.0.0.1` so they have no Service,
    and the rules are `absent(up{...})`, which therefore fires forever. Deleting the
    ServiceMonitors makes it *worse*. Undo that route only if you make them scrapable.
  - Grafana's own alerting is a **separate, independent** system owned by the yolo app repo
    (`grafana-alerting-yolo` ConfigMap → topic `yolo-grafana`). Do not merge the two; the
    `handleGrafanaManagedAlerts: false` flag on the Alertmanager datasource is what keeps
    them apart.
  - **node-exporter's `--collector.filesystem.mount-points-exclude` is tuned — don't revert
    it to upstream.** Alert rules fire per *series*, and node-exporter emits one per
    *mountpoint*, so a single full disk pages once per bind-mount of it. Untuned, this box
    reported **52 filesystem series for 4 real disks** (`/dev/sda5` alone had 35 — every
    NVIDIA driver file bind-mounted by the container runtime), and one real `/var` alert
    arrived 7 times. Now 52 → 7, one per device. Note `/dev/sda5` is represented by
    `/usr/lib/modules`, so **an alert naming `/usr/lib/modules` means the HOST ROOT is
    filling**; that mount was chosen because it is the only sda5 path with no driver
    version in its name (the `libnvidia-*.so` paths embed `580.173.02` and would stop
    matching on the next driver upgrade, silently resurrecting the duplicates).
- **Every unattended job pushes to ntfy through `ntfy-lib.sh` — never a hand-rolled `curl`.**
  A dead alert channel is indistinguishable from a healthy system, so the registry + gate
  exist to make a half-wired channel a build failure instead of a surprise. Adding an alert?
  Add the topic to `NTFY_TOPICS` in `ntfy-lib.sh`, source the lib in the publisher, add the
  publisher to `PUBLISHERS` in `ntfy-topic-check.sh`, and run that gate. Bodies carry no
  secrets (public topics). `docs/architecture.md` §7a is the source of truth.
- **Backup retention is a standard convention.** *Every* backup cron job must follow the
  same rule: keep all backups for the current + previous month, and for any older month
  keep only that month's most recent backup (delete the rest). Name archives
  `<name>-MM-DD-YY.<ext>` and prune at the end of the run. `backup-minikube-mnt.sh` is the
  canonical implementation; see `docs/architecture.md` §7 ("Backup retention convention") for
  the reusable snippet to copy into any new backup script.
  - **Off-site mirror (WD Cloud, NFS):** `backup-minikube-mnt.sh` also copies each archive to
    the WD Cloud NAS (`192.168.50.169`, mounted `/mnt/wdcloud`) and applies the **same** month
    rule to that share — with **no age floor** (our own disk, so deletes are free). The 90-day
    floor only ever mattered for GCS Coldline's minimum-storage duration and is gone; if a
    future off-site target is cloud storage with the same constraint, restore that floor.
    Details: `docs/architecture.md` §7 ("Off-site copy — WD Cloud").
  - **Separate nightly WD NAS job (not cluster-related):** this host also runs the
    8TB→16TB WD My Cloud rsync backup nightly at 02:00 via `/etc/cron.d/wd-backup`
    (script + README in `/home/cloud/wd-backup/`; moved from the dev box 2026-07-12
    because prod is always on). It is an **additive mirror** — no dated archives — so
    the retention convention above does not apply. Its two NAS (`.68` → `.251`) are
    **not** the DR NAS (`.169`). Its toolkit — including the non-git `.smb-cred-*`
    files — is now captured in the weekly DR archive and re-armed on a bare-metal
    rebuild by `restore-scratch.sh` phase 8 (`install-on-prod.sh`, with a direct
    `install-cron` fallback if the NAS is momentarily dark). See `docs/architecture.md`
    §7 ("Tenant job — WD My Cloud"). It pushes nightly to ntfy `yolo-wd-cloud-backup`
    (bytes copied this run, used/free on the 16TB) via STEP0's `ntfy-lib.sh`, sourced
    defensively — a box without STEP0 cloned still backs up, just silently.

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
  (Jenkins API token, Vault userpass password, Splunk HEC token) — see `docs/plan.md` P0 #1 to
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
