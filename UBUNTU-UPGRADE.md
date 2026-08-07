# UBUNTU-UPGRADE.md — `private-cloud` 24.04 LTS → 26.04 LTS

Runbook for upgrading this host from **Ubuntu 24.04.4 LTS (Noble)** to **Ubuntu 26.04 LTS
(Resolute Raccoon)**. Written 2026-08-06 from a live survey of the box, for an upgrade
planned the week of 2026-08-10.

Companion documents: [`GM9000-MIGRATION.md`](./GM9000-MIGRATION.md) (the disk swap this box
just went through) and [`nginx/CLAUDE.md`](../nginx/CLAUDE.md) (the NPM stack).

> **Do not run `do-release-upgrade` as your first action.** It will produce a system whose
> container stack does not start. Read §0, then do §2 **days before** §4.

---

## 0a. What 26.04 actually broke — found the hard way, 2026-08-07

This box did not take the in-place path: it was **reinstalled** on 26.04 and rebuilt with
`restore-scratch.sh`. That run surfaced eleven distinct bugs, every one of them invisible to
`--dry-run`. All are fixed in the scripts now; this is the record of *why*, so the next
26.04 box does not rediscover them.

| # | 26.04 change | What it did | Fixed by |
|---|---|---|---|
| 1 | cgroup v1 removed | docker will not start with `native.cgroupdriver=cgroupfs` | phase 1 writes `systemd`, warns on a stale daemon.json |
| 2 | — | kubectl pinned `v1.31` while minikube 1.38.1 deploys k8s **1.35.1** — four minors of skew | repo pinned `v1.35` |
| 3 | `ubuntu-drivers-common` 1:0.10.9 | `autoinstall` **deleted**, now `install`. Prints usage, exits 0-ish, `run()` ignored it → phase logged "driver installed" with **no driver** | prefer `install`, then VERIFY with `dpkg` |
| 4 | — | phase 2's `cp` cannot overwrite a root-owned archive (backups run from root's cron) | chown before copy |
| 5 | — | `start-scratch.sh` was committed **100644** — phase 6 could never run on a fresh clone | git mode 100755 |
| 6 | — | helm's repo LIST restores but its index CACHE does not; `helm repo add` is skip-if-present, so installs die "no cached repo found" *after* namespaces/PVs exist | `helm repo update` before bring-up |
| 7 | — | `tar`/`cp` ran as `cloud`; neither restores ownership without root | `sudo tar -xpzf`, `sudo cp -a` |
| 8 | **different system UIDs** | see below — the subtle one | `--numeric-owner` |
| 9 | — | vault helm chart unpinned; a rebuild takes whatever is latest that day | `VAULT_CHART_VERSION=0.33.0` |
| 10 | ships **apache2 enabled** | holds `:80`, so nginx-proxy-manager (all public ingress + LE renewal) cannot bind | `free_web_ports()` in phase 1, re-checked in phase 8 |
| 11 | **`sudo` is now `sudo-rs`** | see below — the dangerous one | phase 0 dies without a tty |

### #8 — tar restores the user NAME, not the UID

`tar` records both, and on extract **as root** it resolves the *name* against the
**destination's** `/etc/passwd`. Across a distro version that silently relocates data:

```
old box (24.04):  vault storage = uid 100, named `systemd-network`
new box (26.04):  `systemd-network` = 998,   uid 100 = `syslog`
result:           vault-data restored to 998; vault runs as 100; permission denied
```

`vault-0` then sat in a readiness loop on `open /vault/data/core/_migration: permission
denied` — *after* minikube was Ready and monitoring deployed, i.e. half-built rather than
cleanly failed. Directories whose uid had **no name at all** (postgres `70`, loki `10001`)
came through perfectly, which made it look like random per-app inconsistency rather than one
bug. Container UIDs are numeric facts; the names are noise that varies per release.
`--numeric-owner` on **both** sides — create *and* extract — is the fix.

> Related: you cannot "normalise" this data to a single owner. PostgreSQL refuses to start
> unless its data directory is `0700`/`0750` (*"data directory has invalid permissions"*),
> and `0700` grants access to the owner alone — so pgdata must be owned by the uid postgres
> runs as. `verify-recovery.sh` §5 therefore asserts "not owned by uid 1000" rather than
> exact UIDs, which legitimately differ per image generation.

### #11 — sudo-rs will not use a cached credential without a tty

