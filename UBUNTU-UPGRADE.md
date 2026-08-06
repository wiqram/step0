# UBUNTU-UPGRADE.md — `private-cloud` 24.04 LTS → 26.04 LTS

Runbook for upgrading this host from **Ubuntu 24.04.4 LTS (Noble)** to **Ubuntu 26.04 LTS
(Resolute Raccoon)**. Written 2026-08-06 from a live survey of the box, for an upgrade
planned the week of 2026-08-10.

Companion documents: [`GM9000-MIGRATION.md`](./GM9000-MIGRATION.md) (the disk swap this box
just went through) and [`nginx/CLAUDE.md`](../nginx/CLAUDE.md) (the NPM stack).

> **Do not run `do-release-upgrade` as your first action.** It will produce a system whose
> container stack does not start. Read §0, then do §2 **days before** §4.

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
