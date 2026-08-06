# GM9000-MIGRATION.md — OS-disk swap to a 4TB NVMe, fresh Ubuntu, full restore

Runbook for replacing the boot disk of `private-cloud` with a **4TB Acer Predator GM9000
NVMe** in slot **M.2_1**, fresh-installing Ubuntu, and bringing the private cloud back to
full production via `restore-scratch.sh`. Written 2026-08-06 from a live survey of the box.

> **Keep a copy of this file off the machine before you start** (it is pushed to
> `github.com/wiqram/step0`; open it on your phone or the dev box during the migration —
> the machine you are reading it on is the one being wiped).

---

## 0. Read this first — what is actually in the box (surveyed 2026-08-06)

The plan as stated was *"replace the primary M.2 NVMe with the GM9000 and move the current
M.2 to the secondary slot."* **The current boot disk is not an M.2 and not an NVMe.**
Verified via `lsblk`/`lspci`:

| Device | What it is | Holds |
|---|---|---|
| `sda` | **Samsung 840 EVO 250GB — 2.5″ SATA SSD** (a ~2014-era drive on a SATA cable, not in any M.2 slot; the 840 EVO was never made in M.2 form) | `sda3` ESP, `sda5` `/` (26G used), `sda6` `/home` (72G used, **96% full**), `sda7` `/var` (87G used, 86% — all of docker/minikube lives here) |
| `sdb` | WD Blue 1TB **HDD** (SATA) | `sdb1` `/mnt/minikube-backups` — weekly DR archives (~186G) **and the LIVE `minikube-mnt`** (~60G: vault-data, JENKINS_HOME, grafana-data, every app DB, ollama models 13G); `sdb2` `/mnt/kachra` — live registry blobs (37G, bind-mounted into minikube-mnt); `sdb3` unused |
| — | **No NVMe device exists in the system today.** All four M.2 slots are empty (no NVMe controller on the PCI bus; Intel VMD reports zero child devices) | — |

**Consequences for the plan:**

1. The GM9000 goes into the **empty `M.2_1`** slot (CPU-attached, PCIe 4.0 x4 — the best
   slot on the board). Nothing needs to move to a "secondary M.2 slot": the 840 EVO stays
   right where it is, on its SATA cable, and becomes the **rollback disk** (§9).
2. This migration is an **OS-disk swap, not bare-metal disaster recovery**: `sdb` — which
   carries the cluster's entire stateful universe (Vault raft data, Jenkins home, all app
   databases, secrets, registry images, DR archives) — **survives untouched**. That makes
   this far safer than the true-DR scenario `restore-scratch.sh` was written for, but it
   adds one trap this runbook defuses in §2 step 4 (don't let a week-old archive overwrite
   the live data that survived).
3. Board = **ASUS ProArt Z690-CREATOR WIFI**: 4× M.2 (M.2_1 = CPU PCIe 4.0 x4, 2242–22110;
   M.2_2/M.2_3/M.2_4 = chipset PCIe 4.0 x4; M.2_4 shares bandwidth with SATA ports 5–8),
   8× SATA. The GM9000 is a **PCIe 5.0** drive (SMI SM2508, up to 14,000/13,000 MB/s, 4GB
   DRAM on the 4TB model, M.2 2280 single-sided, 5-yr warranty). In this Gen4 slot it will
   link at **PCIe 4.0 x4 (~7.4 GB/s ceiling)** — that is expected, not a fault, and still
   roughly **14× the sequential and far more of the random-I/O throughput** of the 840 EVO.
   A Gen5 drive running at Gen4 also draws less power and runs cooler; use the board's
   M.2_1 heatsink (peel the film off its thermal pad; keep the drive's own label on — it
   is the heat spreader).

The whole job in one line: **prep + fresh backup (§2) → hardware swap (§3) → install
Ubuntu 24.04 on the GM9000 with the §1 layout (§4) → pre-restore setup (§5) → run
`restore-scratch.sh` (§6) → verify production (§7) → optional NVMe performance phase (§8)
→ deal with the old disk (§9).**

Expect the public sites to be **down for roughly half a day** (realistic: 4–8 h including
soak checks). Nothing keeps serving while the box is down; pick a quiet window.

---

## 1. Partitioning the 4TB GM9000 (what goes where, and why)

### 1.1 Design goals

- **Isolation**: the July incident (`/var` at 90% → kubelet `DiskPressure=True` → node
  tainted → Prometheus `Pending`) was caused by Docker churn sharing a filesystem with the
  OS. Docker gets its **own** filesystem so a runaway build can never starve the OS again.
- **The minikube cluster, all k8s images, the buildkit caches and the host images all live
  in `/var/lib/docker`** (minikube driver=docker keeps the node's entire filesystem in a
  docker volume). That is the hottest, churniest path on the box — it gets the big, fast,
  isolated allocation.
- **Don't repeat today's sizing mistakes at 16× scale.** Today `/home` is 96% full and
  `/var` 86% while `sdb3` (282G) sits idle. Size generously, and deliberately leave a
  large **unallocated tail** so future needs are an online `growpart`/new partition away,
  instead of a reinstall.