26.04 ships `sudo-rs` 0.2.13 as the default `sudo`. Run headless (nohup, CI, an agent),
**every** `sudo` fails with *"A terminal is required to authenticate"* — and because `run()`
did not check exit status and `mark_phase` advanced unconditionally, phase 1 logged success
and marked itself done with docker, kubectl, minikube and helm all absent. The next run then
*skipped* phase 1 as complete. This single behaviour is why several of the other bugs stayed
hidden long enough to surface later as a half-built platform.

Phase 0 now refuses to start in that situation. To run headless deliberately, give the shell
a working non-interactive sudo first:

```bash
printf '#!/bin/sh\necho $PASSWORD\n' > /tmp/askpass && chmod 700 /tmp/askpass
mkdir -p /tmp/sudoshim && printf '#!/bin/sh\nexec /usr/bin/sudo -A "$@"\n' > /tmp/sudoshim/sudo
chmod 755 /tmp/sudoshim/sudo
SUDO_ASKPASS=/tmp/askpass PATH=/tmp/sudoshim:$PATH ./restore-scratch.sh
```

### Smaller things

- **`nfs-common` is not installed by default**, so the `/mnt/wdcloud` fstab automount fails
  (`mount-start-limit-hit`) until phase 1 installs it. Harmless for the script's own
  ordering, but a fresh box looks like the NAS is unreachable.
- **NVIDIA**: `nvidia-driver-580` (`580.173.02-0ubuntu0.26.04.1`) builds cleanly against
  kernel 7.0.0-29 via DKMS and matches what 24.04 ran. Secure Boot is off here, so no MOK
  enrolment. `nouveau` is blacklisted by `/lib/modprobe.d/nvidia-graphics-drivers.conf`,
  which the driver package puts into the initramfs — **a reboot is required**; before it,
  `modprobe nvidia` fails "No such device" because nouveau still owns the card.
- **Docker's `resolute` repo exists day one** — `get.docker.com` works unmodified.
- `systemctl is-enabled httpd` prints **`alias`** and exits **0** on Ubuntu
  (`apache2.service` declares `Alias=httpd.service`), while a genuinely disabled `apache2`
  prints `disabled` and exits **1**. Test the reported STATE, never the exit status.

---

## 0. The blocker: this box runs cgroup v1, and 26.04 has deleted it

Ubuntu 26.04 ships **systemd 259**, and the release notes state that support for cgroup v1
— **both the legacy and hybrid hierarchies** — has been *completely removed*. systemd
dropped it in v256; 24.04 is the last Ubuntu that still has it (systemd 255).

This box depends on cgroup v1 in three places, all verified live on 2026-08-06:

| Where | Current value |
|---|---|
| Kernel cmdline | `systemd.unified_cgroup_hierarchy=0` |
| `/sys/fs/cgroup` | `tmpfs` (= v1; v2 reports `cgroup2fs`) |
| `/etc/docker/daemon.json` | `"exec-opts": ["native.cgroupdriver=cgroupfs"]` |
| `docker info` | `Cgroup Version: 1`, `Cgroup Driver: cgroupfs` |

On 26.04 that kernel parameter becomes a **silent no-op**: the box boots cgroup v2 anyway,
docker is then configured with the wrong cgroup driver, and kubelet/minikube come up in a
combination that has never run here. The failure is not a clean error at upgrade time — it
surfaces later as containers that will not start or a node that misreports resources.

**Therefore the order is fixed: migrate to cgroup v2 on 24.04 first (§2), prove it (§3),
and only then upgrade the OS (§4).** One change at a time, each independently reversible.
This is the same discipline `GM9000-MIGRATION.md` §4 applied when it pinned the rebuild to
24.04 — that pin was correct *then*; §2 below is what retires it.

### One-time advantage: there is no cluster to convert right now

As of 2026-08-06 `minikube status` reports **"Profile 'minikube' not found"** — the cluster
does not exist on this box. That makes the cgroup v2 switch unusually cheap: nothing has to
be migrated, and the cluster gets **built natively on v2** the first time
`start-scratch.sh` runs. Do §2 *before* you rebuild the cluster and you skip the hard part
entirely. If you rebuild the cluster on v1 first, you will have to `minikube delete` and
rebuild it again later anyway.

---

## 1. Prerequisites and rollback assets

