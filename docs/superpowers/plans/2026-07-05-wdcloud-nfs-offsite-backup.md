# WD Cloud (NFS) Off-site Backup Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Replace the off-site backup target from GCS Coldline with the WD Cloud 6TB NAS (`192.168.50.169`) over NFS, keeping GCS as a commented fallback and updating the DR restore path + docs.

**Architecture:** `backup-minikube-mnt.sh`'s off-site block becomes a guarded `cp` to a persistent NFS mount (`/mnt/wdcloud`) plus the same month-retention prune minus the Coldline 90-day floor. `restore-scratch.sh` pulls the latest archive from that mount instead of `gcloud`. The GCS code is retained commented-out. The WD volume is formatted once, manually, in the WD dashboard (not scripted).

**Tech Stack:** Bash, NFS (`nfs-common`), WD My Cloud. No test framework in this repo — verification is `bash -n` + a live dry-run against the mounted WD.

**Spec:** `docs/superpowers/specs/2026-07-05-wdcloud-nfs-offsite-backup-design.md`

---

### Task 1: Replace off-site block in `backup-minikube-mnt.sh`

**Files:**
- Modify: `backup-minikube-mnt.sh:122-231` (the entire GCS off-site section)

- [ ] **Step 1: Replace the GCS section header + code with the WD NFS block**

Replace everything from line 122 (`##############################################` opening the
"Off-site copy to Google Cloud Storage (Coldline)" band) through the final `fi` on line 231
with the block below. Note `hostname` and `prev_ym` are already defined earlier in the script
(lines 50 and 86) and are reused here.

```bash
##############################################
#
# Off-site copy to the WD Cloud 6TB NAS (LAN, over NFS).
#
# Copies THIS run's archive (already a .tgz) to the WD Cloud, mounted at
# $WD_MOUNT, then prunes that share with the SAME month retention as the local
# prune above. No age floor: it is our own disk, so deletes are always free
# (unlike Coldline's 90-day minimum-storage duration — see the disabled GCS
# fallback below).
#
# Entirely additive + guarded: if the WD mount is absent/unwritable (NAS off,
# network down, not yet mounted) it only WARNs to the cron log — it never aborts
# or touches the local backup above.
#
# ---- ONE-TIME SETUP (operator; the WD is a NAS appliance, not a local disk) ----
#   # 0. FORMAT the 6TB volume ONCE via the WD My Cloud web dashboard
#   #    (Settings -> Utilities -> Format Volume / Full Factory Restore), then
#   #    enable/create the NFS share this points at. NOT scriptable from here.
#   # 1. Install the NFS client and confirm the export path:
#   sudo apt-get install -y nfs-common
#   showmount -e 192.168.50.169
#   # 2. Persistent, boot-safe mount (nofail+soft => a dark NAS never blocks boot):
#   sudo mkdir -p /mnt/wdcloud
#   #   add to /etc/fstab (replace <WD_EXPORT> with the path from showmount):
#   #   192.168.50.169:<WD_EXPORT>  /mnt/wdcloud  nfs  _netdev,nofail,soft,timeo=150,retrans=3,x-systemd.automount  0 0
#   sudo mount /mnt/wdcloud && mkdir -p /mnt/wdcloud/private-cloud
##############################################
WD_HOST="192.168.50.169"                 # WD Cloud 6TB on the LAN
WD_EXPORT="__CONFIRM_WITH_showmount_-e_192.168.50.169__"   # informational; mount is via /etc/fstab
WD_MOUNT="/mnt/wdcloud"                   # persistent NFS mount (see setup above)
WD_DEST="$WD_MOUNT/private-cloud"         # archives live here

echo
echo "Off-site: copying $archive_file to $WD_DEST (WD Cloud, NFS)"

if ! mountpoint -q "$WD_MOUNT"; then
    echo "WARNING: $WD_MOUNT is not mounted — skipping off-site WD backup. See setup notes above." >&2
elif ! mkdir -p "$WD_DEST" 2>/dev/null || [ ! -w "$WD_DEST" ]; then
    echo "WARNING: $WD_DEST missing/unwritable — skipping off-site WD backup." >&2
else
    if cp "$dest/$archive_file" "$WD_DEST/"; then
        echo "Off-site copy OK: $WD_DEST/$archive_file"
    else
        echo "WARNING: off-site copy of $archive_file to $WD_DEST failed." >&2
    fi

    # --- WD prune: same month retention as local, NO age floor (our own disk). ---
    echo "Pruning $WD_DEST (keep weekly for current + previous month, one per older month)"
    declare -A wd_latest_day
    declare -A wd_latest_file

    # Pass 1: for older months, find the most recent (highest-day) backup per month.
    for f in "$WD_DEST/$hostname"-*.tgz; do
        [ -e "$f" ] || continue
        base=$(basename "$f")
        [[ "$base" =~ ^${hostname}-([0-9]{2})-([0-9]{2})-([0-9]{2})\.tgz$ ]] || continue
        mm="${BASH_REMATCH[1]}"; dd="${BASH_REMATCH[2]}"; yy="${BASH_REMATCH[3]}"
        ym="$yy$mm"
        [ "$ym" -ge "$prev_ym" ] && continue
        if [ -z "${wd_latest_day[$ym]}" ] || [ "$dd" -gt "${wd_latest_day[$ym]}" ]; then
            wd_latest_day[$ym]="$dd"
            wd_latest_file[$ym]="$f"
        fi
    done

    # Pass 2: delete older-month backups that are not their month's most recent.
    for f in "$WD_DEST/$hostname"-*.tgz; do
        [ -e "$f" ] || continue
        base=$(basename "$f")
        [[ "$base" =~ ^${hostname}-([0-9]{2})-([0-9]{2})-([0-9]{2})\.tgz$ ]] || continue
        mm="${BASH_REMATCH[1]}"; dd="${BASH_REMATCH[2]}"; yy="${BASH_REMATCH[3]}"
        ym="$yy$mm"
        [ "$ym" -ge "$prev_ym" ] && continue
        if [ "$f" != "${wd_latest_file[$ym]}" ]; then
            echo "  deleting $f"
            rm -f "$f"
        fi
    done

    unset wd_latest_day wd_latest_file
fi

# ============================================================================
# GCS Coldline fallback (DISABLED — the WD Cloud NFS block above is the active
# off-site copy). To re-enable a cloud copy, uncomment this block. It uploads to
# gs://$GCS_BUCKET and prunes with the month rule + a 90-day age floor (Coldline
# has a 90-day minimum-storage duration; earlier deletes incur a fee). One-time
# setup (bucket + step0-backup service-account key) is in this file's git history
# and architecture.md §7.
# ============================================================================
```