- **Restore first, optimize second.** Phase 1 (this runbook) reproduces today's layout
  exactly — `minikube-mnt` and registry blobs stay on the HDD so every script path,
  backup job and `--mount-string` works unmodified. §8 then moves the hot platform data
  to the NVMe as a separate, reversible change.

### 1.2 The layout (plain GPT partitions — recommended)

| # | Size | FS | Mount | Why |
|---|------|----|-------|-----|
| 1 | 1 GiB | FAT32 | `/boot/efi` | ESP. |
| 2 | 120 GiB | ext4 | `/` | OS + `/usr` + `/opt` + snaps' squashfs mounts. Today's root uses 26G; 120G absorbs a decade of package growth. (No separate `/usr` — splitting `/usr` is obsolete practice and complicates boot.) |
| 3 | 120 GiB | ext4 | `/var` | System var **without** docker: journald, apt, snapd state, `/var/log`. Today's /var minus docker is ~15G. Isolates log growth from both OS and docker. |
| 4 | 600 GiB | ext4 | `/home` | Repos, IDE caches (`~/.cache` 16G, `~/.local` 11G today), Downloads. Today 72G used on a 79G partition — this ends the 96%-full era. |
| 5 | 900 GiB | ext4 | `/var/lib/docker` | **The minikube cluster node, every k8s image, host images, buildkit cache.** Today ~73G used; 900G gives Jenkins build churn and the §8 growth room to never trigger DiskPressure. |
| — | ~2.0 TiB | — | *unallocated tail* | Future: §8 `platform-data` partition (minikube-mnt + registry on NVMe), or growing partition 5 (it is last on purpose — it can grow contiguously into the tail). |

- **Swap: none on disk.** The box runs **zram** (zram-tools: `ALGO=zstd`, `PERCENT=35`
  ≈ 33G on 96G RAM) — reproduce that in §5 instead. A disk swap partition would only be
  needed for hibernation, which a 24/7 server never uses.