**Timing.** Canonical enables direct LTS→LTS upgrades when the first point release ships.
**26.04.1 was scheduled for 2026-08-06.** Before starting, confirm the path is actually
open:

```bash
do-release-upgrade -c
```

- `New release '26.04.1 LTS' available.` → good, proceed.
- `There is no development version of an LTS available.` → the meta file has not flipped
  yet. **Wait.** Do *not* reach for `do-release-upgrade -d`; that pulls the development
  channel and is not what you want on this box.

**Rollback assets (both must exist before you start §4):**

1. **The 840 EVO on `sda`** — still holds the complete pre-migration 24.04 system, reachable
   from the BIOS boot menu as `Boot0000 "Ubuntu (840 EVO rollback)"`. Do not wipe it until
   the upgrade has soaked. Read `GM9000-MIGRATION.md` §9 first — booting it is a deliberate
   act, not a dual-boot toy, because its crons will act on the live `sdb` data.
2. **A same-day quiesced backup** — `sudo bash ~/Ideaprojects/STEP0/backup-minikube-mnt.sh`
   with the cluster stopped, landing on both `/mnt/minikube-backups/` and `/mnt/wdcloud/`.

**Also back up the NPM database** (it is not in the minikube archive path):

```bash
cd ~/Ideaprojects/nginx
docker exec nginx-db-1 sh -c 'mysqldump -uroot -pnpm --single-transaction npm' \
  > backups/npm_db_$(date +%Y%m%d_%H%M%S).sql
```

> Do **not** add `--routines` — `mysql.proc` is corrupt in this MariaDB image and the dump
> exits non-zero (verified 2026-08-06).

---

## 2. Phase A — move to cgroup v2, on 24.04 (do this first, its own day)

### 2.1 Kernel cmdline

Drop `systemd.unified_cgroup_hierarchy=0`. While you are here, drop the dead KVM-era
relics: per `GM9000-MIGRATION.md` §5.1 the `vfio-pci.ids` refer to an RTX 2080 Ti that is
**no longer in the machine**, so they bind nothing. Keep `intel_iommu=on` — GPU-in-container
needs it.

```bash
sudo cp /etc/default/grub /etc/default/grub.bak-cgroupv1
sudo sed -i 's/^GRUB_CMDLINE_LINUX_DEFAULT=.*/GRUB_CMDLINE_LINUX_DEFAULT="intel_iommu=on"/' \
  /etc/default/grub
sudo update-grub
```

### 2.2 Docker cgroup driver

`systemd` is the correct driver on a cgroup v2 host (and what kubeadm expects).

```bash
sudo cp /etc/docker/daemon.json /etc/docker/daemon.json.bak-cgroupv1
sudo sed -i 's/native\.cgroupdriver=cgroupfs/native.cgroupdriver=systemd/' \
  /etc/docker/daemon.json
grep cgroupdriver /etc/docker/daemon.json    # expect: native.cgroupdriver=systemd
```

### 2.3 Fix the automation so it cannot undo this

**`restore-scratch.sh` line ~179 hard-codes `native.cgroupdriver=cgroupfs`.** If it is ever
re-run after this migration it will silently rewrite `daemon.json` back to v1 and restart
docker. Change it to `systemd` and commit:

```bash
cd ~/Ideaprojects/STEP0
sed -i 's/native\.cgroupdriver=cgroupfs/native.cgroupdriver=systemd/' restore-scratch.sh
git commit -am "restore-scratch: docker cgroup driver systemd (cgroup v2)" && git push
```

Also update the cgroup rows in `GM9000-MIGRATION.md` §10.1 and the §4/§5.1 text, which
still assert cgroup v1 as a live fact.

### 2.4 Reboot and verify

```bash
sudo reboot
```

Every one of these must pass before you go further:

```bash
cat /proc/cmdline                  # NO systemd.unified_cgroup_hierarchy=0
stat -fc %T /sys/fs/cgroup         # cgroup2fs   (was: tmpfs)
docker info | grep -i cgroup       # Cgroup Version: 2 ; Cgroup Driver: systemd
systemctl is-system-running        # running (or degraded only for known-unrelated units)
docker ps                          # nginx-proxy-manager healthy, nginx-db-1 up
```

### 2.5 Rebuild the cluster on v2 and soak

```bash
cd ~/Ideaprojects/STEP0 && ./start-scratch.sh      # or ./restore-scratch.sh for a full restore
```