- [ ] **Step 2: Append the original GCS block, commented out, below the fallback banner**

Take the original GCS code (old lines 162–231: the `GCS_BUCKET=...` vars through the final
`unset gcs_latest_day gcs_latest_file` and its closing `fi`) and paste it beneath the banner
from Step 1 with every line prefixed `# ` so it is inert. Do not delete it — it is the
documented fallback.

- [ ] **Step 3: Syntax-check**

Run: `bash -n backup-minikube-mnt.sh`
Expected: no output (exit 0).

- [ ] **Step 4: Commit**

```bash
git add backup-minikube-mnt.sh
git commit -m "feat: off-site backup to WD Cloud (NFS) instead of GCS Coldline

WD Cloud 6TB on the LAN (192.168.50.169) over NFS is now the active off-site
target: guarded cp to /mnt/wdcloud/private-cloud + month-retention prune with no
90-day floor (own disk, free deletes). GCS Coldline block retained commented as a
fallback."
```

---

### Task 2: Point `restore-scratch.sh` at the WD mount

**Files:**
- Modify: `restore-scratch.sh` — header (lines 4-6), prereqs (lines 82-83), phase 1 base
  packages (line 105), phase 2 (`phase2_pull`, lines 159-197)

- [ ] **Step 1: Reword the header comment**

Replace lines 4-6:

```bash
# restore-scratch.sh — COLD disaster recovery: bare Ubuntu -> fully wired private cloud
# from the latest GCS Coldline backup. Inverse of backup-minikube-mnt.sh; ends by
# running start-scratch.sh (SKIP_APP_BUILDS=1) then pausing before app deploys.
```

with:

```bash
# restore-scratch.sh — COLD disaster recovery: bare Ubuntu -> fully wired private cloud
# from the latest WD Cloud (LAN NFS) backup. Inverse of backup-minikube-mnt.sh; ends by
# running start-scratch.sh (SKIP_APP_BUILDS=1) then pausing before app deploys.
```

- [ ] **Step 2: Reword prereq #2 (the interactive-auth note)**

Replace lines 82-83:

```bash
  2. You can complete an interactive `gcloud auth login` with an account that
     has read on gs://private_cloud_backup (project igtrader-296013).
```

with:

```bash
  2. The WD Cloud NAS (192.168.50.169) is reachable on the LAN and its NFS share
     holds the latest private-cloud-*.tgz backup (this box will mount it read-only).
```

- [ ] **Step 3: Add `nfs-common` to phase 1 base packages**

Replace line 105:

```bash
  run "sudo apt-get install -y ca-certificates curl gnupg jq git apt-transport-https"
```