- **Format technique, all ext4**: this is deliberate — the entire stack is proven on ext4,
  overlay2 is happy on it, and one filesystem type keeps every tool and muscle-memory
  valid. (XFS was considered for `/var/lib/docker` and rejected: negligible gain at this
  scale, can't shrink, and it would make this the only XFS on the estate.) After install:
  - `sudo tune2fs -m 1 <dev-of-home>` and `-m 1 <dev-of-docker>` — the default 5%
    root-reserve would waste ~75G across those two big filesystems; 1% is plenty off-root.
  - TRIM: do nothing — Ubuntu's weekly `fstrim.timer` is on by default and is the correct
    mechanism (don't add `discard` mount options).
  - Keep default `relatime`; that is what prod runs today.

### 1.3 Considered and rejected

- **One big `/` (installer default)** — rejected: no blast-radius isolation; docker churn
  filling the OS filesystem is exactly the failure mode we just spent July fixing.
- **Full LVM** — genuinely attractive (resize any volume online), and if you prefer it,
  install from the **Ubuntu Server ISO** (its Subiquity installer supports custom LVM;
  the 24.04 Desktop installer's manual mode does not) and `apt install ubuntu-desktop`
  afterwards — but note the extra footguns: the desktop meta-package must then be told to
  hand networking to NetworkManager (the 10GbE profile in `restore-scratch.sh` phase 8 is
  created with `nmcli`), and you take an unfamiliar installer path on a production
  rebuild day. Plain partitions + a 2 TiB free tail deliver 90% of the flexibility with
  zero installer risk, so that is the recommendation.
- **Moving `minikube-mnt`/registry to NVMe during the restore** — rejected for phase 1:
  it would change `start-scratch.sh --mount-string`, `ensure-registry-store.sh`, fstab
  binds and the backup script all at once, on the same day as a disk swap. §8 does it
  safely later. **During this migration, the HDD keeps its current role unchanged.**

---

## 2. Before shutdown — prep on the OLD system (~1 h, do it all)

Work through this in order on the running box. Steps 4–5 are the ones that protect you.

**1. Push every repo.** Anything not on GitHub does not come back through phase 5 clones
(it survives on the old disk, but you don't want to depend on forensics). Survey:

```bash
for d in /home/cloud/Ideaprojects/*/ /home/cloud/IdeaProjects/*/; do
  [ -d "$d/.git" ] || continue
  s=$(git -C "$d" status --porcelain | wc -l)
  a=$(git -C "$d" rev-list --count @{u}..HEAD 2>/dev/null || echo '?')
  [ "$s$a" = "00" ] || echo "$s dirty, $a ahead: $d"
done
```

As of 2026-08-06 six repos have uncommitted files (`nginx`, `vault`,
`IG-Trading-Microservices`, `qcx`, `splunk-hsbc-demo`, `docker-development-youtube-series`).
Commit/push what matters, discard what doesn't. Also confirm **this file** is pushed:
`git -C ~/Ideaprojects/STEP0 log origin/master..master` should be empty.

**2. Baseline health.** `./verify-recovery.sh` should PASS now — if something is already
broken, fix it or note it; you don't want to discover it post-restore and blame the
migration. Also record `kubectl get po -A | grep -cv Running`.

**3. Lock the LAN IP.** The router forwards 80/443 to **192.168.50.53**, but the box gets
that address via **DHCP** (`enp6s0`, Intel I225-V). In the router admin, add a **DHCP
reservation** binding `enp6s0`'s MAC to 192.168.50.53 (get the MAC with
`ip link show enp6s0`). The NIC doesn't change in this migration, so the fresh install
will then come up on the same IP and the router port-forwards keep working — this is
what makes "repoint DNS" unnecessary (§6).

**4. Quiesce, then take a fresh backup — THE critical step.** The weekly archive is from
Monday; `restore-scratch.sh` phase 4 will extract the latest archive **over** the live
`minikube-mnt` that survives on `sdb`. If that archive is days old, you'd silently roll
Vault, Jenkins and every app DB back to Monday. A quiesced same-day backup makes the
overwrite a harmless no-op:

```bash
cd ~/Ideaprojects/nginx && docker compose stop     # stop public traffic
minikube stop                                      # stop the cluster (DBs, vault flush to sdb)
sudo bash ~/Ideaprojects/STEP0/backup-minikube-mnt.sh   # fresh archive + WD off-site copy
```

Verify: the ntfy `yolo-private-cloud-backup` note arrives with **tar rc=0** (a quiesced
system should not even hit rc=1), and today's `private-cloud-08-XX-26.tgz` is present in
**both** `/mnt/minikube-backups/` and `/mnt/wdcloud/`. Expect ~41GB and ~30–45 min
(the Aug-03 archive was 41G; see §10.3).

Two reassurances about the quiesce: `cluster-autostart.sh` explicitly **respects** an
operator `minikube stop` (exited container → "RESPECTING, not starting"), so the */10
cron will not undo it. And `alerting-pipeline-watch.sh` *will* page
`yolo-private-cloud-resource-crunch` after ~15 min of Prometheus being down — that is
the watchdog working as designed; expect that alert (and later its "cleared" note)
throughout the migration window.

**5. Salvage bundle** — small items that are in **no backup and no repo**. The old disk
survives, so this is belt-and-braces, but 2 minutes now beats mounting the old root later:

```bash
# on sdb1 (NOT /mnt/kachra — its root is not writable by the cloud user)
H=/mnt/minikube-backups/migration-handoff && mkdir -p $H
cp -a ~/.ssh $H/ssh 2>/dev/null                      # SSH keys (dev-box access etc.)
cp -a ~/.gitconfig $H/ 2>/dev/null
cp -a ~/.docker/config.json $H/docker-config.json 2>/dev/null   # docker hub login (if any)
cp -a ~/.local/bin $H/local-bin                      # gh / sops / age binaries
cp /etc/hosts /etc/fstab /etc/default/zramswap /etc/docker/daemon.json $H/
cp /etc/default/grub $H/grub                         # the cmdline to reproduce (§5)
crontab -l > $H/cloud-crontab.txt
sudo crontab -u root -l > $H/root-crontab.txt
ip link show enp6s0 | grep ether > $H/lan-mac.txt
nvidia-smi --query-gpu=driver_version --format=csv,noheader > $H/nvidia-driver.txt
```

Note what is **deliberately not salvageable**: the `gh` GitHub token and any browser
sessions live in the GNOME keyring, encrypted with the login password — plan to re-run
`gh auth login` fresh (§5). `~/.vault/`, `STEP0/.env`, the SOPS age key and the wd-backup
SMB creds are all **already inside the backup archive** (verified against
`backup-minikube-mnt.sh`) — you do not need to hand-carry those.

**6. Shut down.** `sudo shutdown -h now`. Do **not** wipe, format or "clean up" the old
disk at any point in this runbook — it is the rollback (§9).

---

## 3. Hardware swap + BIOS (~20 min)

1. **Unplug both SATA drives** (the 840 EVO *and* the `sdb` HDD) — pull their SATA data
   cables and remember which port each was in. This guarantees the Ubuntu installer can
   only see the NVMe: the bootloader/ESP land on the GM9000 and there is zero chance of
   the installer touching the rollback disk or the data disk.
2. Fit the **GM9000 into M.2_1** (the CPU slot, under the primary heatsink between the
   CPU and the top PCIe slot). Single-sided 2280 — fits the standoff as-is. Peel the
   protective film off the heatsink's thermal pad; do **not** peel the drive's label.
3. Boot into BIOS:
   - Confirm the drive is detected and linked at **PCIe 4.0 x4**.
   - **Disable Intel VMD** (Advanced → System Agent → VMD setup). It is currently ON,
     provides nothing on a non-RAID single-drive setup, and with it off the NVMe
     enumerates as a plain device — no `vmd` driver layer between you and the disk.
     (SATA stays AHCI; changing VMD does not affect the SATA controller here.)
   - Leave Secure Boot as it is today (off). Leave XMP/RAM as-is.
4. After the OS install (§4) completes and boots: power off, **reconnect both SATA
   drives**, boot again, and set BIOS boot priority to **the new "ubuntu" entry on the
   GM9000 first**. The old disk's boot entry stays in the list — that's the §9 rollback.

---

## 4. Fresh Ubuntu install on the GM9000 (~30 min)

**Install Ubuntu 24.04.x LTS (Noble) Desktop — NOT 25.x/26.04.** This is a deliberate,
load-bearing choice, not conservatism for its own sake:

- The entire stack is **proven** on 24.04: kernel 6.8, Docker 27.3, minikube/kubelet,
  NVIDIA 580-server-open, cgroup config, the DR scripts' apt repos (`restore-scratch.sh`
  pins the k8s v1.31 apt repo, etc.).
- **The cluster runs cgroup v1** (`systemd.unified_cgroup_hierarchy=0` on the kernel
  cmdline, `native.cgroupdriver=cgroupfs` in docker's daemon.json — both live facts of
  this box). systemd **removed cgroup-v1 support in v256**, which ships in everything
  newer than 24.04. On a newer Ubuntu that boot parameter is a no-op and the whole
  container stack comes up in an unproven configuration — a production rebuild is the
  wrong day to absorb that. (Moving to cgroup v2 is a fine *future* project: do it as its
  own change with a rollback plan, never bundled into a disk swap.)
- Desktop edition, because this box genuinely runs a GUI workload (IntelliJ, Chrome).

Installer choices:

- **Manual ("Something else") partitioning** → create the §1.2 table on the NVMe (the
  only disk visible, since SATA is unplugged). For partition 5, type the mount point
  `/var/lib/docker` if the installer's dropdown doesn't offer it; if the installer
  refuses a custom mount point, create the partition ext4 with **no** mount point and
  wire it in §5 step 2 instead (two commands, before docker exists — nothing is lost).
  Leave the ~2 TiB tail unallocated.
- **Username `cloud`** — hard requirement, `restore-scratch.sh` phase 0 dies on any other
  user (`$HOME` must be `/home/cloud`).
- Hostname `private-cloud` (phase 1 would fix it anyway, but set it correctly now).
- Timezone **Europe/London** — the crontab schedules are written in local time and were
  painstakingly phased around it; a UTC box would re-break them.
- Connect to the wired LAN; skip Ubuntu Pro/livepatch prompts (re-attach later if wanted).
- No third-party-drivers checkbox needed (NVIDIA is handled properly in §6 phase 1).

First boot: `sudo apt update && sudo apt full-upgrade -y`, then power off and reconnect
the SATA drives (§3 step 4). Verify on the next boot: `lsblk` shows the NVMe root plus
the untouched `sda`/`sdb`, and `ip -4 addr show` shows **192.168.50.53** (the §2 step 3
reservation doing its job).

---

## 5. Pre-restore setup — what `restore-scratch.sh` does NOT do (~30 min)

Answering the direct question: **`restore-scratch.sh` installs all core tooling itself**
(docker + daemon.json, kubectl, minikube, helm, jq, nfs-common, NVIDIA driver + container
toolkit, gcloud) — you do *not* pre-install those. But it **carries no credentials and no
host-boot config**. It cannot log into GitHub for you, and the following six things are
yours to do first, in this order:

**1. Kernel cmdline (cgroup v1 + IOMMU) — restore-scratch does NOT reproduce this.**
The live box boots with:

```
intel_iommu=on systemd.unified_cgroup_hierarchy=0 kvm.ignore_msrs=1 vfio-pci.ids=10de:1e07,10de:10f7,10de:1ad6,10de:1ad7
```

`systemd.unified_cgroup_hierarchy=0` is the one that matters (see §4); `intel_iommu=on`
supports GPU-in-container; `kvm.ignore_msrs` and the `vfio-pci.ids` are inert relics of
the retired KVM era (those PCI IDs are an RTX 2080 Ti that is no longer in the machine —
verified: the only GPUs present are the iGPU and the 3080 Ti, so the vfio line binds
nothing). Reproduce at minimum the first two; carrying the full original line verbatim is
equally safe if you prefer byte-identical:

```bash
sudo sed -i 's/^GRUB_CMDLINE_LINUX_DEFAULT=.*/GRUB_CMDLINE_LINUX_DEFAULT="intel_iommu=on systemd.unified_cgroup_hierarchy=0"/' /etc/default/grub
sudo update-grub && sudo reboot
# after reboot, verify:  cat /proc/cmdline   and   stat -fc %T /sys/fs/cgroup  -> "tmpfs" (v1), not "cgroup2fs"
```

**2. Mount the surviving disks** (in true bare-metal DR phase 3 handles this, but doing it
first avoids the phase-2/phase-3 ordering wrinkle described in §10.3, and if the installer
couldn't set `/var/lib/docker`, wire that partition now too):

```bash
sudo mkdir -p /mnt/minikube-backups /mnt/kachra
echo '/dev/disk/by-label/minikube-backups /mnt/minikube-backups auto nosuid,nodev,nofail,x-gvfs-show 0 0' | sudo tee -a /etc/fstab
echo '/dev/disk/by-label/Kachra /mnt/kachra auto nosuid,nodev,nofail,x-gvfs-show 0 0' | sudo tee -a /etc/fstab
# only if the installer could not mount partition 5 at /var/lib/docker:
#   echo '/dev/disk/by-partuuid/<p5-uuid> /var/lib/docker ext4 defaults 0 2' | sudo tee -a /etc/fstab
sudo systemctl daemon-reload && sudo mount -a
ls /mnt/minikube-backups/   # expect: minikube-mnt/, private-cloud-*.tgz incl. your §2 fresh one
```

Do **not** pre-create the registry bind — `ensure-registry-store.sh` (run inside
start-scratch) recreates the `/mnt/kachra/container-registry-images` fstab bind itself.

**3. zram swap** (prod parity): `sudo apt install -y zram-tools`, set
`/etc/default/zramswap` to `ALGO=zstd` / `PERCENT=35`, then
`sudo systemctl restart zramswap` (verify `swapon --show` ≈ 33G).

**4. /etc/hosts** — restore-scratch phase 9 item D; add now so nothing trips on it:

```
192.168.50.53   nginx-private-cloud.com
192.168.50.53   jenkins-private-cloud.com
192.168.50.53   jenkins-slave-private-cloud.com
127.0.0.1       container-registry-private-cloud.com
127.0.0.1       tatesremedies.com
```

**5. GitHub auth + clone STEP0** — **restore-scratch has NO git credentials** (the old
token lived in the GNOME keyring and died with it). All `wiqram/*` repos are private, so
phase 5 clones fail without this:

```bash
sudo apt install -y gh git
gh auth login        # GitHub.com → HTTPS → login via browser; grant repo scope
gh auth setup-git    # use gh as the git credential helper
git config --global user.name  "wiqram"
git config --global user.email "<your commit email>"    # copy from salvage .gitconfig
mkdir -p ~/Ideaprojects ~/IdeaProjects                  # BOTH casings — they are different dirs
gh repo clone wiqram/step0 ~/Ideaprojects/STEP0         # exact casing: Ideaprojects (lower p)
```

Also reinstall the small host tools that live outside apt and are needed by the vault
tooling: copy `sops` and `age` from the salvage bundle (`/mnt/minikube-backups/migration-handoff/local-bin/`)
into `~/.local/bin/` (and ensure `~/.local/bin` is on PATH), or fetch fresh releases.

**6. Docker Hub login — after phase 1 installs docker** (restore-scratch phase 9 item B):
`docker login` with the Docker Hub account/PAT, so image pulls during bootstrap don't hit
anonymous rate limits. If you skipped it, it only shows up as slow/failed pulls — fix and
re-run.

---

## 6. Run restore-scratch.sh (~2–4 h, mostly unattended)

```bash
cd ~/Ideaprojects/STEP0
./restore-scratch.sh --dry-run    # optional: read what it will do; sends no notifications
./restore-scratch.sh              # type 'restore' at the prompt
```

Subscribe to ntfy `yolo-private-cloud-restore-scratch` and
`yolo-private-cloud-start-scratch` on your phone — the run narrates itself there.
Phase-by-phase, with what is different **in this migration** vs true bare-metal:

| Phase | What happens | This-migration notes |
|---|---|---|
| 0 preflight | user/HOME checks, typed `restore` confirmation | — |
| 1 tooling | hostname, apt base, **docker + daemon.json (cgroupfs)**, kubectl 1.31, minikube, helm, **NVIDIA driver via `ubuntu-drivers autoinstall` + container toolkit**, gcloud | **Expect one interruption**: after the NVIDIA driver installs, **reboot, then re-run `./restore-scratch.sh`** — the phase marker resumes automatically. Verify `nvidia-smi` shows the 3080 Ti after the reboot. |
| 2 pull backup | mounts WD NFS, copies newest `private-cloud-*.tgz` to `/mnt/minikube-backups` | Your §2 fresh archive is already on `sdb1`; the WD copy is the same file, so this is a ~41G LAN copy (~7 min) that lands on an identical file. Harmless — let it run (it also proves the WD DR path works). |
| 3 storage layout | mounts labelled disks, creates dirs, chowns | Disks already mounted from §5.2 — phase just confirms. The `chown -R cloud:cloud /mnt/minikube-backups` pass over ~250G on the HDD takes a few minutes. |
| 4 extract | staging-extract of the archive; places `~/.vault` (unseal key!), `minikube-mnt`, SOPS age key → `~/.config/sops/age/keys.txt`, `qcguy-ghost`, nginx runtime (data/letsencrypt/compose), `STEP0/.env` (JENKINS_CRED, NTFY_URL), `~/wd-backup` (SMB creds) | Because the archive is your quiesced same-day one, the `minikube-mnt` overlay re-applies identical data. This is where the §2 step 4 discipline pays off. |
| 5 clone repos | clones the `restore_repo_manifest` list at pinned branches, overlays nginx runtime onto the clone | Needs the §5.5 `gh` auth. Afterwards spot-check branches: `for d in ...; do git -C $d rev-parse --abbrev-ref HEAD; done` matches the manifest (the stale-branch failure mode is silent — see restore-lib.sh header). |
| 6 platform | `SKIP_APP_BUILDS=1 start-scratch.sh`: 5million network, registry store bind, **minikube start** (16 cpu / 64G / GPU / minikube-mnt mount), durable registry, metrics-server + gpu plugin, kube-prometheus, **vault restore + unseal from `~/.vault`**, grafana admin sync, jenkins (restored JENKINS_HOME) | Longest phase (~30–60 min; first run pulls the kicbase + all platform images over the network). Watch `yolo-private-cloud-start-scratch`. |
| 7 nginx | `docker compose up -d` on the restored NPM (all proxy hosts + TLS certs come from the archive) | NPM's Let's Encrypt certs restored intact — no re-issuance needed. |
| 8 automation | restart policy, **cloud crontab (canonical) + root backup cron + wd-backup 02:00 cron**, 10GbE `/30` NM profile on the atlantic NIC, watchdog + devbox-kube-access systemd units, WD NFS fstab automount, vault-auto-unseal loop, agent deploy-URL seeding | All automatic. |
| 9 verify + handoff | `minikube status`, vault seal check, Jenkins credential preflight, `verify-recovery.sh`, prints the handoff | See below. |

**After phase 9 — the handoff steps, adapted to this migration:**

1. **DNS: nothing to change.** Same house, same router, same public IP, and §2 step 3
   pinned the LAN IP. Just verify: `dig +short jenkins.traderyolo.com` equals
   `curl -s ifconfig.me`, and `https://jenkins.traderyolo.com` answers (proves router
   port-forward → NPM → cluster end-to-end).
2. **Deploy the apps:** `./trigger-app-builds.sh`. Unlike true bare-metal DR, the registry
   on `sdb2` **survived with all images**, so expect existing pods to pull immediately and
   Jenkins builds to be warm-ish rather than ground-zero rebuilds.
3. **Ollama models: no re-pull needed** (another divergence from the printed handoff —
   models are excluded from the *tar* but live in `minikube-mnt/ollama/models` on `sdb`,
   which survived; verify with `du -sh /mnt/minikube-backups/minikube-mnt/ollama/models`
   ≈ 13G, then confirm the ollama pod serves).
4. ntfy subscriptions (phone): `yolo-private-cloud-platform`,
   `yolo-private-cloud-resource-crunch`, `yolo-private-cloud-backup`, `yolo-grafana`,
   `yolo-wd-cloud-backup`.
5. If phase 9 warned that `JENKINS_CRED` doesn't authenticate: fix `STEP0/.env` per the
   warning before triggering builds (both credential and token hash came from the same
   backup, so with the §2 fresh archive this warning should not appear).

---

## 7. Proving production is fully back (the sign-off list)

Run through all of these; the migration is done when every line passes.

**Platform:**
- [ ] `./verify-recovery.sh` → exit 0, no FAIL lines (checks fixed IPs, both NAS, 10GbE,
      hostname/DNS/public-IP, vault unsealed, all three crons).
- [ ] `kubectl get po -A` — all Running/Completed; no CrashLoop/Pending.
- [ ] `kubectl top po -A` returns numbers (metrics-server owns `v1beta1.metrics.k8s.io`).
- [ ] `kubectl get apiservice v1beta1.metrics.k8s.io v1beta1.custom.metrics.k8s.io` —
      first owned by `kube-system/metrics-server`, second by prometheus-adapter.
- [ ] `kubectl -n vault exec vault-0 -- vault status` → `Sealed false`; a known kv path
      reads back (e.g. via an app pod's injected secret).
- [ ] GPU: `kubectl describe node minikube | grep nvidia.com/gpu` shows 1; ollama answers
      a prompt.
- [ ] Grafana login works (`./sync-grafana-admin.sh --status` chain all green);
      dashboards render; the Alertmanager `Watchdog` alert is firing (that's healthy);
      `./alerting-pipeline-watch.sh --status` all probes OK.
- [ ] Jenkins UI reachable at `https://jenkins.traderyolo.com`, jobs list intact
      (restored JENKINS_HOME), one app build ran green end-to-end (build → push to
      registry → rollout).

**Public sites — walk the NPM proxy-host list** (NPM admin UI on
`http://172.16.238.10:81`) and curl every domain it fronts over HTTPS from *outside* the
LAN if possible (phone off Wi-Fi): qcguy.com, the `*.traderyolo.com` set (jenkins,
grafana, container-registry, …), tatesremedies, predictonomy/bestrental/dyingpaleblue/
helpmepdf/radcliffe domains — valid cert, right content. For grafana.traderyolo.com,
Grafana Live only needs the websocket toggle if NPM was *rebuilt*; ours was restored, so
it should just work.

**Ops loop:**
- [ ] Cloud crontab matches `cron/cloud-crontab` (`crontab -l | diff - cron/cloud-crontab`),
      root cron has the Monday 05:00 backup, `/etc/cron.d/wd-backup` exists.
- [ ] Run `sudo bash backup-minikube-mnt.sh` once by hand → ntfy OK note, archive on both
      disks (proves the whole backup path on the new OS).
- [ ] Dev box: `ssh vik@10.10.10.2` works over the 10GbE /30; on the dev box
      `kubectl --context prod-minikube get ns` answers; `jenkins-deploy <app>` still fires.
      (If the /30 is dark, that's the known atlantic link-wedge — check the watchdog is
      installed on the new box: `systemctl status 10gbe-link-watchdog`.)
- [ ] 48-hour soak: no unexpected ntfy alerts; `kubectl get po -A` stable; Monday's
      automatic backup lands on both disks.

Only after the soak passes, consider §8/§9.

---

## 8. Optional phase 2 — move the hot platform data to the NVMe

*(Do this days/weeks later, as its own maintenance window — never bundled with the swap.)*

**Motivation:** after §6, everything I/O-heavy except one thing is on the NVMe. The
exception is `minikube-mnt` — Jenkins home, Grafana, Vault, and **every app database**
(postgres ×4, mysql, mongo, redis, loki) — plus the registry blobs, all still on a 1TB
spinning HDD shared with the weekly backup writes. If Jenkins feels slow or `iostat -x 5`
shows `sdb` pegged at 100% util during builds/deploys, this move is the fix. (Measure
first; if the HDD isn't the bottleneck, skip this section — it's optional for a reason.)

**Mechanism — bind-mount, so every script keeps its path.** The canonical path
`/mnt/minikube-backups/minikube-mnt` stays valid for `start-scratch.sh --mount-string`,
`backup-minikube-mnt.sh`, and all docs; only the *backing store* moves:

```bash
# 1. carve a partition from the NVMe free tail (example: 800G) and format it
sudo parted /dev/nvme0n1 -- mkpart platform-data ext4 <start> <end>
sudo mkfs.ext4 -L platform-data /dev/nvme0n1p6 && sudo tune2fs -m 1 /dev/nvme0n1p6
sudo mkdir -p /mnt/platform-data
echo '/dev/disk/by-label/platform-data /mnt/platform-data ext4 defaults 0 2' | sudo tee -a /etc/fstab
sudo mount /mnt/platform-data

# 2. cold-stop the cluster, then copy (HDD-read-bound: ~60G ≈ 10 min)
cd ~/Ideaprojects/nginx && docker compose stop && minikube stop
sudo rsync -aHAX /mnt/minikube-backups/minikube-mnt/ /mnt/platform-data/minikube-mnt/
sudo rsync -aHAX /mnt/kachra/container-registry-images/ /mnt/platform-data/container-registry-images/

# 3. shadow the HDD copies with binds (fstab, before the existing registry bind line):
#    /mnt/platform-data/minikube-mnt  /mnt/minikube-backups/minikube-mnt  none bind 0 0
#    and CHANGE ensure-registry-store.sh's SRC to /mnt/platform-data/container-registry-images
#    (one-line edit; commit it). Remove the old kachra bind line from fstab.

# 4. the minikube docker driver captures binds at CONTAINER CREATION → cold rebuild:
minikube delete && cd ~/Ideaprojects/STEP0 && ./start-scratch.sh
```

**Consequences to accept + mitigate:** the platform data then lives on the same physical
disk as the OS, losing today's disk-failure isolation. The weekly archive + WD off-site
still protect it (the tar reads the canonical path, i.e. the NVMe data, unchanged), but
tighten the loss window with a cheap nightly rsync back to the now-otherwise-idle HDD —
add to the root cron: `0 4 * * * rsync -aHAX --delete /mnt/platform-data/minikube-mnt/ /mnt/minikube-backups/minikube-mnt-nightly-mirror/`.
The old on-HDD `minikube-mnt` copy from step 2 can serve as that mirror's seed. Update
`CLAUDE.md`/`architecture.md` when you do this.

---

## 9. The old 840 EVO — rollback first, then retirement

**Weeks 0–2 (soak): touch nothing.** The complete pre-migration OS stays bootable on it.
Rollback procedure if the new install goes sideways: BIOS boot menu → old ubuntu entry →
the whole old stack boots and serves. Two rules:
- Rollback is a **deliberate decision, not a dual-boot toy** — the old OS's crons
  (cluster-autostart, backups) will act on the *live, possibly newer* `sdb` data the
  moment it boots. Boot it only to genuinely roll back (fine: `sdb` state is shared, the
  cluster carries on) or with `sdb` unplugged for pure inspection.
- Never boot both installs' automation in the same day and expect the crontabs to
  coordinate — they won't.

**After the §7 soak passes — retire it from every critical path.** It is a ~12-year-old
consumer TLC drive (the 840 EVO generation with the notorious read-degradation firmware
history) that just spent years at 86–96% full. Check its health once
(`sudo smartctl -a /dev/sda` → Wear_Leveling_Count, reallocated sectors), then wipe:

```bash
sudo wipefs -a /dev/sda            # after triple-checking lsblk that sda is the 840 EVO
sudo parted /dev/sda -- mklabel gpt mkpart scratch ext4 0% 100%
sudo mkfs.ext4 -L scratch /dev/sda1
echo '/dev/disk/by-label/scratch /mnt/scratch auto nosuid,nodev,nofail,noauto,x-gvfs-show 0 0' | sudo tee -a /etc/fstab
```

Sensible uses, in order of usefulness: **(a)** scratch/experiment disk (`/mnt/scratch`) —
image exports, test VMs, restore rehearsals; **(b)** somewhere to move the cold clutter
currently on `sdb1` (`old-minikube-mnt/`, `dev-ollama-models/`, the 2025 archives) so the
backup disk holds only backups; **(c)** pull it entirely and keep it on a shelf as the
"last known good pre-migration system" for a few months. **Do not** put anything
production-critical (backups included) on it — wiping it also deletes the rollback, so
only do this after you are certain the new system is the system.

---

## 10. Appendix

### 10.1 Facts card (surveyed 2026-08-06 — the values §5–§7 must reproduce)

| Fact | Value |
|---|---|
| Hostname / user | `private-cloud` / `cloud` |
| LAN | `enp6s0` (I225-V 2.5GbE), **192.168.50.53** via DHCP, gw 192.168.50.1 |
| 10GbE | `enp4s0` (AQC113CS), static **10.10.10.1/30**, dev box 10.10.10.2 (OOB: vik@192.168.50.161) |
| Cluster IPs | node 172.16.238.2, NPM 172.16.238.10, gw 172.16.238.1, net `5million` 172.16.0.0/16 |
| Kernel cmdline | `intel_iommu=on systemd.unified_cgroup_hierarchy=0` (+ inert kvm/vfio relics, §5.1) |
| cgroups | **v1** (docker `Cgroup Version: 1`, driver `cgroupfs`) |
| daemon.json | cgroupfs + json-file 100m + overlay2 + nvidia runtime (phase 1 + nvidia-ctk reproduce it) |
| NVIDIA | driver 580-server-open (580.173.02), container-toolkit 1.20; GPU = RTX 3080 Ti only |
| RAM / swap | 96 GB DDR5; zram-tools zstd 35% (~33G), no disk swap |
| Timezone | Europe/London (crontab times are local) |
| NAS | DR/off-site: WD Cloud NFS 192.168.50.169:/nfs/private-cloud → /mnt/wdcloud (hard,nofail,automount); tenant SMB pair .68→.251 |
| Backups on sdb1 | weekly `private-cloud-MM-DD-YY.tgz`, latest 2026-08-03 41G; live `minikube-mnt` ~60G incl. ollama models 13G |
| Registry blobs | `/mnt/kachra/container-registry-images` (37G) bind → `minikube-mnt/container-registry-images` |
| Minikube | `--cpus 16 --memory 65536 --disk-size 40g --driver=docker --gpus all --network 5million --mount minikube-mnt→/mnt` |
| Board / drive | ProArt Z690-CREATOR WIFI (M.2_1 = CPU Gen4 x4); GM9000 4TB Gen5 (runs Gen4 here — expected) |

### 10.2 Rough timeline

| Step | Duration |
|---|---|
| §2 prep + quiesced backup | ~1–1.5 h (backup tar ~40 min) |
| §3 swap + §4 Ubuntu install + updates | ~1 h |
| §5 pre-restore setup | ~30 min |
| §6 restore (incl. one NVIDIA reboot, phase 6 ~1 h) | ~2–4 h |
| §7 verification | ~1 h + 48 h passive soak |
| **Site downtime (quiesce → apps redeployed)** | **~4–8 h** |

### 10.3 Quirks found while writing this (for the backlog — none block the migration)

1. **`restore-scratch.sh` does not reproduce the kernel cmdline** (cgroup v1). On true
   bare metal that's a silent config drift; §5.1 covers it manually here. Consider adding
   a phase-8 GRUB check to the script.
2. **Phase 2 copies the archive into `/mnt/minikube-backups` *before* phase 3 mounts the
   labelled disk over that path** — on true bare metal the copy can be shadowed by the
   later mount. Pre-mounting the disks (§5.2) sidesteps it; worth reordering some day.
3. **The weekly archive has grown 21G → 41G in six weeks — and it is the registry.**
   The blob store is bind-mounted *inside* `minikube-mnt`, so tar sweeps it up: a full
   listing of the 08-03 archive attributes **34.03 GB (~83%) to
   `container-registry-images`** (next largest: nginx 6.9G, jenkins 2.2G,
   predictonomy-backups 1.7G; docker blobs are pre-compressed so they pass ~1:1 into
   the tgz). Root cause of the store's growth: the yolo pipeline pushes a `bNNNN` tag
   per service per build and nothing prunes — 8 services × **302 tags** each (+
   marketstream 97) vs exactly 1 tag for every other app. At +4–6G/week the retention
   math fills `sdb1` (164G free) **before the September prune relief** — this needs
   fixing BEFORE the migration's same-day backup. Fix layers: (a) `--exclude` the
   registry dir from the tar (archive drops to ~7G; matches the documented "registry
   rebuilds via Jenkins" DR contract) + dump a `_catalog`/tags listing into the archive
   instead; (b) prune old build tags via the registry API (registry:3,
   `REGISTRY_STORAGE_DELETE_ENABLED=true`) then `garbage-collect` — note
   `delete-docker-reg-images.sh` is a Registry-**v1** relic and does NOT work on this
   store.
4. `CLAUDE.md` said 48 GB RAM; the box has 96 GB (upgraded with the 64G minikube
   envelope). Fixed in the same commit as this file.

### 10.4 Sources for the hardware claims

- GM9000: [Tom's Hardware review](https://www.tomshardware.com/pc-components/ssds/acer-predator-gm9000-2tb-ssd-review) · [TheSSDReview (SM2508)](https://www.thessdreview.com/our-reviews/nvme/predator-gm9000-gen5-2tb-ssd-review/) · [Predator Storage product page](https://www.predatorstorage.com/products/pcie-m-2-ssd/gm9000-gen5-ssd/)
- Board: [ASUS ProArt Z690-CREATOR WIFI tech specs](https://www.asus.com/motherboards-components/motherboards/proart/proart-z690-creator-wifi/techspec/) (M.2_1 CPU PCIe 4.0 x4; M.2_4 shares SATA 5–8; 8× SATA)
- Everything else: live survey of this box, `restore-scratch.sh`, `backup-minikube-mnt.sh`,
  `start-scratch.sh`, `restore-lib.sh`, `verify-recovery.sh` as of commit `080d48e`.