`minikube start` in `start-scratch.sh` passes no explicit cgroup driver flag, which is
correct — minikube/kubeadm detect cgroup v2 and select the systemd driver themselves. Then
walk the `GM9000-MIGRATION.md` §7 sign-off list, in particular `kubectl top po -A`,
`kubectl describe node minikube | grep nvidia.com/gpu`, and `./verify-recovery.sh`.

**Soak for at least 48 hours on cgroup v2 + 24.04 before touching the OS.** If something is
wrong with v2, you want to discover it while `do-release-upgrade` is still not in the
picture.

> Possible bonus: `HANDOFF-2026-06-16` attributes the "cAdvisor missing pod labels" quirk to
> the docker driver on **cgroup v1**. It may simply disappear here. Check whether
> `kubectl top po -A` labels are complete.

---

## 3. Phase B — clean up the apt sources (before the upgrade, not during)

`do-release-upgrade` disables third-party repositories and rewrites the codename in the
Ubuntu ones. Stale entries cause fetch failures that abort its pre-flight. This box has
accumulated a lot of drift — it was installed as **21.10** and upgraded forward, and several
repos never had their codename updated. Surveyed 2026-08-06:

| Source | Current | Action before upgrading |
|---|---|---|
| `docker.list` | **`jammy`** (22.04!) | Retarget to `noble` now, `resolute` in §5.1. Docker 27.3.1 is currently installed from the *jammy* repo on a *noble* box. |
| graphics-drivers PPA | **`jammy`** | Retarget to `noble` or remove — §5.2 reinstalls the driver from the 26.04 archive anyway. |
| CUDA repo | **`ubuntu2004`** (20.04!) | Remove. Nothing needs it; `nvidia-container-toolkit` is the repo that matters. |
| `cdrom:` source | **Ubuntu 21.10 Impish** | Remove — an installer leftover that will fail every fetch. |
| `apt.kubernetes.io` | legacy | Remove; the live k8s repo is `pkgs.k8s.io` (pinned v1.31 by `restore-scratch.sh`). |
| ethereum PPA | jammy-era | Remove if unused. |
| ESM infra | `jammy` | Leave — `ubuntu-advantage-tools` rewrites these itself. |
| helm (baltocdn) | `all` | Fine, distribution-independent. |
| nvidia-container-toolkit | `$(ARCH)` | Fine, distribution-independent. |
| chrome / teamviewer / claude-desktop | `stable` | Fine. |

```bash
ls /etc/apt/sources.list.d/          # inventory first
sudo sed -i 's/ jammy / noble /' /etc/apt/sources.list.d/docker.list
# remove the dead ones (inspect each before deleting)
sudo apt update                      # must complete with ZERO fetch errors
```

Do not proceed to §4 until `sudo apt update` is completely clean.

---

## 4. Phase C — the release upgrade

```bash
# 1. fully patch 24.04 first
sudo apt update && sudo apt full-upgrade -y && sudo apt autoremove -y
sudo reboot

# 2. quiesce production (public sites go down here)
cd ~/Ideaprojects/nginx && docker compose stop
minikube stop
sudo bash ~/Ideaprojects/STEP0/backup-minikube-mnt.sh    # fresh archive, both disks

# 3. upgrade
sudo do-release-upgrade
```

Notes while it runs:

- **Run it from a physical console or `tmux`**, not a bare SSH session. Over SSH it opens a
  fallback sshd on port 1022; a dropped connection mid-upgrade is how systems get bricked.
- When it asks about **modified config files**, keep your local version for
  `/etc/default/grub`. `/etc/docker/daemon.json` is not shipped by any package, so it will
  not prompt — but verify it afterwards regardless (§5.1).
- It will offer to remove obsolete packages at the end. Accept.
- Expect **1–2 hours** plus reboot.

---

## 5. Phase D — post-upgrade rebuild

### 5.1 Docker

Docker 29 shipped with day-one support for 26.04 and the official repo carries `resolute`
packages, so this is a codename change rather than a workaround:

```bash
sudo sed -i 's/ noble / resolute /' /etc/apt/sources.list.d/docker.list
sudo apt update && sudo apt install -y docker-ce docker-ce-cli containerd.io \
  docker-buildx-plugin docker-compose-plugin
grep cgroupdriver /etc/docker/daemon.json        # MUST still be systemd
docker info | grep -i cgroup                     # Version: 2, Driver: systemd
```