with:

```bash
  run "sudo apt-get install -y ca-certificates curl gnupg jq git apt-transport-https nfs-common"
```

- [ ] **Step 4: Replace phase 2 config + `phase2_pull` to pull from the WD mount**

Replace lines 160-197 (from `GCLOUD="$HOME/google-cloud-sdk/bin/gcloud"` through the closing
`}` of `phase2_pull`) with:

```bash
WD_HOST="192.168.50.169"                       # WD Cloud 6TB on the LAN
WD_EXPORT="__CONFIRM_WITH_showmount_-e_192.168.50.169__"   # NFS export path (see backup-minikube-mnt.sh setup)
WD_MOUNT="/mnt/wdcloud"
WD_DEST="$WD_MOUNT/private-cloud"
BACKUP_DIR="/mnt/minikube-backups"
ARCHIVE_PATH=""   # set by phase2, consumed by phase4

phase2_pull() {
  should_run 2 || { log "phase 2 already done, skipping"; ARCHIVE_PATH="$(cat "$BACKUP_DIR/.restore-archive" 2>/dev/null)"; return; }
  log "PHASE 2 — mount WD Cloud (NFS) + pull latest backup"
  run "sudo mkdir -p '$BACKUP_DIR' && sudo chown cloud:cloud '$BACKUP_DIR'"
  run "sudo mkdir -p '$WD_MOUNT'"

  # Mount the WD NFS share if it is not already mounted.
  if [ "$DRY_RUN" = 1 ]; then
    echo "  DRYRUN> sudo mount -t nfs -o soft,timeo=150,retrans=3 $WD_HOST:$WD_EXPORT $WD_MOUNT"
    echo "  DRYRUN> ls $WD_DEST/private-cloud-*.tgz | pick_latest_archive"
    ARCHIVE_PATH="$BACKUP_DIR/<latest>.tgz"; return
  fi
  if ! mountpoint -q "$WD_MOUNT"; then
    run "sudo mount -t nfs -o soft,timeo=150,retrans=3 '$WD_HOST:$WD_EXPORT' '$WD_MOUNT'" \
      || die "cannot mount WD Cloud $WD_HOST:$WD_EXPORT at $WD_MOUNT"
  fi

  # Find newest archive by date embedded in filename (restore-lib pick_latest_archive).
  local listing latest
  listing="$(ls "$WD_DEST"/private-cloud-*.tgz 2>/dev/null)" || true
  [ -n "$listing" ] || die "no private-cloud-*.tgz found in $WD_DEST"
  latest="$(printf '%s\n' "$listing" | pick_latest_archive)"
  [ -n "$latest" ] || die "no private-cloud-*.tgz found in $WD_DEST"
  log "latest backup: $latest"
  cp "$latest" "$BACKUP_DIR/" || die "copy from WD Cloud failed"
  ARCHIVE_PATH="$BACKUP_DIR/$(basename "$latest")"
  echo "$ARCHIVE_PATH" > "$BACKUP_DIR/.restore-archive"
  [ -s "$ARCHIVE_PATH" ] || die "copied archive is empty: $ARCHIVE_PATH"
  log "downloaded: $ARCHIVE_PATH ($(du -h "$ARCHIVE_PATH" | awk '{print $1}'))"
  mark_phase 2
}
```

- [ ] **Step 5: Update the phase-1 log line + keep gcloud install (fallback)**

The phase-1 `log "PHASE 1 — install host tooling ..."` line (line 101) still mentions gcloud;
leave the gcloud SDK install (lines 148-154) in place — it supports the commented GCS fallback.
No change needed here beyond confirming the file still parses.

- [ ] **Step 6: Syntax-check**

Run: `bash -n restore-scratch.sh`
Expected: no output (exit 0).

- [ ] **Step 7: Commit**

```bash
git add restore-scratch.sh
git commit -m "feat: restore-scratch pulls DR backup from WD Cloud (NFS), not GCS

Phase 2 mounts the WD NFS share (192.168.50.169) and copies the latest
private-cloud-*.tgz instead of gcloud auth login + storage cp. Adds nfs-common to
phase 1 tooling. gcloud install kept for the commented GCS fallback."
```

---

### Task 3: Update `architecture.md` §7

**Files:**
- Modify: `architecture.md` — §7 "Off-site copy" (heading + body ~438-466) and the
  components-table row (~530)

- [ ] **Step 1: Rewrite the §7 off-site subsection**

