# DEVBOX-9100PRO-MIGRATION.md — dev box M.2 swap to a Samsung 9100 PRO 4TB

Runbook for replacing the dev box's M.2 (Samsung 980 1TB) with a **Samsung 9100 PRO
4TB**, fresh-installing Ubuntu, and rewiring the dev↔prod integration. Companion to
[`GM9000-MIGRATION.md`](./GM9000-MIGRATION.md) (the prod-box OS-disk swap). Written
2026-08-06 from a live SSH survey of the box.

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
| `nvme0n1` | **Samsung 980 1TB — the M.2 being replaced. It carries ONLY Ubuntu**: `p1` 465.8G ext4 `/` (283G used — no separate /home; 192G of it is `/home/vik`), `p3` 2M, `p4` 232.9G ext4 labelled `ubuntu-backup` (unmounted, not in fstab), ~233G unallocated |
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

**B. Swap day**
5. Stop the compose stack cleanly; `sudo shutdown -h now` (§2.5).
6. Remove the 980 from M.2_1 → set it aside. Fit the **9100 PRO into M.2_1**. Unplug
   the SATA (Windows) disk's data cable (§3).
7. BIOS: 9100 PRO detected at **PCIe 5.0 x4**; Secure Boot stays ON (§3).
8. Install **Ubuntu 24.04.x Desktop**, manual partitioning per §4: ESP 1G · `/` 120G ·
   `/var` 100G · `/var/lib/docker` 400G · `/home` 1.5T · ~1.8T free. User `vik`,
   hostname `vik`, TZ Europe/London (§4).
9. Power off. Reconnect SATA; fit the **980 into any Gen4 M.2 slot**. BIOS boot order:
   the NEW ubuntu entry (on the 9100 PRO) first (§4).
10. First boot: updates; enable os-prober → `update-grub` picks up Windows (+ the old
    ubuntu as rollback) (§5.1).

**C. Rebuild (~half a day, mostly §5–§6)**
11. zram + docker-mount guard + NVIDIA driver (MOK prompt possible — Secure Boot is on)
    + docker + snaps/toolchain (§5).
12. Mount the old 980 read-only; copy identity + config + data per the §6.1 list.
13. Ollama back exactly as it was: binary + the three systemd overrides +
    `ollama-warm.service` + the model store (two models are custom-built — copy, don't
    re-pull) (§6.2).
14. 10GbE + prod wiring: eno1 static `10.10.10.2/30` profile, `devbox-connect-prod.sh
    all` + `install-unit`, `10gbe-link-watchdog.sh --install`. **Do NOT add any prod
    route to the eno2 profile** — that exact mistake once silently capped dev→prod at
    1GbE (§6.3).
15. Compose stack up; verify list §7 (including the from-prod checks).