### 5.2 NVIDIA driver (kernel 7.0)

The currently-installed **580.173.02** came from a *jammy* PPA and will not build against
kernel 7.0. Install from the 26.04 archive instead:

```bash
sudo ubuntu-drivers autoinstall
sudo reboot
nvidia-smi                                       # must show the RTX 3080 Ti
```

Then re-verify the container toolkit still works — GPU-in-container is what the cluster
actually depends on:

```bash
docker run --rm --gpus all ubuntu nvidia-smi
```

### 5.3 Rebuild the cluster

The node container was built against the old kernel and docker; rebuild it rather than
hoping it survives:

```bash
minikube delete
cd ~/Ideaprojects/STEP0 && ./start-scratch.sh
```

### 5.4 Bring the proxy back

```bash
cd ~/Ideaprojects/nginx && docker compose up -d
docker exec nginx-proxy-manager nginx -t         # never skip -t
```

---

## 6. Phase E — sign-off and rollback

Walk the full `GM9000-MIGRATION.md` §7 list. The upgrade-specific additions:

- [ ] `stat -fc %T /sys/fs/cgroup` → `cgroup2fs`; `docker info` → Version 2 / systemd driver.
- [ ] `nvidia-smi` works **and** `kubectl describe node minikube | grep nvidia.com/gpu` = 1.
- [ ] `kubectl get po -A` all Running; `kubectl top po -A` returns numbers.
- [ ] Every NPM-fronted domain serves valid HTTPS from outside the LAN.
- [ ] `./verify-recovery.sh` → 0 FAIL.
- [ ] `sudo apt update` clean; `systemctl --failed` empty.
- [ ] 48-hour soak, and Monday's automatic backup lands on both disks.

**Rollback:** BIOS boot menu → `Ubuntu (840 EVO rollback)`. That system is pre-migration
24.04 with cgroup v1 and is fully intact. Two cautions: it will act on whatever state `sdb`
is in at that moment (`GM9000-MIGRATION.md` §9), and any cluster rebuilt on 26.04 will have
written to `minikube-mnt` — so treat a rollback as "restore from the last quiesced archive",
not "carry on where I left off".

---

## 7. Appendix — facts and sources

**Surveyed on this box, 2026-08-06:**

| Fact | Value |
|---|---|
| Current OS / kernel | Ubuntu 24.04.4 LTS, 6.8.0-137-generic, systemd 255 |
| Target | Ubuntu 26.04 LTS (Resolute Raccoon), kernel 7.0, systemd 259 |
| cgroups now | v1 (`tmpfs`), docker driver `cgroupfs` |
| Docker | 27.3.1, from the **jammy** repo |
| NVIDIA | RTX 3080 Ti, driver 580.173.02 (jammy graphics-drivers PPA) |
| k8s pin | v1.31 (`restore-scratch.sh`) |
| Cluster | **absent** — `minikube` profile not found |
| Boot entries | `Boot0006` NVMe (first), `Boot0000` 840 EVO rollback |
| `Prompt=` | `lts` in `/etc/update-manager/release-upgrades` |

**Sources:**

- [Ubuntu 26.04 LTS — summary for LTS users](https://documentation.ubuntu.com/release-notes/26.04/summary-for-lts-users/)
  (systemd 255→259; cgroup v1 legacy **and** hybrid removed; kernel 6.8→7.0)
- [Ubuntu 26.04 LTS release notes](https://documentation.ubuntu.com/release-notes/26.04/)
- [Ubuntu 26.04 LTS released with Kernel 7.0, GNOME 50](https://ubuntuhandbook.org/index.php/2026/04/ubuntu-26-04-lts-released-with-kernel-7-0-gnome-50-more/)
- [Upgrade Ubuntu 24.04 to 26.04 LTS](https://www.linuxtechi.com/upgrade-ubuntu-24-04-to-ubuntu-26-04/)
  (26.04.1 on 2026-08-06 is when the LTS→LTS path opens)
- [Install Docker CE on Ubuntu 26.04 LTS](https://computingforgeeks.com/install-docker-ce-ubuntu-2604/)
  (Docker 29, `resolute` packages available day one)
- [Ubuntu Desktop upgrade documentation](https://ubuntu.com/desktop/docs/en/latest/how-to/upgrade-ubuntu-desktop/)
