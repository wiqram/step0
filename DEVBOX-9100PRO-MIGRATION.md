# DEVBOX-9100PRO-MIGRATION.md — dev box M.2 swap to a Samsung 9100 PRO 4TB

Runbook for replacing the dev box's M.2 (Samsung 980 1TB) with a **Samsung 9100 PRO
4TB**, fresh-installing Ubuntu, and rewiring the dev↔prod integration. Companion to
[`GM9000-MIGRATION.md`](./GM9000-MIGRATION.md) (the prod-box OS-disk swap). Written
2026-08-06 from a live SSH survey of the box; **retargeted 2026-08-07 to Ubuntu 26.04
LTS** (was 24.04) after the 9100 PRO was physically fitted.

**Status 2026-08-07 (evening) — §2 through §6 are DONE; the box is rebuilt and working.**
Ubuntu 26.04 LTS is installed on the 9100 PRO and running: `/boot/efi` is
`nvme0n1p1` (**the ESP decoupling, this migration's headline goal, achieved**), `/` on
p2, `/home` on p5, the drive links at **32.0 GT/s ×4 = PCIe 5.0 ×4**. NVIDIA 595.84,
Docker 29.7.2 with its data on p4, Go 1.26.5, Node 24, kubectl 1.34.10, ollama 0.32.6
serving all four models on `10.10.10.2:11434`, and the dev compose stack green
(**12 containers, `verify-dev` 20/20**). Everything salvageable has been pulled off the
980, including a 33G copy of its `ubuntu-backup` partition.

**What is still open:**
- **§4.1's `/var` → p3 move.** Deferred, not forgotten: p3 is formatted and empty and
  `/var` still lives on the 120G root. `/var/lib/docker` → p4 **is** done. Needs a
  reboot; see the revised §4.1 for doing it safely post-install.
- **§7's from-prod checks.** The prod box was powered off, so the 10GbE peer, the
  `prod-minikube` context and `verify-recovery.sh`'s dev probes are all **unverified
  end-to-end**. The dev-side config is correct and the watchdog is doing its job
  (bouncing a dead peer on schedule) — but "configured" is not "proven".
- **§8.1.** SATA still unplugged; see the health warning now at the top of that section.

⚠️ **Device names flipped when the new disk went in.** The 9100 PRO took `nvme0n1`; the
old 980 is `nvme1n1`. §0's table still uses the pre-fit names — read it as history.
Everywhere else in this doc, `nvme0n1` = the 9100 PRO.

The dev box is `vik@10.10.10.2` (10GbE /30 to prod) / `vik@192.168.50.161` (LAN OOB).
It matters to prod in three ways, all restored in §6: it serves **ollama to prod yolo**
(`10.10.10.2:11434`), it holds the **`prod-minikube` kube context** + `jenkins-deploy`
helper, and it runs the **10GbE link watchdog** on its end of the /30.

---

## 0. What is actually in the box (surveyed 2026-08-06)

| Component | Fact |
|---|---|
| Board | **ASUS ProArt Z890-CREATOR WIFI** (LGA1851 / Core Ultra "Arrow Lake", 24 threads) — **5× M.2: M.2_1 is CPU-attached PCIe 5.0 x4**, the other four are PCIe 4.0 |
| RAM / GPU | 64 GB; RTX 2080 Ti (driver 595.84) |
| `nvme0n1` *(now `nvme1n1`)* | **Samsung 980 1TB — the M.2 being replaced. It carries ONLY Ubuntu**: `p1` 465.8G ext4 `/` (283G used — no separate /home; 192G of it is `/home/vik`), `p3` 2M, `p4` 232.9G ext4 labelled `ubuntu-backup` (unmounted, not in fstab), ~233G unallocated |
| `sda` | Samsung 860 EVO 1TB **SATA** — **Windows lives here, entirely**: `sda1` 100M **the shared ESP** (holds BOTH `\EFI\MICROSOFT` and `\EFI\ubuntu`, and is Ubuntu's `/boot/efi`), `sda3` 441.6G Windows C:, `sda4`/`sda6` WinRE, `sda5` 488.3G NTFS "Stuffs" data |
| Boot | UEFI entries `ubuntu` (first) and `Windows Boot Manager` — **both pointing at sda1**, the SATA disk's ESP. **Secure Boot is ENABLED** (shim) |
| Swap | 2G swapfile on `/`, no zram |
| Network | `eno1` 10GbE = `10.10.10.2/30` static (NM "Wired connection 1"), MAC `bc:fc:e7:e7:4e:e5`; `eno2` LAN = 192.168.50.161 **via DHCP** (NM "Wired connection 3"), MAC `bc:fc:e7:e7:4e:e4` |
| Ollama | systemd service with three load-bearing overrides: waits for `eno1 10.10.10.2` before starting, **`OLLAMA_HOST=10.10.10.2:11434`** (prod yolo consumes this), `OLLAMA_MAX_LOADED_MODELS=2`; plus an **`ollama-warm.service`**. Models ≈ 4.8G in `/usr/share/ollama`: qwen2.5:0.5b, qwen2.5:7b-instruct, and **two custom local models** (`dyingpaleblue:latest`, `predictonomy:latest`) |
| Docker | Full IG-Trading-Microservices dev compose stack running (14 containers); 19.6G images + 11G build cache |
| Also | kube contexts `minikube` + `prod-minikube`; `~/bin/jenkins-deploy` + `~/.jenkins-deploy-urls.env`; go/node/java/kubectl installed; **gh/sops/age deliberately NOT installed** (dev box is sops-write-only by design); TZ Europe/London; no passwordless sudo |

**Three consequences that shape the whole plan:**

1. **Windows is untouched by this migration.** It does not live on the M.2 — swapping
   the 980 cannot break Windows. The only Ubuntu↔Windows coupling is the **shared ESP
   on the Windows disk** (`sda1`, a cramped 100M): today, Ubuntu's bootloader lives on
   Windows' drive. The fresh install deliberately breaks that coupling — the 9100 PRO
   gets its **own ESP**, so each disk becomes independently bootable and a future
   Windows reinstall/update can never eat Ubuntu's bootloader again (or vice versa).
2. **This board runs the 9100 PRO at full speed.** M.2_1 is CPU PCIe 5.0 x4 — the
   9100 PRO ([14,800/13,400 MB/s, 4TB has 4GB LPDDR4X DRAM, 2400 TBW, 5-yr warranty](https://download.semiconductor.samsung.com/resources/data-sheet/Samsung_NVMe_SSD_9100_PRO_with_Heatsink_Datasheet_Rev.2.0.pdf))
   is not slot-limited here, unlike the prod GM9000 on Z690. With **four free Gen4
   slots**, the old 980 stays in the machine as the rollback disk.
3. **Nothing backs up the dev box.** No cron, no archive, no NAS job (wd-backup moved
   to prod 2026-07-12). The surviving old disk **is** the entire safety net — treat it
   as read-only history and do not wipe it until weeks after everything works (§8).

---

## 0.5 Quick reference — every step in order

**A. Before swap day**
1. ☐ Push all repos (`~/IdeaProjects/*`); note/commit uncommitted work (§2.1).
2. ☐ Windows prep: save the **BitLocker recovery key** if C: is encrypted
   (`manage-bde -status` in an admin prompt), disable **Fast Startup** (§2.2).
3. ☐ Router: DHCP reservations — eno2 `bc:fc:e7:e7:4e:e4` → 192.168.50.161 (and prod's
   already-planned one) (§2.3).
4. ☐ Note prod impact window: dev ollama + the compose stack go dark during the
   migration; prod yolo's dev-ollama-backed features degrade until §6 completes (§2.4).
4c. ☐ **Partition the blank 9100 PRO from the still-running 24.04 system**:
   `sudo bash devbox-prep-9100pro.sh` (dry run) then `--commit` (§2.4c).

**B. Swap day**
5. Stop the compose stack cleanly; `sudo shutdown -h now` (§2.5).
6. ✅ *(done 2026-08-07)* 9100 PRO in M.2_1, 980 moved to a Gen4 slot. Remaining:
   **unplug the SATA (Windows) disk's data cable — that alone is sufficient** (§3).
7. BIOS: 9100 PRO detected at **PCIe 5.0 x4** ✅ *(verified)*; Secure Boot stays ON (§3).
8. Install **Ubuntu 26.04 LTS Desktop** ("Resolute Raccoon"). Advanced Partitioning:
   **assign** the pre-made partitions — `p1`→`/boot/efi`, `p2`→`/`, `p5`→`/home`;
   leave `p3`/`p4` unassigned. User `vik`, hostname `vik`, TZ Europe/London (§4).
8b. **Before leaving the live session**, migrate `/var` onto `p3` and add the `p3`/`p4`
   fstab lines (§4.1) — doing it here avoids moving `/var` out from under a running
   journald/dpkg on first boot.
9. Power off. Reconnect SATA. BIOS boot order: the NEW ubuntu entry (on the 9100 PRO)
   first (§4). *(The 980 stays where it is — no second M.2 handling.)*
10. First boot: updates; enable os-prober → `update-grub` picks up Windows (+ the old
    ubuntu as rollback) (§5.1).

**C. Rebuild (~half a day, mostly §5–§6)** — ✅ *all of C done 2026-08-07*
11. ✅ zram + docker-mount guard + NVIDIA driver (**no MOK prompt** — see §5.0)
    + docker + snaps/toolchain (§5). **Read §5.0 first — the 26.04 deltas are real and
    two of them fail silently.**
12. ✅ Mount the old 980 read-only; copy identity + config + data per the §6.1 list.
13. ✅ Ollama back exactly as it was: binary + the **four** systemd env overrides +
    `ollama-warm.service` + the model store (two models are custom-built — copy, don't
    re-pull) (§6.2).
14. ✅ 10GbE + prod wiring: eno1 static `10.10.10.2/30` profile, `devbox-connect-prod.sh
    all` + `install-unit`, `10gbe-link-watchdog.sh --install`. **Do NOT add any prod
    route to the eno2 profile** — that exact mistake once silently capped dev→prod at
    1GbE (§6.3). *(Config verified; the peer itself was down at the time — the prod box
    was off — so the end-to-end checks in §7 still owe a re-run.)*
15. ✅ Compose stack up (12 containers, verify-dev 20/20). §7's from-prod checks pending
    prod being powered on.
16. ☐ **Do §4.1's `/var` rsync + fstab line LAST, then reboot** — it is the one step
    that must not be interleaved with the installs above (§4.1).

**D. Weeks later**
17. Old 980: after the soak, EITHER clone **Windows onto it** (retiring the 2014-era
    SATA 860 EVO from OS duty — the recommended endgame; exact steps in **§8.1**:
    decrypt BitLocker → Magician clone → boot from 980 → reclaim the duplicated data
    partition → strip the 860 to data-only) OR wipe it as an Ubuntu scratch disk.
    Peek at its `ubuntu-backup` partition before destroying anything (§8).

**Rollback at any point:** BIOS boot menu → the OLD `ubuntu` entry (sda1 ESP → old root
on the 980, found by UUID — works from whichever M.2 slot the 980 sits in).

---

## 1. Design decisions (and rejected alternatives)

**Fresh Ubuntu on the 9100 PRO; Windows untouched on SATA — chosen.** The 980 carries
only Ubuntu, so this is a single-OS migration wearing a dual-boot costume. Fresh
install gets a clean partition scheme (the 980's is messy: no separate /home, a
233G unallocated hole, an orphaned `ubuntu-backup` partition), a decoupled ESP, and
none of years of config drift.

- *Rejected — clone the 980 onto the 9100 PRO*: carries the mess and the coupling
  along; you'd still be booting through the Windows disk's ESP.
- *Rejected — move Windows to the new 4TB too*: Windows is content where it is,
  reinstalling/cloning it now adds risk for zero benefit, and §8 gives it a better
  home later (the 980).

**Install first; stage NOTHING on the new disk beforehand — chosen.** The tempting
alternative is "partition the 9100 PRO now, copy everything across, install Ubuntu on
top". It is the wrong shape, and not merely because the installer would format the
staged files: **there is nothing to copy in advance.** Every byte of source data lives
on the 980, which stays in the machine and is readable read-only *after* the install —
which is exactly what §6.1 does. Staging first buys zero and adds a format risk.

- *But the partition TABLE is worth creating in advance* — a table is not data.
  `devbox-prep-9100pro.sh` (§2.4c) lays down the table below from the still-running
  24.04 system, formats and labels each partition, and applies `tune2fs -m 1`. The
  installer step then degrades from "type 1536 GiB into a GUI next to the disk holding
  your only backup" to "pick the partition labelled `home`". It also pre-creates the
  `/var` and `/var/lib/docker` partitions, which the desktop installer may refuse to
  accept as mount points (§4.1).

**Partition plan (all ext4), mirroring the prod philosophy at dev proportions:**

| # | Size | Mount | Why |
|---|------|-------|-----|
| 1 | 1 GiB | `/boot/efi` | **The 9100 PRO's own ESP** — the decoupling. |
| 2 | 120 GiB | `/` | OS + snaps. Root today is 283G only because home and docker live inside it; with those split out, ~40G of actual system gets 3× headroom. |
| 3 | 100 GiB | `/var` | Logs/journald/snapd, isolated from docker churn. |
| 4 | 400 GiB | `/var/lib/docker` | The compose dev stack (19.6G images + 11G buildkit today, 227 images accreted). Same lesson as prod: docker on its own filesystem can never fill the OS. |
| 5 | 1536 GiB | `/home` | The dev workhorse: 192G today (repos, IntelliJ, android SDK, go, caches) with room to stop thinking about it. |
| — | ~1.5 TiB | *free tail* | Future: datasets, VMs, growing partition 5, whatever. |

*(Arithmetic, corrected 2026-08-07: the disk is 3726 GiB; 1+120+100+400+1536 = 2157 GiB
allocated, leaving **1569 GiB ≈ 1.5 TiB** free — the doc previously said ~1.8T.)*

- **Swap:** `zram-tools` (`ALGO=zstd`, `PERCENT=35` ≈ 22G on 64G RAM) like prod, replacing
  the token 2G swapfile. No hibernation — it's a trap on dual-boot machines anyway.
- **Heatsink note:** the 9100 PRO comes in heatsink (`MZ-VAP4T0CW`, 8.8mm) and bare
  variants. M.2_1 sits under the board's own heatsink — use the **bare drive under the
  ASUS heatsink**, or remove the board's heatsink for that slot if you bought the
  Samsung-heatsink version. Gen5 drives throttle without one; don't run it naked.
- `tune2fs -m 1` on partitions 4 and 5; default `relatime`; weekly `fstrim.timer` is
  already on — no `discard` mount options.

---

## 2. Before swap day (on the running system)

**1. Push every repo.** Same sweep as prod:
```bash
for d in ~/IdeaProjects/*/; do [ -d "$d/.git" ] || continue
  s=$(git -C "$d" status --porcelain | wc -l); a=$(git -C "$d" rev-list --count @{u}..HEAD 2>/dev/null || echo '?')
  [ "$s$a" = "00" ] || echo "$s dirty, $a ahead: $d"; done
```
Uncommitted work survives on the old disk regardless, but pushed > salvaged.

*Sweep run 2026-08-06:* 12 repos dirty (mostly untracked/fork noise — fine), two need
real attention: **IG-Trading-Microservices had 1 unpushed commit** (`dae3755` —
**pushed 2026-08-06**, the repo's pre-push submodule-proto gate passing) and
**`ollama-dev` has NO git remote at all** (21 dirty files, 16G; copied into the
bundle — give it a private GitHub remote as a follow-up, it's load-bearing: the
ollama service PATH points into its quant-trainer venv).

**2. Windows prep (in Windows, once):** if C: is BitLocker-encrypted
(`manage-bde -status`), save the recovery key to your Microsoft account or paper —
BIOS boot-order changes can trip a recovery prompt. Turn OFF Fast Startup (Control
Panel → Power Options → "Choose what the power buttons do") so NTFS is never left
dirty-mounted while you're re-cabling disks.

**3. Router reservations:** eno2 `bc:fc:e7:e7:4e:e4` → 192.168.50.161 (keeps the OOB
address stable — prod's `verify-recovery.sh` probes it).

**3b. BitLocker: already verified OFF** (2026-08-06, from Linux — `sda3`/`sda5` probe
as plain `ntfs`, which an encrypted volume would not). Only the Fast Startup check in
§2.2 still needs a Windows boot.

**4. Plan the prod impact:** while the dev box is down, prod loses the dev ollama
endpoint (`10.10.10.2:11434`) and whatever consumes it degrades; the 10GbE watchdog on
prod will note the dead peer (that's it working). No prod action needed — everything
self-recovers when §6 completes.

**4b. Belt-and-braces bundle — done 2026-08-06.** Because the box has no backup and
the 980 gets physically handled, the small irreplaceables were pulled over the 10GbE
to **prod `/mnt/minikube-backups/migration-handoff-devbox/`**: `~/.ssh`, `.gitconfig`,
`.kube`, `.jenkins-deploy-urls.env`, `~/bin`, the ollama units (incl. the RESOLVED
`ollama-warm.service` symlink target), `/etc/fstab`, the eno1 NM profile dump, vik's
crontab, both MACs, the `dae3755` patch, the full ollama model store (~4.8G, incl.
the two custom models) and the remote-less `ollama-dev` repo (16G, venvs excluded).
The old disk remains the primary safety net; this covers the 980 dying in-hand.

**4c. Partition the blank 9100 PRO — from the still-running 24.04 system.** Per §1 this
is the one thing that IS safe to do in advance. `devbox-prep-9100pro.sh` is dry-run by
default and refuses to touch anything unless the target reports model
`Samsung SSD 9100 PRO 4TB`, has **zero** partitions, has nothing mounted, and is not
carrying the current `/`:

```bash
cd ~/IdeaProjects/step0
sudo bash devbox-prep-9100pro.sh              # prints the plan, changes nothing
sudo bash devbox-prep-9100pro.sh --commit     # then type ERASE at the prompt
lsblk -o NAME,SIZE,FSTYPE,LABEL /dev/nvme0n1  # expect ESP/ubuntu-root/ubuntu-var/docker/home
```
If a partition table already exists the script aborts rather than eat it — that is
deliberate; inspect and `sgdisk --zap-all` by hand if you really mean to start over.

**5. Shut down cleanly:**
```bash
cd ~/IdeaProjects/IG-Trading-Microservices && docker compose stop
sudo shutdown -h now
```
No pre-shutdown backup ritual here — unlike prod there is no archive to refresh; the
old disk itself, kept intact in a Gen4 slot, is the backup.

---

## 3. Hardware + BIOS (~20 min)

1. ~~Remove the **980 from M.2_1**~~ — **superseded 2026-08-07: leave the 980 in.**
   The original reasoning was "with it and the SATA disk absent, the installer can only
   put the ESP on the 9100 PRO". That is over-strong: **the 980 has no ESP** (it boots
   via `sda1` on the Windows disk), so unplugging SATA alone already guarantees the
   9100 PRO's ESP is the only one in the machine. Leaving the 980 fitted saves a
   case-open cycle before §6.1's 192G copy and makes it a GRUB rollback entry from
   first boot. The residual risk — a mis-click formatting it in the installer — is
   what §2.4c's pre-made, *labelled* partitions defend against: in the installer you
   only ever select partitions on `nvme0n1`, by label, never create one.
2. **Unplug the SATA data cable** of the 860 EVO (Windows). ← the one mandatory step.
   26.04's installer will happily [reuse an existing ESP](https://ubuntuhandbook.org/index.php/2026/04/how-to-install-ubuntu-26-04-desktop-edition-step-by-step/)
   when it finds one, which is the exact coupling this migration removes.
3. ✅ *(done)* 9100 PRO fitted in **M.2_1** (the CPU Gen5 slot) with a heatsink per §1;
   980 relocated to a Gen4 slot.
4. BIOS: confirm the drive links at **PCIe 5.0 x4** — ✅ verified from Linux
   (`cat /sys/bus/pci/devices/0000:01:00.0/current_link_speed` → `32.0 GT/s PCIe`,
   width 4, and `max_*` identical). Leave **Secure Boot ON** (the current Ubuntu
   already boots via shim; the fresh one will too); leave VMD/RAID settings as they
   are unless NVMe detection misbehaves.

---

## 4. Ubuntu install (~45 min)

**Ubuntu 26.04 LTS Desktop** ("Resolute Raccoon", released 2026-04-23) — a deliberate
change from the 24.04 this doc originally targeted: the box is being rebuilt from
scratch anyway, so it may as well land on the current LTS with its full 5-year (10 with
Pro) window rather than start two years into 24.04's. See §5.0 for what 26.04 changes.

> *Point-release note:* only `ubuntu-26.04-desktop-amd64.iso` is on releases.ubuntu.com
> as of 2026-08-07 — **26.04.1 is not out yet** (24.04.1 landed ~4 months after .0, so
> expect late August). If there is no schedule pressure, .1 is the conventional choice.
> On this hardware .0 is unlikely to bite; it is a judgement call, not a blocker.

Username **`vik`**, hostname **`vik`** (prod tooling — `verify-recovery.sh`, ssh
configs, the /30 — assumes this identity), timezone **Europe/London**.

**Partitioning: choose "Manual" / Advanced Partitioning and ASSIGN, never create.**
§2.4c already laid the table down. On `nvme0n1` (the only NVMe with an ESP, and the
only disk that should be visible besides the 980):

| Partition | Label | Do this |
|---|---|---|
| `nvme0n1p1` | `ESP` | mount `/boot/efi`, **format** (it is ours, not Windows') |
| `nvme0n1p2` | `ubuntu-root` | mount `/`, format ext4 |
| `nvme0n1p3` | `ubuntu-var` | **leave unassigned** — handled in §4.1 |
| `nvme0n1p4` | `docker` | **leave unassigned** — handled in §4.1 |
| `nvme0n1p5` | `home` | mount `/home`, format ext4 |

`p3`/`p4` are left out because the desktop installer's Advanced Partitioning tool
[offers a mount-point control that may not accept arbitrary paths](https://ubuntu.fan/en/docs/guide/installation/manual-partition)
like `/var/lib/docker`. Rather than discover that mid-install, do them in §4.1 — it is
two fstab lines and one rsync.

⚠️ **Do not touch `nvme1n1` (the 980) at any point in the installer.** It is the entire
backup and the source for §6.1.

### 4.1 `/var` and `/var/lib/docker` — before you reboot out of the live session

Do this **in the installer's live session immediately after the install finishes**, not
on first boot: `/var` is in use by journald/dpkg the moment the real system is running,
and moving it out from under them is needless faff. From the live USB:

```bash
# Identify the 9100 PRO first — device names are not guaranteed across boots, and the
# installer REFORMATTED p2, so `ubuntu-root` is gone as a label (p3/p4 keep theirs,
# they were left untouched). PARTLABEL survives regardless — use it to confirm.
lsblk -o NAME,SIZE,FSTYPE,LABEL,PARTLABEL /dev/nvme0n1
NEW=/dev/nvme0n1                                    # adjust if the above says otherwise

sudo mkdir -p /mnt/new /mnt/var
sudo mount ${NEW}p2 /mnt/new                        # the freshly installed root
sudo mount ${NEW}p3 /mnt/var                        # label `ubuntu-var`, still intact
sudo rsync -aHAX /mnt/new/var/ /mnt/var/            # trailing slashes matter
sudo mv /mnt/new/var /mnt/new/var.preinstall && sudo mkdir -m 755 /mnt/new/var
sudo mkdir -p /mnt/var/lib/docker                   # mountpoint for p4, empty for now

# fstab (UUIDs, not device names — device names are not the contract)
V=$(sudo blkid -s UUID -o value ${NEW}p3)
D=$(sudo blkid -s UUID -o value ${NEW}p4)
printf 'UUID=%s /var            ext4 defaults 0 2\n' "$V" | sudo tee -a /mnt/new/etc/fstab
printf 'UUID=%s /var/lib/docker ext4 defaults 0 2\n' "$D" | sudo tee -a /mnt/new/etc/fstab
tail -3 /mnt/new/etc/fstab                          # eyeball before unmounting
sudo umount /mnt/var /mnt/new
```
On first boot, `findmnt /var /var/lib/docker` must show both, then
`sudo rm -rf /var.preinstall` once you are satisfied.

*If you skip this and reboot first* — which is what actually happened on 2026-08-07 —
it is recoverable **without a live USB**, provided you get the ordering right. The two
partitions are not equally awkward:

- **`/var/lib/docker` (p4) is trivial and must be done FIRST**, before docker is ever
  installed: `sudo mkdir -p /var/lib/docker`, add the fstab line, `sudo mount
  /var/lib/docker`. Nothing holds the directory yet, so it just works — and every image
  and build-cache layer then lands on p4 from the first pull instead of filling the
  120G root.
- **`/var` (p3) is the one that can't be swapped live** (journald/snapd/dpkg hold it
  open), so it goes **LAST**: finish all installs and restores first, then
  `rsync -aHAX -x /var/ /mnt/newvar/` (the `-x` is what stops it descending into the p4
  mount), `mkdir -p /mnt/newvar/lib/docker`, add the fstab line, and reboot
  **immediately** — the only drift in that window is a few log lines.

Doing it this way needs no `var.preinstall` move: the original `/var` on root simply
sits shadowed under the new mount. Reclaim it later if you care (`mount -o bind` the
root device somewhere and delete), or leave it — it is a couple of GB on a 120G
partition.

**Then:** power off, reconnect the SATA disk, and set BIOS boot priority to the **new**
ubuntu entry (the one on the 9100 PRO — there will be TWO "ubuntu" entries; they're
distinguishable by disk in the BIOS boot menu). Verify after boot: `lsblk` shows all
three disks; **`findmnt /boot/efi` shows `/dev/nvme0n1p1`, NOT `sda1`** — that single
check is the whole ESP-decoupling goal of this migration.

---

## 5. Base system (~1 h)

### 5.0 What 26.04 changes vs the 24.04 this section was written for

Read this before running anything below — three of the four are silent-failure shaped.

- **`sudo` is now `sudo-rs`** (confirmed on the installed box: `sudo-rs 0.2.13-0ubuntu1`).
  ⚠️ **But the coreutils half of this bullet was WRONG** — corrected 2026-08-07 on the
  real install. `cp --version` reports **`cp (GNU coreutils) 9.7`**: the `rust-coreutils`
  (0.8.0) and `coreutils-from-uutils` packages *are* installed, but **GNU still provides
  `/usr/bin`**. So the [uutils-by-default claim](https://computingforgeeks.com/ubuntu-2604-rust-coreutils-guide/)
  did not hold here. Verify on your own box (`cp --version`) rather than assuming either
  way — the alternatives system can flip it.
  Using `rsync -aHAX` throughout §6.1 was still the right call, but for a better reason
  than the one originally given: see the read-error handling note in §8.1.
  Do still smoke-test the STEP0 units you install in §6.3 — ⚠️ **`devbox-connect-prod.sh
  route` really does fail under sudo-rs-era non-tty invocation**; details in §6.3.
- **Docker's apt repo has a `resolute` suite** — verified 2026-08-07 against
  `download.docker.com/linux/ubuntu/dists/`. `get.docker.com` works unmodified.
- **kubectl:** `pkgs.k8s.io` is distro-agnostic; no change.
- **NVIDIA:** 26.04 ships kernel 7.0 and the 2080 Ti is Turing — supported.
  ✅ *Resolved 2026-08-07, and both fears were wrong:*
  - **`ubuntu-drivers autoinstall` NO LONGER EXISTS** on 26.04 — the subcommand was
    removed; it is now **`sudo ubuntu-drivers install`** (`autoinstall` exits non-zero
    with `Error: No such command`). §5.4 is corrected below.
  - **No MOK enrollment, no blue screen.** The recommended driver is
    `nvidia-driver-595-open`, which 26.04 ships as a **prebuilt kernel module signed by
    the Canonical Ltd. Kernel Module Signing key** (already enrolled in the shim db) —
    **not** DKMS. `dkms` isn't even installed. `modinfo nvidia` shows
    `signer: Canonical Ltd. Kernel Module Signing`. Secure Boot stays on and nothing
    is asked of you.
  - Driver lands at **595.84** — the same version the old box ran.
  - `modprobe nvidia` fails with `No such device` until you reboot (nouveau still holds
    the card); that is expected, not a fault. After the reboot `nvidia-smi` prints the
    2080 Ti and `lspci -k` shows `Kernel driver in use: nvidia`.
- ⚠️ **The `go` and `node` SNAPS ARE STRICTLY CONFINED AND PRODUCE NO OUTPUT when run
  non-interactively** — the single nastiest 26.04 trap found during this migration.
  `/snap/bin/go version` from a script or an SSH/agent shell exits **0 with empty
  stdout** (`snap run go version` works; the shim doesn't). Anything that shells out to
  `go`/`node` therefore sees success and no data. This silently breaks
  IG-Trading-Microservices' `dockerup-dev.sh` pre-flight, which only tests
  `command -v go` and would have handed the build a mute compiler.
  **Consequence: do NOT use the `go`/`node` snaps.** §5.6 now installs Go into
  `/usr/local/go` from go.dev (which is what the repo's own pre-flight FIX text tells
  you anyway) and Node from **NodeSource** apt. The other snaps (IntelliJ, gradle,
  openjdk, slack, …) are classic or GUI apps and are unaffected.
- **npm 11 blocks package install scripts by default** (`npm warn allow-scripts`).
  `npm install -g grpc-tools` warns that `node-pre-gyp install` did not run — harmless
  here (the package ships the binaries), but if a global package ever comes up broken,
  that warning is why: re-run with `--allow-scripts=<pkg>`.
- **A `.venv` copied off the old disk is DEAD.** 24.04 was Python 3.12, 26.04 is
  **3.14**, so `IG-Trading-Microservices/.venv` imports nothing. Delete and recreate it
  (`python3 -m venv .venv && .venv/bin/pip install grpcio-tools==1.81.1` — the pin
  builds fine on 3.14). Same applies to any other venv §6.1 brings across.
- **os-prober is enabled by default** on 26.04 even with `GRUB_DISABLE_OS_PROBER`
  commented out — `update-grub` runs it and just prints a warning. Setting it to
  `false` explicitly (§5.1) is still worth doing so the intent is recorded.
- **Ollama's install script** and the systemd units copied off the old disk are
  distro-agnostic; unit syntax is stable across this jump. No change to §6.2.

**1. GRUB menu with Windows (+ rollback Ubuntu):**
```bash
sudo sed -i 's/^#GRUB_DISABLE_OS_PROBER.*/GRUB_DISABLE_OS_PROBER="false"/' /etc/default/grub
sudo update-grub   # picks up Windows Boot Manager (sda1) and the old ubuntu (980)
```

**2. zram + drop the swapfile habit:** `sudo apt install -y zram-tools`, set
`/etc/default/zramswap` to `ALGO=zstd` / `PERCENT=35`, restart `zramswap`.

**3. Docker-mount guard (same as prod §5.2):**
```bash
sudo mkdir -p /etc/systemd/system/docker.service.d
printf '[Unit]\nRequiresMountsFor=/var/lib/docker\n' | sudo tee /etc/systemd/system/docker.service.d/require-docker-mount.conf
```

**4. NVIDIA driver** — `sudo ubuntu-drivers install` (**not** `autoinstall`, removed in
26.04), reboot, `nvidia-smi` shows the 2080 Ti at 595.84. Secure Boot stays on and
there is **no MOK prompt** — see §5.0 for why.

**5. Docker:** `curl -fsSL https://get.docker.com | sudo sh && sudo usermod -aG docker vik`.
⚠️ **Mount `/var/lib/docker` (p4) BEFORE this step**, or every image and build-cache
layer lands on the 120G root and has to be moved later.

**6. Toolchain** (from the survey of what the box actually runs):

- **snaps** — `intellij-idea-ultimate --classic`, `intellij-idea-community --classic`,
  `openjdk`, `gradle --classic`, `slack`, `spotify`, `thunderbird`, `gimp`, `vlc`.
  ⚠️ **NOT `go` and NOT `node`** — see the confinement trap in §5.0.
- **Go** → `/usr/local/go` from go.dev:
  `V=$(curl -fsSL https://go.dev/VERSION?m=text|head -1); curl -fsSL -o /tmp/$V.tgz https://go.dev/dl/$V.linux-amd64.tar.gz && sudo rm -rf /usr/local/go && sudo tar -C /usr/local -xzf /tmp/$V.tgz`
- **Node** → NodeSource apt (`deb.nodesource.com/node_24.x nodistro main`).
- **apt** — `kubectl` (pkgs.k8s.io), `protobuf-compiler`, `jq`, `python3-venv`,
  `zram-tools`, `ethtool`, `nfs-common`.
- **npm -g** — `grpc-tools` (provides `grpc_tools_node_protoc`; installs into
  `~/.npm-global/bin` via the copied `.npmrc`, so that dir must be on PATH).
- The `protoc-gen-go` / `-go-grpc` / `-grpc-gateway` / `-openapiv2` plugins come across
  for free in §6.1's `~/go` copy — no `go install` needed.

Do NOT install gh/sops/age — their absence on the dev box is a deliberate security
property (sops-write-only from dev). The dev stack degrades gracefully without sops
(it falls back to `*.example` templates), and in a §6.1 restore it never needs to:
the real gitignored `.env` files come across with the repo copy.

⚠️ **`~/go/bin/go` is a stale go1.19 binary from 2022** that the old `.profile` put
*first* on PATH (`export PATH=$GOPATH/bin:$GOROOT/bin:$PATH` with
`GOROOT=$HOME/go/go1.19`). Every `go.mod` in IG-Trading-Microservices requires
**1.26.0**. Restoring that `.profile` verbatim therefore shadows the real compiler with
one seven years too old. Drop the `GOROOT`/go1.19 export, put `/usr/local/go/bin` ahead
of `$GOPATH/bin`, and rename `~/go/bin/go` out of the way.

---

## 6. Reconnect the world

### 6.1 Copy from the old disk (mount read-only)

**Use `rsync -aHAX`, not `cp -a`** — on 26.04 `cp` is uutils, not GNU (§5.0), and this
is the one bulk recursive copy in the whole migration. rsync is not part of coreutils.
The UUID below is device-name-proof (the old root is `nvme1n1p1` since the new disk
took `nvme0n1`) — verified still correct 2026-08-07.

```bash
sudo mkdir -p /mnt/old && sudo mount -o ro /dev/disk/by-uuid/46465bde-40e0-458b-a302-6d2e68604877 /mnt/old
O=/mnt/old/home/vik
R="rsync -aHAX"
$R $O/.ssh ~/ && chmod 700 ~/.ssh
$R $O/.gitconfig $O/.kube ~/                          # .kube carries BOTH contexts incl prod-minikube
$R $O/.jenkins-deploy-urls.env ~/ && chmod 600 ~/.jenkins-deploy-urls.env
mkdir -p ~/bin && $R $O/bin/jenkins-deploy ~/bin/
$R $O/.config/JetBrains ~/.config/ ; $R $O/.local/share/JetBrains ~/.local/share/
$R $O/android $O/go ~/                                # SDKs — cheaper to copy than re-download
$R $O/Documents $O/Desktop $O/Downloads ~/
$R $O/10gbe-link-watchdog.sh ~/                       # or take it fresh from STEP0
$R $O/.local/opt ~/.local/                            # OpenRGB AppImage (crontab uses it)
# vik's crontab is a single @reboot OpenRGB lights-off line — restore it straight
# off the old disk (or from the §2.4b bundle's text/vik-crontab.txt):
sudo cat /mnt/old/var/spool/cron/crontabs/vik | crontab -
```
**The curated list above is a good first pass but is NOT sufficient — finish with a full
sweep.** Working through it on 2026-08-07 and then diffing old-vs-new turned up ~40 more
top-level entries that matter, several of them irreplaceable:

- **`.config/sops/age/keys.txt`** — the dev-box age key. Easy to miss because §0 says
  "sops deliberately not installed": the *binary* is absent by design, the **key is
  not**, and without it `dev-env-sync.sh` can never materialise real secrets again.
- **Wallets** — `.config/Exodus` (13M) and `MultiDoge` (9.2M). Nothing else on the box
  is this unrecoverable.
- **`yolo-api-key.txt`**, `signal-desktop-keyring.gpg`, `.git-credentials` (chmod 600 —
  git over https has no key in `~/.ssh`, which holds only `authorized_keys` +
  `known_hosts`).
- **`.minikube`** (884M) — the local `minikube` kube context is inert without it.
- `.android` (4.3G AVDs — distinct from the `android` SDK dir), `.thunderbird`,
  `.mozilla`, `.config/Signal`, `.config/OpenRGB` (**the restored crontab drives it**),
  `.local/share/Steam`, `virtualenv`/`virtualenvs`/`pipx`/`jupyter`, `.m2`, `.gradle`,
  `.npmrc` (sets `prefix=~/.npm-global` — that bin dir must reach PATH), `.docker`,
  `.jdks`, `.codex`, `.hunter`, `.IT-Finance`, `wd-backup`, `yolo-e2e-audit`.

So rather than curate, take the lot and exclude the junk — one command, nothing missed:

```bash
sudo rsync -aHAX \
  --exclude='java_error_in_idea*' --exclude='*.hprof' --exclude='replay_pid*.log' \
  --exclude='.claude.json.backup.*' --exclude='.local/share/Trash' \
  --exclude='/.profile' --exclude='/.bashrc' --exclude='/IdeaProjects/step0' \
  /mnt/old/home/vik/ /home/vik/ && sudo chown -R vik:vik /home/vik
```

The `.profile`/`.bashrc` exclusions are the important ones — see the note at the end of
this section. (`java_error_in_idea.hprof` alone is 3.1G of IntelliJ heap dump.)

⚠️ **Close Chrome (and any app whose profile you are restoring) BEFORE the copy — and
verify it, don't assume it.** Chrome keeps `~/.config/google-chrome` open as live
LevelDB/SQLite; rsyncing over it while it runs leaves the on-disk profile and the
process's in-memory state disagreeing, and `--delete`/`--delete-after` will additionally
remove profile files the running browser has created. This bit on 2026-08-07 (Chrome was
up; 80 WhatsApp-Web IndexedDB `.ldb` files went missing). The fix is a clean restore with
the app **shut down**, which worked perfectly — 8.1G / 36,800 files, zero diffs:

```bash
pgrep -c chrome                     # must be 0 — check, don't assume
mv ~/.config/google-chrome ~/.config/google-chrome.pre-restore   # safety net
sudo rsync -aHAX --delete /mnt/old/home/vik/.config/google-chrome/ ~/.config/google-chrome/
sudo chown -R vik:vik ~/.config/google-chrome
rm -f ~/.config/google-chrome/Singleton{Lock,Socket,Cookie}      # stale locks from the old box
```
That last line matters: a copied profile carries `Singleton*` locks naming the old
machine/PID, and Chrome refuses to start on them. The same shut-it-down-first rule
applies to Thunderbird, Signal, Steam and the JetBrains IDEs.

Outside `$HOME`, also take **`/usr/local/bin/helm`** and **`/usr/local/bin/minikube`**
(the rest of that dir is 2022-era `docker-compose`/`node`/`kubectl` you now get from
apt). `/mnt/old/root/.ssh` is empty and `/etc/samba/smb.conf` is stock — neither needs
anything. `/opt` holds only installable apps (Chrome, Signal, Zoom, TeamViewer,
NordVPN); their *data* is in `~/.config`, which the sweep above already took.

**Repos: copy, don't re-clone.** The doc used to say "prefer fresh clones". In the real
restore that was the wrong call and the whole of `$O/IdeaProjects/` (52G) was rsynced
instead. Three reasons, all of which apply on any future run:
- every repo was **0 ahead** but many had dirty working trees (58 files in one) — a
  fresh clone silently discards all of it;
- **`ollama-dev` has no git remote at all** and is load-bearing (the ollama unit's PATH
  points into its `quant-trainer/.venv`);
- five entries aren't repos (`container-registry`, `Crypto-Mining`, `qcguy-cms`,
  `qcguy_CERTS`, `minikube-priv-cloud`, plus a pile of `.zip` archives).

The gitignored `*.env` / `.env.development` files ride along with the copy, which is
what lets the dev stack come up **without sops** (§5.6). Note the old checkout is
`~/IdeaProjects/step0` (lowercase) while a fresh clone gives `STEP0` — exclude the old
one and symlink, don't end up with both. Browser profiles (`$O/.mozilla`,
`$O/.config/google-chrome`) if wanted.

**`~/.profile` / `~/.bashrc` are NOT in the list above on purpose** — copying them
verbatim re-imports the stale go1.19 GOROOT (§5.6). Re-add by hand only what still
applies: `GOPATH`, `ANDROID_SDK_ROOT` + its `emulator`/`platform-tools` PATH entries,
`~/.npm-global/bin`, and `/usr/local/go/bin` **ahead of** `$GOPATH/bin`.

### 6.2 Ollama — exactly as it was, then prove it from prod

The unit's overrides are load-bearing (bind to `10.10.10.2`, wait for eno1, cap loaded
models) and two models are **custom local builds** that `ollama pull` cannot recreate.
`override.conf` carries **four** env vars, not the three listed in §0/§9 — the other two
are `OLLAMA_NUM_PARALLEL=1` and `OLLAMA_KEEP_ALIVE=-1` (the latter is what keeps the
warmed 7b resident in VRAM forever, so it is not cosmetic):

```bash
curl -fsSL https://ollama.com/install.sh | sh          # installs binary + base unit
sudo systemctl stop ollama
sudo rsync -aHAX /mnt/old/etc/systemd/system/ollama.service  /etc/systemd/system/   # full unit is custom too
sudo rsync -aHAX /mnt/old/etc/systemd/system/ollama.service.d /etc/systemd/system/
# ollama-warm.service is a SYMLINK into the ollama repo — clone wiqram/ollama first, then:
sudo ln -sf /home/vik/IdeaProjects/ollama/dev/ollama-warm.service /etc/systemd/system/ollama-warm.service
sudo rsync -a /mnt/old/usr/share/ollama/ /usr/share/ollama/    # ~4.8G model store, owner ollama:ollama
sudo chown -R ollama:ollama /usr/share/ollama
sudo systemctl daemon-reload && sudo systemctl enable --now ollama ollama-warm
OLLAMA_HOST=10.10.10.2:11434 ollama list                # expect qwen2.5 x2, dyingpaleblue, predictonomy
```
*(Do 6.3 first if eno1 has no address yet — the unit deliberately waits for it.)*
From **prod**: `curl -s http://10.10.10.2:11434/api/tags | jq '.models[].name'`.

### 6.3 10GbE + prod wiring

```bash
sudo nmcli con add type ethernet ifname eno1 con-name "10gbe-prod" \
  ipv4.method manual ipv4.addresses 10.10.10.2/30 autoconnect yes
sudo nmcli con up 10gbe-prod
# From the STEP0 repo (scp the two scripts from prod, or clone STEP0):
./devbox-connect-prod.sh route && ./devbox-connect-prod.sh test
sudo ./devbox-connect-prod.sh install-unit             # boot-check: route + ollama + kubectl heal
sudo ./10gbe-link-watchdog.sh --install                # auto-detects eno1/atlantic
kubectl --context prod-minikube get ns                 # the copied ~/.kube just works
```
⚠️ **The one bug not to reintroduce:** never add a prod-API or `10.10.10.x` route to
the **eno2** profile. A stray /32 on eno2 (metric 100 < eno1's) once sent all dev→prod
traffic over the 1GbE LAN silently — the "10GbE TX cap" incident. eno2 stays plain DHCP.

**Where the old profile actually lives (2026-08-07).** `/etc/NetworkManager/system-connections/`
on the old disk is **EMPTY** — do not conclude the config was lost. NM on this box uses
the **netplan keyfile backend**, so every profile is a
`/etc/netplan/90-NM-<uuid>.yaml`. The eno1 one (`name: "Wired connection 1"`) is the
authoritative record and is worth reading rather than retyping the values from memory:

```yaml
addresses: ["10.10.10.2/30"]
routes:  [{to: "172.16.238.2/32", via: "10.10.10.1"}]
passthrough: {ipv6.method: "disabled"}
```

So the `nmcli con add` above should also set `ipv4.routes "172.16.238.2/32 10.10.10.1"`,
`ipv4.never-default yes` and `ipv6.method disabled` — that single command then replaces
both it *and* `devbox-connect-prod.sh route`.

⚠️ **`devbox-connect-prod.sh route` calls plain `sudo` internally**, so it fails with
`sudo: A terminal is required to authenticate` from any non-tty context (a script, an
agent shell). `install-unit` and `10gbe-link-watchdog.sh --install` are fine because you
invoke *those* under sudo yourself. Run `route` from a real terminal, or just fold its
route into the `nmcli con add` as above and skip it.

### 6.4 Dev stack

**The entry point is `./dockerup-dev.sh`, not `docker compose up -d`** — there is no
plain `docker-compose.yml` in this repo; the script drives three compose files
(`robin_stocks/docker-compose-dev.yml`, `docker-compose-dev.yml`,
`docker-compose-dev-api-gateway.yml`), then seeds and runs `scripts/verify-dev.sh`.
Its pre-flight collects *all* toolchain misses in one pass, so run it once and read the
list. First run rebuilds everything — the 11G build cache is gone, expect a slow build.

Gaps a fresh 26.04 box hits, in the order the pre-flight reports them (2026-08-07):
`protoc` (apt `protobuf-compiler`), `grpc_tools_node_protoc` (`npm i -g grpc-tools`),
python `grpcio-tools` (**recreate the venv** — the copied one is 3.12, §5.0), and a
`go` that is really 1.26 (§5.6). `sops` is expected to be absent; the pre-flight warns
and falls back, and the real env files came over with the repo copy.

**Green looks like:** 12 containers and `[verify-dev] RESULT: 20 passed, 0 failed` —
containers ×12, gateway `/healthz`, login→JWT + an authed call, the postgres ledger
schema at 11 migrations, redis/mongo pings, robin_stocks gRPC on :8079, UI on :3000.
(§0's "14 containers" counted two transient `run --rm` helpers.)

---

## 7. Verification

- [ ] `findmnt /boot/efi` → **`/dev/nvme0n1p1`**, not `sda1` (the decoupled ESP — the
      headline goal); GRUB menu offers Windows; **Windows actually boots** via that
      entry and via the BIOS menu.
- [ ] `findmnt /var /var/lib/docker` → both on `nvme0n1p3`/`p4` (§4.1 took), and
      `/var.preinstall` removed.
- [ ] `sudo nvme list` / `lspci -vv` shows the 9100 PRO at Gen5 x4 (`LnkSta: 32GT/s x4`);
      a quick `dd if=/dev/zero of=~/t bs=1M count=8192 oflag=direct` writes multi-GB/s.
- [ ] 26.04 sanity: `lsb_release -a` → 26.04; `sudo --version` (sudo-rs) and
      `cp --version` (uutils) noted, and nothing in §5–§6 misbehaved because of them.
- [ ] `nvidia-smi` OK under Secure Boot (MOK enrolled).
- [ ] Compose stack: 14 containers up, UI reachable.
- [ ] Ollama from prod: `curl http://10.10.10.2:11434/api/tags` lists all four models.
- [ ] `./devbox-connect-prod.sh test` green; `kubectl --context prod-minikube get ns`;
      `jenkins-deploy <app>` fires (check Jenkins).
- [ ] `ping 10.10.10.1` over the /30; both watchdog + connect-prod units `active`;
      a large `scp` to prod sustains ~1 GB/s (proves no eno2 TX-cap regression).
- [ ] **From prod:** `./verify-recovery.sh` — its dev-box probes (OOB ssh, /30 route
      symmetry, ollama) all PASS again.
- [ ] Old ubuntu entry still boots from the 980 (rollback intact). Soak for 2 weeks.

---

## 8. Endgame for the old disks (weeks later)

**First, look before wiping:** mount the 980's `ubuntu-backup` partition
(`232.9G`, label `ubuntu-backup`) read-only and see what past-you stashed there.

✅ *Looked, 2026-08-07 — 35G used of 229G, all of it from 2022:* `vik/` (29G, a Jan-2022
home snapshot), `backup - IG-Trading-Microservices/` (6.2G, Jun 2022), `Coin Mining/`
(142M), `Nvidia 3080ti config/` (8K). Nothing current, but nothing reproducible either,
so it was copied to **`~/old-980-ubuntu-backup/`** on the new disk before the 980 was
touched — 35G against 1.4T free is not a trade worth thinking about. Delete it whenever
you've decided you don't want it; the point was to make the wipe reversible.

Then pick the 980's future:

- **Recommended — give Windows the NVMe it never had** (step-by-step in **§8.1**).
  The 860 EVO is a decade-old SATA drive doing OS duty; the 980 delivers ~95% of the
  perceptible jump from SATA (Windows' daily feel is bounded by low-QD random latency,
  where Gen3 and Gen5 NVMe are near-identical). End state: every OS on NVMe, each disk
  single-purpose, each with its own ESP.
  *Why not put Windows on the 9100 PRO instead?* Sharing it would re-share one ESP
  between the OSes (the exact coupling this migration removed) and cost ~450G of the
  dev disk's free tail for a difference you won't feel.
- **Simpler** — wipe the 980 → single ext4 → `/mnt/fast` Ubuntu scratch (emulators,
  datasets, build dirs).
- **Laziest** — shelve it untouched as the frozen pre-migration Ubuntu.

### 8.1 Moving Windows onto the 980 — step by step

> **This section runs AFTER the two-week soak, not before it.** Stated explicitly
> because "retire the old SSD that houses Windows" is the natural thing to want to do
> on the same day — and it is the one reordering that can lose data. The 980 is doing
> *two* jobs until the soak ends: it is the rollback boot **and** the source for
> everything §6.1 has not copied yet. Cloning Windows onto it destroys both at once.
> If the rebuild then turns out to be missing something, all that survives is the
> partial handoff bundle on prod (`/mnt/minikube-backups/migration-handoff-devbox/`) —
> which has ssh/kube/ollama/models but **not** the 192G home.

> ⚠️ **The 980 has failing media (measured 2026-08-07). Read this before committing.**
> SMART says `PASSED` and wear is only **4%**, but that is not the number that matters:
>
> | | 980 (`nvme1`) | 9100 PRO (`nvme0`) |
> |---|---|---|
> | Media and Data Integrity Errors | **172** | 0 |
> | Error log entries | **172**, all `Unrecovered Read Error` | 0 |
> | Available Spare | **91%** | 100% |
> | Percentage Used | 4% | 0% |
> | Unsafe shutdowns / time above warning temp | 243 / 6347 min | 1 / 0 |
>
> This is **failing media, not wear-out** — it has already burned 9% of the spare block
> pool, and it is observable rather than theoretical. Salvaging `ubuntu-backup` (`p4`)
> hit hard EIO on four files near LBA ~1.47G; those were all junk (2021 IntelliJ logs, a
> stub index, a Trash item).
>
> **The damage is NOT confined to `p4`.** An initial reading that it was got disproved by
> the full-home sweep, which lost a Steam `.vpk` *and* a 705 MB family video
> (`Desktop/Mama Phone London Trip Pics/`) — both on **`p1`, the root partition every
> §6.1 restore is sourced from**. The video was recovered to **99.84%** with
> `ddrescue -r5` (1077 kB bad over 11 areas; it still plays for its full 4m39s with brief
> glitches) — `rsync` had simply discarded it, because rsync's behaviour on a read error
> is to **fail the file and move on**, reporting only `exit 23` at the very end.
>
> **Therefore: never trust an rsync exit 0 off a suspect disk, and never wipe the source
> until you have read every byte of it.** Two habits, both cheap:
> ```bash
> # 1. enumerate every unreadable file BEFORE destroying the source
> sudo find /mnt/old -xdev -type f -size +0 -print0 \
>   | sudo xargs -0 -n1 -P8 sh -c 'dd if="$0" of=/dev/null bs=1M status=none 2>/dev/null \
>       || echo "UNREADABLE: $0"'
> # 2. recover each one rsync gave up on
> sudo ddrescue -r5 -b 4096 "$SRC" "$DST" "$DST.map"
> ```
> Check `smartctl -a` on the source disk at the *start* of any migration, not the end:
> `Media and Data Integrity Errors` and a sub-100% `Available Spare` are the two fields
> that predict this, and both were visible here all along.
>
> The consequence for this section is direct: §8.1's premise is "the 860 EVO is a
> decade-old SATA drive, give Windows something better." A drive with 172 uncorrected
> read errors and a shrinking spare pool is **not** better. If the goal is getting
> Windows off SATA, the honest options are a partition carved from the 9100 PRO's ~1.5T
> free tail, or a cheap healthy NVMe in one of the three remaining Gen4 slots.
> *(Proceeded anyway on 2026-08-07 — an explicit, informed decision, recorded here so the
> next reader doesn't mistake it for an oversight.)*

⚠️ **The `Windows Boot Manager` NVRAM entry disappears when the SATA disk is unplugged.**
After the fresh install with SATA out, `efibootmgr` lists exactly one OS entry —
`Ubuntu` on the 9100 PRO's own ESP — because both `sda1`-based entries (old `ubuntu`
*and* `Windows Boot Manager`) were pruned. On reconnecting the disk Windows will **not**
be in the boot order; reach it from the BIOS boot menu, which enumerates
`\EFI\Microsoft\Boot\bootmgfw.efi` directly, or recreate it with
`efibootmgr -c -d /dev/sda -p 1 -L "Windows Boot Manager" -l '\EFI\Microsoft\Boot\bootmgfw.efi'`.
This is cosmetic NVRAM state, **not** a damaged Windows install — don't start repairing
things. (It also means step 9's "clean the dangling NVRAM entries" is already done for
you.)

**Prerequisites — all four, no exceptions:**
1. The §7 soak is signed off. **Wiping the 980 deletes the Ubuntu rollback** — this is
   the step where the migration becomes final.
2. The 980's `ubuntu-backup` partition has been peeked at and anything wanted salvaged.
3. **BitLocker fully decrypted.** In an admin prompt: `manage-bde -status C:` — if it
   shows encrypted, run `manage-bde -off C:` and wait for "Fully Decrypted" (this can
   take an hour+; the clone tools below cannot read a locked volume). Re-encrypt at
   the end if wanted.
4. Fast Startup still OFF (§2.2) and Windows fully shut down before any disk surgery —
   a hibernated NTFS clone is a corrupted clone.

**Clone (Path 1 — Samsung Magician, recommended):**

5. Boot Windows, install/open **Samsung Magician → Data Migration**. Source = the
   860 EVO, target = the 980 (Samsung targets are exactly what this tool exists for).
   It clones the whole source disk — ESP, MSR, C:, both recovery partitions, **and the
   "Stuffs" data partition rides along**; that's fine, it gets dealt with in step 8.
   Start the clone (~1 h for ~900G). Everything previously on the 980 is destroyed.
6. Shut down. In BIOS, pick the **Windows Boot Manager entry on the 980** (there are
   briefly two — distinguish by disk). Verify inside Windows that C: now lives on
   "Samsung SSD 980" (Disk Management, or `diskpart` → `list disk`).
7. **Do step 9's source cleanup promptly** — the clone copied the GPT verbatim, so two
   disks now carry identical partition GUIDs and identical Windows installs; running
   that way long-term invites boot-entry confusion.

**Reclaim the duplicated data partition on the 980:**

8. The cloned layout mirrors the source: `ESP | MSR | C: | WinRE | Stuffs | rec`.
   Delete the cloned **Stuffs** copy from the 980 (Disk Management — triple-check
   you're on the 980; the real Stuffs stays on the 860 EVO). Note the freed ~488G is
   **not adjacent to C:** (WinRE sits between), so plain Disk Management cannot extend
   C: into it. Two options:
   - *Zero-risk:* format the freed space as a new NTFS `D:` and use it as a second
     Windows volume. Done.
   - *Polish:* from Ubuntu, use GParted to slide the small WinRE partition (~952M)
     left and then grow C: — safe with BitLocker off (GParted moves preserve the
     partition GUIDs the Windows BCD references), but it's an hour of partition
     surgery for a tidier layout. Afterwards in Windows check `reagentc /info` and
     `reagentc /enable` if WinRE went disabled.

**Retire the 860 EVO to data-only:**

9. From Ubuntu: delete `sda1` (old shared ESP), `sda2`, `sda3` (old C:), `sda4` and
   `sda6` (old recovery) — **keep `sda5` "Stuffs"**. Then clean the dangling NVRAM
   entries: `sudo efibootmgr` and `-b XXXX -B` the old `Windows Boot Manager` and old
   `ubuntu` entries that pointed at sda1. Finally `sudo update-grub` — os-prober now
   finds Windows on the 980's own ESP and the GRUB menu keeps working.
   The freed ~443G sits *before* Stuffs on the disk; rather than moving a 488G NTFS
   partition, just create a new partition there (ext4 scratch for Ubuntu, or NTFS).
10. Optional: re-enable BitLocker (`manage-bde -on C:`) and **save the new recovery
    key**. Windows activation is unaffected throughout — the motherboard (what the
    digital license is tied to) never changed.

**Fallback (Path 2)** if Magician refuses the clone: boot a Clonezilla USB and do a
disk-to-disk clone (860 EVO → 980, both 931.5G so sizes match), then continue from
step 6 — the same duplicate-GPT caution in step 7 applies even more strongly.
Last resort is the fully manual route (partition by hand, `ntfsclone` C:, rebuild the
BCD with `bcdboot` from a Windows installer USB's Shift+F10 prompt) — workable but
only worth it if both tools fail.

**And close the backup gap** this migration exposed: the dev box still has no backup.
Minimum viable: a nightly `rsync` of `~/` to prod's WD Cloud share or the prod box
(prod is always on; the 10GbE makes it free). Worth a follow-up task rather than a
skipped thought.

---

## 9. Appendix — facts card (surveyed 2026-08-06, re-verified 2026-08-07)

| Fact | Value |
|---|---|
| Identity | host `vik`, user `vik`, TZ Europe/London, Ubuntu 24.04.4 → **26.04 LTS** (kernel 7.0.0-29, Python 3.14), Secure Boot ON, **no passwordless sudo** |
| Post-rebuild versions | NVIDIA **595.84** (`nvidia-driver-595-open`, prebuilt + Canonical-signed, no DKMS), Docker **29.7.2**, kubectl **1.34.10**, Go **1.26.5** (`/usr/local/go`), Node **24.19.0** (NodeSource), ollama **0.32.6** |
| New disk layout | `nvme0n1` p1 ESP 1G → `/boot/efi` · p2 120G → `/` · p3 100G `ubuntu-var` → `/var` · p4 400G `docker` → `/var/lib/docker` · p5 1.5T `home` → `/home` · ~1.5T free tail |
| Board / slots | ProArt Z890-CREATOR WIFI; M.2_1 = CPU **Gen5 x4** (→ 9100 PRO), 4× Gen4 (→ old 980) |
| **New M.2 (2026-08-07)** | `nvme0n1` Samsung 9100 PRO 4TB, blank, PCI `0000:01:00.0` off CPU root port `00:01.0` = M.2_1; `current_link_speed` = `max_link_speed` = **32.0 GT/s ×4 (Gen5 ×4)**. 3726 GiB usable |
| Old M.2 | Samsung 980 1TB (**now `nvme1n1`**, Gen3 ×4): Ubuntu `/` 465.8G (283G used), `ubuntu-backup` 232.9G unmounted, ~233G unallocated. Root UUID `46465bde-40e0-458b-a302-6d2e68604877`, `ubuntu-backup` UUID `f4e3825c-768f-4ea8-b776-5adb9c18e27a` |
| Windows disk | 860 EVO 1TB SATA: shared ESP (100M) + C: 441.6G + WinRE ×2 + "Stuffs" 488.3G NTFS |
| NICs | eno1 10GbE `bc:fc:e7:e7:4e:e5` = 10.10.10.2/30 static; eno2 LAN `bc:fc:e7:e7:4e:e4` = .161 DHCP |
| Ollama | `OLLAMA_HOST=10.10.10.2:11434`, waits for eno1, `MAX_LOADED_MODELS=2`, `NUM_PARALLEL=1`, `KEEP_ALIVE=-1`, + `ollama-warm.service`; models: qwen2.5:0.5b, qwen2.5:7b-instruct, dyingpaleblue (custom), predictonomy (custom). Unit `PATH` points into `~/IdeaProjects/ollama-dev/quant-trainer/.venv/bin`, and `ollama-warm.service` is a symlink to `~/IdeaProjects/ollama/dev/ollama-warm.service` — **both repos must exist before `systemctl enable`** |
| Docker | compose dev stack (IG-Trading-Microservices, 14 containers), 19.6G images, 11G buildkit |
| Prod touch-points | ollama endpoint, `prod-minikube` context, `~/bin/jenkins-deploy` + `~/.jenkins-deploy-urls.env`, watchdog + connect-prod units |
| 9100 PRO 4TB | PCIe 5.0 x4, 14,800/13,400 MB/s, 4GB LPDDR4X DRAM, 2400 TBW, 5-yr ([datasheet](https://download.semiconductor.samsung.com/resources/data-sheet/Samsung_NVMe_SSD_9100_PRO_with_Heatsink_Datasheet_Rev.2.0.pdf), [Samsung announcement](https://news.samsung.com/us/samsung-announces-9100-pro-series-ssds-with-breakthrough-pcie-5-0-performance/)) |
| Board source | [ASUS ProArt Z890-CREATOR WIFI](https://www.asus.com/us/motherboards-components/motherboards/proart/proart-z890-creator-wifi/) ([review confirming 1× Gen5 + 4× Gen4 M.2](https://www.tweaktown.com/reviews/11230/asus-proart-z890-creator-wifi-motherboard/index.html)) |
| Ubuntu 26.04 | "Resolute Raccoon", released 2026-04-23 ([release notes](https://documentation.ubuntu.com/release-notes/26.04/), [Canonical announcement](https://canonical.com/blog/canonical-releases-ubuntu-26-04-lts-resolute-raccoon)). Defaults: sudo-rs 0.2.13, uutils coreutils 0.8.0 ([guide](https://computingforgeeks.com/ubuntu-2604-rust-coreutils-guide/)). 26.04.1 not yet released as of 2026-08-07 |
| Helper script | [`devbox-prep-9100pro.sh`](./devbox-prep-9100pro.sh) — lays down the §1 partition table on the blank 9100 PRO (§2.4c). Dry-run by default |
