# Off-site backup: GCS Coldline → WD Cloud (NFS) — design

**Date:** 2026-07-05
**Status:** approved (design), pending implementation
**Touches:** `backup-minikube-mnt.sh`, `restore-scratch.sh`, `docs/architecture.md` §7, `CLAUDE.md`

## Goal

Replace the **off-site** backup target from **GCS Coldline** (`gs://private_cloud_backup`)
with the **WD Cloud 6 TB NAS on the LAN** (`192.168.50.169`), accessed over **NFS**.

The local archive build + local prune to `/mnt/minikube-backups` are **unchanged**. Only the
off-site copy (and its DR consumer + docs) change.

## Why NFS

Probed the WD at `192.168.50.169` from the prod host:

- **NFS 2049 OPEN**, rpcbind **111 OPEN**, SMB **445 OPEN**, **SSH 22 closed** (rsync/SSH ruled out).
- 0.3 ms LAN hop; the box's own backup header already calls itself a "Backup to NFS mount script".

NFS wins for a **root cron**: no credentials baked into the script (unlike CIFS), no SSH-key /
busybox fragility, and a persistent `/etc/fstab` mount the script just `cp`s into. Neither
`nfs-common` nor `cifs-utils` is currently installed on the prod host — `nfs-common` is a
one-time add.

## Decisions (locked)

- **WD Cloud is the default/active off-site target**, fully replacing GCS Coldline as the live copy.
- **Format the WD 6 TB first, once, manually via the WD dashboard** (device is empty; full wipe is
  intended). Not scripted — the host cannot format a network appliance. See "One-time setup — Step 0".
- **Keep the GCS block as a commented-out fallback** (not deleted) — re-enable a cloud copy later
  without rewriting. Existing GCS bucket data is left untouched (delete manually whenever).
- **Update `restore-scratch.sh` in the same change** so the DR restore path stays working.
- No 90-day age floor on the WD prune — the Coldline early-deletion fee it guarded against does
  not exist on our own disk.

## One-time setup (operator, documented in-script)

### Step 0 — format the WD Cloud 6 TB (manual, in the WD dashboard)

The device is a network appliance — the STEP0 host has **no block device** to `mkfs` (it's only
reachable over NFS/SMB; SSH is closed). So the format is a **manual one-time operator step**, done
in the **WD My Cloud web dashboard**, before the mount below:

- Dashboard → **Settings → Utilities → Format Volume** (or Full Factory Restore) to wipe the 6 TB
  volume for a clean, dedicated backup disk. Confirmed intent: the device is empty; a full wipe is fine.
- After formatting, (re)create/enable the NFS share that `WD_EXPORT` will point at.

This is **not scripted** and never runs from the cron — it is a documented prerequisite, called out
in the script's setup comment band the same way the GCS bucket-creation steps were.

### Step 1 — host mount

```bash
sudo apt-get install -y nfs-common
# Confirm the export path (needs nfs-common):
showmount -e 192.168.50.169
# Persistent, boot-safe mount (nofail+soft => a dark NAS never blocks boot or wedges the cron):
sudo mkdir -p /mnt/wdcloud
# /etc/fstab:
# 192.168.50.169:<WD_EXPORT>  /mnt/wdcloud  nfs  _netdev,nofail,soft,timeo=150,retrans=3,x-systemd.automount  0 0
sudo mount /mnt/wdcloud
mkdir -p /mnt/wdcloud/private-cloud
```

`<WD_EXPORT>` is the one value not auto-discoverable without `nfs-common`; it is confirmed here
and written into the script as `WD_EXPORT`. Until the mount exists, the off-site block **no-ops
with a WARNING** (mirroring how the GCS block no-op'd before its bucket existed).

## Change 1 — `backup-minikube-mnt.sh` (off-site block, replaces GCS lines 122–231)

Config:

```bash
WD_HOST="192.168.50.169"
WD_EXPORT="<confirm-with: showmount -e 192.168.50.169>"   # documented, informational
WD_MOUNT="/mnt/wdcloud"
WD_DEST="$WD_MOUNT/private-cloud"
```

Guarded + additive (identical philosophy to the GCS block — **never** aborts the local backup):

1. If `$WD_MOUNT` is **not a live mountpoint** (`mountpoint -q`) or `$WD_DEST` is **not writable**
   → `WARNING` to the cron log, skip the whole off-site step.
2. Copy: `cp "$dest/$archive_file" "$WD_DEST/"`, then `WARNING` on failure.
3. Prune `$WD_DEST`: the **same** two-pass month-retention logic as the local prune
   (keep every weekly for current + previous month; for older months keep only that month's
   most recent), operating on `$WD_DEST/${hostname}-*.tgz`. **No age floor** — plain `rm -f`.

The old GCS block (vars + upload + floored prune) is moved into a `# ---- GCS Coldline fallback
(disabled) ----` comment band directly below, with a one-line note on how to re-enable.

## Change 2 — `restore-scratch.sh`

- **Phase 1 tooling:** add `nfs-common` to the install list (so phase 2 can mount). Keep the
  gcloud install (fallback path stays possible).
- **Phase 2 (`phase2_pull`):** replace `gcloud auth login` + `gcloud storage ls/cp` with:
  - Ensure `/mnt/wdcloud` is mounted (mount `$WD_HOST:$WD_EXPORT` if not; `die` with a clear
    message if it can't mount — DR genuinely needs the archive).
  - `ls "$WD_MOUNT/private-cloud/private-cloud-*.tgz" | pick_latest_archive` (reuse existing
    `pick_latest_archive` helper), then `cp` to `$BACKUP_DIR/`.
  - Keep the `.restore-archive` marker + empty-file check unchanged.
- `--dry-run` branch updated to print the mount/copy commands instead of the gcloud commands.
- Header comment + prerequisites block (lines ~5, 82–83) reworded: DR pulls from the WD NFS
  share on the LAN, not GCS.

## Change 3 — docs

- **`docs/architecture.md` §7** "Off-site copy — Google Cloud Storage Coldline" → rewrite for
  **WD Cloud over NFS** (mount, month-retention prune with **no** 90-day floor, guarded/additive).
  Update the §7 restore paragraph and the components-table row (line ~530) similarly.
- **`CLAUDE.md`** — the `backup-minikube-mnt.sh` row, the `restore-scratch.sh` row, and the
  "Off-site mirror (GCS Coldline)" bullet under the retention convention → describe WD-over-NFS.
  Note the GCS path is retained commented as a fallback.

## Out of scope

- Deleting existing objects in `gs://private_cloud_backup` (left as-is).
- Scripting the WD format — it is a **manual dashboard step** (Step 0), never a cron/script action.
- The retention *convention* itself (unchanged; WD simply drops the Coldline-only floor).
- Local archive build + local `/mnt/minikube-backups` prune (unchanged).
- SMB/CIFS or rsync paths (NFS chosen).

## Verification

- `bash -n` both scripts.
- Dry sanity: `mountpoint -q /mnt/wdcloud` guard returns cleanly when unmounted (no-op + WARNING).
- After operator mounts the WD: a manual `sudo ./backup-minikube-mnt.sh` copies the current
  `.tgz` to `/mnt/wdcloud/private-cloud/` and the WD prune lists/keeps correctly.
- `restore-scratch.sh --dry-run` prints the WD mount + copy commands (no gcloud auth).