**D. Weeks later**
16. Old 980: after the soak, EITHER clone **Windows onto it** (retiring the 2014-era
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

**Partition plan (all ext4), mirroring the prod philosophy at dev proportions:**

| # | Size | Mount | Why |
|---|------|-------|-----|
| 1 | 1 GiB | `/boot/efi` | **The 9100 PRO's own ESP** — the decoupling. |
| 2 | 120 GiB | `/` | OS + snaps. Root today is 283G only because home and docker live inside it; with those split out, ~40G of actual system gets 3× headroom. |
| 3 | 100 GiB | `/var` | Logs/journald/snapd, isolated from docker churn. |
| 4 | 400 GiB | `/var/lib/docker` | The compose dev stack (19.6G images + 11G buildkit today, 227 images accreted). Same lesson as prod: docker on its own filesystem can never fill the OS. |
| 5 | 1.5 TiB | `/home` | The dev workhorse: 192G today (repos, IntelliJ, android SDK, go, caches) with room to stop thinking about it. |
| — | ~1.8 TiB | *free tail* | Future: datasets, VMs, growing partition 5, whatever. |

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

**2. Windows prep (in Windows, once):** if C: is BitLocker-encrypted
(`manage-bde -status`), save the recovery key to your Microsoft account or paper —
BIOS boot-order changes can trip a recovery prompt. Turn OFF Fast Startup (Control
Panel → Power Options → "Choose what the power buttons do") so NTFS is never left
dirty-mounted while you're re-cabling disks.

**3. Router reservations:** eno2 `bc:fc:e7:e7:4e:e4` → 192.168.50.161 (keeps the OOB
address stable — prod's `verify-recovery.sh` probes it).

**4. Plan the prod impact:** while the dev box is down, prod loses the dev ollama
endpoint (`10.10.10.2:11434`) and whatever consumes it degrades; the 10GbE watchdog on
prod will note the dead peer (that's it working). No prod action needed — everything
self-recovers when §6 completes.

**5. Shut down cleanly:**
```bash
cd ~/IdeaProjects/IG-Trading-Microservices && docker compose stop
sudo shutdown -h now
```
No pre-shutdown backup ritual here — unlike prod there is no archive to refresh; the
old disk itself, kept intact in a Gen4 slot, is the backup.

---

## 3. Hardware + BIOS (~20 min)

1. Remove the **980 from M.2_1** and set it aside (do NOT install it yet — with it and
   the SATA disk absent, the installer can only put the ESP on the 9100 PRO).
2. Unplug the **SATA data cable** of the 860 EVO (Windows).
3. Fit the **9100 PRO into M.2_1** (the CPU Gen5 slot) with a heatsink per §1.
4. BIOS: confirm the drive links at **PCIe 5.0 x4**; leave **Secure Boot ON** (the
   current Ubuntu already boots via shim; the fresh one will too); leave VMD/RAID
   settings as they are unless NVMe detection misbehaves.

---

## 4. Ubuntu install (~45 min)

**Ubuntu 24.04.x LTS Desktop** (matches the box today and every script that touches
it). "Something else" manual partitioning per the §1 table on the only visible disk.
Username **`vik`**, hostname **`vik`** (prod tooling — `verify-recovery.sh`, ssh
configs, the /30 — assumes this identity), timezone **Europe/London**.

After first boot + `sudo apt update && sudo apt full-upgrade -y`: power off, reconnect
the SATA disk, fit the **980 into any Gen4 M.2 slot**, and set BIOS boot priority to
the **new** ubuntu entry (the one on the 9100 PRO — there will be TWO "ubuntu" entries;
they're distinguishable by disk in the BIOS boot menu). Verify after boot:
`lsblk` shows all three disks; `findmnt /boot/efi` shows the 9100 PRO's partition 1,
NOT `sda1`.

---

## 5. Base system (~1 h)

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

**4. NVIDIA driver** (Secure Boot is ON — if the installer offers MOK enrollment,
set the one-time password and complete the blue-screen enrollment on reboot):
`sudo ubuntu-drivers autoinstall`, reboot, `nvidia-smi` shows the 2080 Ti.

**5. Docker:** `curl -fsSL https://get.docker.com | sudo sh && sudo usermod -aG docker vik`.

**6. Toolchain** (from the survey of what the box actually runs): snaps
`intellij-idea-ultimate --classic`, `intellij-idea-community --classic`, `go --classic`,
`node --classic`, `openjdk`, `gradle --classic`, `slack`, `spotify`, `thunderbird`,
`gimp`, `vlc`; apt `kubectl` (or copy the binary), plus whatever §6.1 brings over.
Do NOT install gh/sops/age — their absence on the dev box is a deliberate security
property (sops-write-only from dev).

---

## 6. Reconnect the world

### 6.1 Copy from the old disk (mount read-only)

```bash
sudo mkdir -p /mnt/old && sudo mount -o ro /dev/disk/by-uuid/46465bde-40e0-458b-a302-6d2e68604877 /mnt/old
O=/mnt/old/home/vik
cp -a $O/.ssh ~/ && chmod 700 ~/.ssh
cp -a $O/.gitconfig $O/.kube ~/                       # .kube carries BOTH contexts incl prod-minikube
cp -a $O/.jenkins-deploy-urls.env ~/ && chmod 600 ~/.jenkins-deploy-urls.env
mkdir -p ~/bin && cp -a $O/bin/jenkins-deploy ~/bin/
cp -a $O/.config/JetBrains $O/.local/share/JetBrains ~/.config/ ~/.local/share/ 2>/dev/null
cp -a $O/android $O/go ~/ 2>/dev/null                 # SDKs — cheaper to copy than re-download
cp -a $O/Documents $O/Desktop $O/Downloads ~/ 2>/dev/null
cp -a $O/10gbe-link-watchdog.sh ~/                    # or take it fresh from STEP0
```
Repos: prefer **fresh clones** into `~/IdeaProjects` (push happened in §2.1); copy any
directory that had uncommitted work from `$O/IdeaProjects/` instead. Browser profiles
(`$O/.mozilla`, `$O/.config/google-chrome`) if wanted.

### 6.2 Ollama — exactly as it was, then prove it from prod

The unit's overrides are load-bearing (bind to `10.10.10.2`, wait for eno1, cap loaded
models) and two models are **custom local builds** that `ollama pull` cannot recreate:

```bash
curl -fsSL https://ollama.com/install.sh | sh          # installs binary + base unit
sudo systemctl stop ollama
sudo cp -a /mnt/old/etc/systemd/system/ollama.service.d /etc/systemd/system/
sudo cp -a /mnt/old/etc/systemd/system/ollama-warm.service /etc/systemd/system/ 2>/dev/null
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

### 6.4 Dev stack

`cd ~/IdeaProjects/IG-Trading-Microservices && docker compose up -d` (first run
rebuilds images — the 11G build cache is gone, expect a slow first build), same for any
other compose-based app you actively develop.

---

## 7. Verification

- [ ] `findmnt /boot/efi` → the 9100 PRO partition (decoupled ESP); GRUB menu offers
      Windows; **Windows actually boots** via that entry and via the BIOS menu.
- [ ] `sudo nvme list` / `lspci -vv` shows the 9100 PRO at Gen5 x4 (`LnkSta: 32GT/s x4`);
      a quick `dd if=/dev/zero of=~/t bs=1M count=8192 oflag=direct` writes multi-GB/s.
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

## 9. Appendix — facts card (surveyed 2026-08-06)

| Fact | Value |
|---|---|
| Identity | host `vik`, user `vik`, TZ Europe/London, Ubuntu 24.04.4, Secure Boot ON |
| Board / slots | ProArt Z890-CREATOR WIFI; M.2_1 = CPU **Gen5 x4** (→ 9100 PRO), 4× Gen4 free (→ old 980) |
| Old M.2 | Samsung 980 1TB: Ubuntu `/` 465.8G (283G used), `ubuntu-backup` 232.9G unmounted, ~233G unallocated. Root UUID `46465bde-40e0-458b-a302-6d2e68604877` |
| Windows disk | 860 EVO 1TB SATA: shared ESP (100M) + C: 441.6G + WinRE ×2 + "Stuffs" 488.3G NTFS |
| NICs | eno1 10GbE `bc:fc:e7:e7:4e:e5` = 10.10.10.2/30 static; eno2 LAN `bc:fc:e7:e7:4e:e4` = .161 DHCP |
| Ollama | `OLLAMA_HOST=10.10.10.2:11434`, waits for eno1, MAX_LOADED_MODELS=2, + `ollama-warm.service`; models: qwen2.5:0.5b, qwen2.5:7b-instruct, dyingpaleblue (custom), predictonomy (custom) |
| Docker | compose dev stack (IG-Trading-Microservices, 14 containers), 19.6G images, 11G buildkit |
| Prod touch-points | ollama endpoint, `prod-minikube` context, `~/bin/jenkins-deploy` + `~/.jenkins-deploy-urls.env`, watchdog + connect-prod units |
| 9100 PRO 4TB | PCIe 5.0 x4, 14,800/13,400 MB/s, 4GB LPDDR4X DRAM, 2400 TBW, 5-yr ([datasheet](https://download.semiconductor.samsung.com/resources/data-sheet/Samsung_NVMe_SSD_9100_PRO_with_Heatsink_Datasheet_Rev.2.0.pdf), [Samsung announcement](https://news.samsung.com/us/samsung-announces-9100-pro-series-ssds-with-breakthrough-pcie-5-0-performance/)) |
| Board source | [ASUS ProArt Z890-CREATOR WIFI](https://www.asus.com/us/motherboards-components/motherboards/proart/proart-z890-creator-wifi/) ([review confirming 1× Gen5 + 4× Gen4 M.2](https://www.tweaktown.com/reviews/11230/asus-proart-z890-creator-wifi-motherboard/index.html)) |