Change the heading `### Off-site copy — Google Cloud Storage Coldline` to
`### Off-site copy — WD Cloud (LAN, NFS)` and rewrite its body to describe: the archive is
copied after the local prune to the WD Cloud NAS (`192.168.50.169`) mounted at `/mnt/wdcloud`
over NFS; the WD share is pruned with the same month-retention rule as local **with no 90-day
age floor** (own disk, free deletes); the step is guarded/additive (a dark NAS only WARNs). Note
the WD 6TB is formatted once manually via the WD dashboard, and that the GCS Coldline path is
retained commented in `backup-minikube-mnt.sh` as a fallback.

- [ ] **Step 2: Update the restore paragraph + components-table row**

In the §7 "Restoring from the off-site copy" paragraph (~466) and the `backup-minikube-mnt.sh`
components-table row (~530), replace "GCS Coldline" / "gs://private_cloud_backup" / "90-day-floor"
wording with the WD-over-NFS description (month-retention prune, no floor).

- [ ] **Step 3: Commit**

```bash
git add architecture.md
git commit -m "docs: architecture §7 off-site copy is WD Cloud (NFS), not GCS Coldline"
```

---

### Task 4: Update `CLAUDE.md`

**Files:**
- Modify: `CLAUDE.md` — `backup-minikube-mnt.sh` row, `restore-scratch.sh` row, and the
  "Off-site mirror (GCS Coldline)" bullet under the backup-retention convention

- [ ] **Step 1: Reword the three GCS mentions**

- `backup-minikube-mnt.sh` row: replace the "pushes the archive off-site to GCS Coldline
  (gs://private_cloud_backup ...) ... 90-day floor" sentence with: pushes the archive off-site to
  the **WD Cloud 6TB NAS on the LAN** (`192.168.50.169`, mounted `/mnt/wdcloud` over NFS) and
  prunes that share with the same month rule (no age floor — own disk). GCS Coldline retained
  commented as a fallback.
- `restore-scratch.sh` row: replace "pulls the latest GCS Coldline backup (interactive gcloud
  auth login)" with "mounts the WD Cloud NFS share and copies the latest backup".
- The "Off-site mirror (GCS Coldline)" bullet under the retention convention: reword to
  "Off-site mirror (WD Cloud, NFS)" — same month rule, **no** 90-day floor; note the floor only
  ever mattered for Coldline and is gone.

- [ ] **Step 2: Commit**

```bash
git add CLAUDE.md
git commit -m "docs: CLAUDE.md off-site backup is WD Cloud (NFS), not GCS Coldline"
```

---

### Task 5: Live verification (AFTER the WD format completes — wait ~15 min)

The operator is formatting the 6TB volume in the WD dashboard. Wait until that finishes before
these live steps (the earlier `bash -n` checks already passed offline).

- [ ] **Step 1: Install the NFS client + discover the export path**

```bash
sudo apt-get install -y nfs-common
showmount -e 192.168.50.169
```
Expected: a real export path (e.g. `/nfs/private-cloud` or `/mnt/HD/HD_a2/...`). Record it.

- [ ] **Step 2: Fill the real export path into both scripts**

Replace `__CONFIRM_WITH_showmount_-e_192.168.50.169__` with the discovered path in
`backup-minikube-mnt.sh` (`WD_EXPORT=`) and `restore-scratch.sh` (`WD_EXPORT=`). Re-run
`bash -n` on both. Commit: `docs: set confirmed WD_EXPORT NFS path`.

- [ ] **Step 3: Mount the WD and create the target dir**

```bash
sudo mkdir -p /mnt/wdcloud
sudo mount -t nfs -o soft,timeo=150,retrans=3 192.168.50.169:<WD_EXPORT> /mnt/wdcloud
mkdir -p /mnt/wdcloud/private-cloud
mountpoint -q /mnt/wdcloud && echo MOUNTED
```
Expected: `MOUNTED`. (Also add the `/etc/fstab` line from the setup band so it persists.)

- [ ] **Step 4: Live off-site copy test (uses an existing local archive, no full re-tar)**

```bash
latest_local=$(ls -t /mnt/minikube-backups/private-cloud-*.tgz 2>/dev/null | head -1)
echo "copying $latest_local"
cp "$latest_local" /mnt/wdcloud/private-cloud/
ls -lh /mnt/wdcloud/private-cloud/
```
Expected: the archive appears on the WD share with a matching size.

- [ ] **Step 5: restore-scratch dry-run**

```bash
./restore-scratch.sh --dry-run --from-phase 2
```
Expected: phase 2 prints the `sudo mount -t nfs ... 192.168.50.169:<WD_EXPORT> /mnt/wdcloud`
and `ls .../private-cloud-*.tgz | pick_latest_archive` lines — no `gcloud auth login`.

- [ ] **Step 6: Report results** — confirm the copy landed and the dry-run shows the WD path.
```
