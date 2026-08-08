#!/bin/bash
####################################
#
# Backup to NFS mount script.
#
####################################

# Single-instance guard (flock). The archive name is deterministic per day
# ($hostname-$day.tgz), so two copies running at once — e.g. a duplicated root
# cron entry both firing Monday 05:00 — would `tar -czf` into the SAME file
# concurrently and corrupt it. Grab an exclusive, non-blocking lock on fd 200;
# if another run already holds it, exit quietly (0) instead of queuing. /tmp is
# writable whether this runs as the root cron or manually via sudo.
LOCKFILE="/tmp/backup-minikube-mnt.lock"
exec 200>"$LOCKFILE"
flock -n 200 || { echo "Another backup-minikube-mnt run holds $LOCKFILE; exiting."; exit 0; }

# Push notifications -> channel `yolo-private-cloud-backup` (ntfy-lib.sh registry).
# This job runs from a root cron on a Monday at 05:00 and nobody reads the cron log
# until something is already lost, so the weekly note IS the verification: it carries
# the run status, this archive's size, and how many backups exist locally + off-site.
# $0 is the absolute cron path, so dirname resolves even though this file is invoked
# by root from /. Sourcing is best-effort: a missing lib must not stop the backup.
SELFDIR="$(cd "$(dirname "$0")" && pwd)"
# shellcheck source=/dev/null
if [ -r "$SELFDIR/ntfy-lib.sh" ]; then source "$SELFDIR/ntfy-lib.sh"; else
  echo "WARNING: $SELFDIR/ntfy-lib.sh not readable — this run will send no notification." >&2
  ntfy_push() { :; }; ntfy_human_bytes() { echo "?"; }; NTFY_TOPIC_BACKUP=""
fi
# Warnings accumulate here and are folded into the final push, so a degraded-but-
# completed backup (e.g. WD dark) is visible on the phone rather than only in the log.
NTFY_WARNINGS=""
note_warn() { NTFY_WARNINGS="$NTFY_WARNINGS
- $1"; }

# What to backup.
backup_files="/mnt/minikube-mnt"
backup_files2="/home/cloud/Ideaprojects/nginx"
backup_files3="/home/cloud/Ideaprojects/STEP0"
backup_files4="/home/cloud/Ideaprojects/qcguy-ghost"
# ~/.vault holds cluster-keys.json (the ONLY copy of Vault's unseal key + root
# token) and jenkins-approle/. It lives in $HOME, outside every dir above, so it
# was NOT captured before — meaning a lost/truncated keys file (see the
# 2026-06-16 start-vault.sh race that zeroed it) on an already-initialized Vault
# would be unrecoverable. Back it up here. Runs as root cron; can read the 0600 file.
backup_files5="/home/cloud/.vault"
# The nightly WD My Cloud rsync backup toolkit (8TB .68 -> 16TB .251) lives OUTSIDE
# STEP0 in ~/wd-backup: the script (wd-backup.sh), its config (wd-backup.conf) AND the
# SMB credential files (.smb-cred-*) that are NOT in any git repo. Capture it so a
# bare-metal restore-scratch can re-arm that job (install-on-prod.sh + 02:00 cron)
# without needing the dev box online. Its logs/ are excluded from the tar below
# (regenerable churn). Same trust level as ~/.vault above — the archive already
# carries the Vault root token, so these creds ride along consistently.
backup_files6="/home/cloud/wd-backup"

#First refresh the live vault config files into minikube-mnt so the backup captures
#the current per-app secrets (these can't live in GitHub).
cp /home/cloud/Ideaprojects/vault/helpmepdf-env-variables.sh $backup_files
cp /home/cloud/Ideaprojects/vault/yolo-env-variables.sh $backup_files
cp /home/cloud/Ideaprojects/vault/predictonomy-env-variables.sh $backup_files
cp /home/cloud/Ideaprojects/vault/ollama-env-variables.sh $backup_files

# Sanity-check the irreplaceable keys file before snapshotting. An empty/missing
# cluster-keys.json would make this archive a false-confidence backup, so warn
# loudly (visible in the cron log) — but still proceed so the rest is captured.
keys_file="$backup_files5/cluster-keys.json"
if [ ! -s "$keys_file" ]; then
    echo "WARNING: $keys_file is missing or EMPTY — Vault unseal key/root token will NOT be in this backup." >&2
    note_warn "cluster-keys.json missing/EMPTY — no Vault unseal key in this archive"
fi

##############################################
#
# Registry catalog snapshot (the archive carries this INSTEAD of the blobs).
#
# The registry blob store (/mnt/kachra/container-registry-images) is bind-mounted
# INSIDE minikube-mnt (ensure-registry-store.sh, R8), so from 2026-06 the tar below
# had been silently swallowing it — 34G of the 41G 2026-08-03 archive (~83%), and
# docker blobs are already gzipped so they inflate the tgz ~1:1 — while
# docs/architecture.md §7 documented the blobs as NOT in the archive (single-disk restore:
# Jenkins re-pushes every image). The --exclude on the tar line restores that
# contract; what a bare-metal restore actually needs is the LIST of what to rebuild,
# which this snapshot captures (every repo + its tags). Best-effort on purpose: with
# the cluster stopped (a quiesced migration-day backup) the registry is dark — keep
# the previous snapshot rather than fail the run or truncate the file.
#
##############################################
REG_URL="${REG_URL:-http://172.16.238.2:5000}"
catalog_file="$backup_files/registry-catalog.txt"
if command -v jq >/dev/null 2>&1 \
   && repos_json=$(curl -sf --max-time 10 "$REG_URL/v2/_catalog?n=1000") \
   && [ -n "$repos_json" ]; then
    {
        echo "# registry catalog snapshot $(date -u +%Y-%m-%dT%H:%M:%SZ) — $REG_URL"
        echo "# format: <repo> <tags-json>. Blobs are NOT in this archive; Jenkins rebuilds them (docs/architecture.md §7)."
        echo "$repos_json" | jq -r '.repositories[]' | while read -r repo; do
            echo "$repo $(curl -sf --max-time 10 "$REG_URL/v2/$repo/tags/list" | jq -c '.tags' 2>/dev/null)"
        done
    } > "$catalog_file.tmp" && mv "$catalog_file.tmp" "$catalog_file"
elif [ -s "$catalog_file" ]; then
    echo "WARNING: registry unreachable — keeping the previous registry-catalog.txt (cluster stopped?)" >&2
else
    echo "WARNING: registry unreachable and no previous registry-catalog.txt — archive carries no registry catalog." >&2
    note_warn "registry catalog missing (registry dark, no previous snapshot)"
fi

# Where to backup to.
dest="/mnt/minikube-backups"

# Create archive filename.
day=$(date +%m-%d-%y)
hostname=$(hostname -s)
archive_file="$hostname-$day.tgz"

# Print start status message.
echo "Backing up $backup_files and $backup_files2 and $backup_files3 and $backup_files4 and $backup_files5 and $backup_files6 to $dest/$archive_file"
date
echo

# Backup the files using tar.
# Exclude ollama/models (~38G of model blobs, e.g. quantos/qwen2.5, qwen3-coder,
# deepseek-r1:32b): they are reproducible via `ollama pull` / the loaders / the Modelfile,
# and including them would bloat
# each weekly archive from ~5G to ~40G and fill /dev/sdb1 under the retention
# policy. ollama's identity key (id_ed25519) + config live outside models/ and
# ARE still captured.
# container-registry-images is likewise excluded (2026-08-06): it is the kachra blob
# store bind-mounted inside minikube-mnt — 34G of the 41G 2026-08-03 archive — and the
# restore contract has always been "registry starts empty; Jenkins re-pushes"
# (docs/architecture.md §7). registry-catalog.txt (refreshed above) records what to rebuild.
# tar's exit code was previously discarded; the weekly push reports it, so a truncated
# or partial archive (rc=2 on a read error, rc=1 on files changing mid-read) now
# surfaces on the phone instead of only in the cron log.
tar_start=$(date +%s)
# --numeric-owner: store UIDs/GIDs as NUMBERS, never as user names. tar records both by
# default and, on extract, resolves the NAME against the destination's /etc/passwd — so a
# restore onto a box with different system accounts silently relocates data to whatever
# uid that name happens to be there. Found 2026-08-07 restoring 24.04 -> 26.04: vault's
# uid 100 was named `systemd-network` on the old box, which is 998 on 26.04, so vault-data
# "restored" to 998 and vault-0 could not read its own storage. Same for `systemd-coredump`
# (mysql/mongo, 999). Directories whose uid had NO name (70, 10001) came through correctly,
# which is why the corruption looked like random per-app inconsistency. Container UIDs are
# numeric facts; the names are meaningless noise. restore-scratch.sh extracts with the same
# flag, and handles older name-bearing archives the same way.
tar -czf $dest/$archive_file --numeric-owner --exclude='*/ollama/models' --exclude='*/wd-backup/logs' --exclude='*/container-registry-images' $backup_files $backup_files2 $backup_files3 $backup_files4 $backup_files5 $backup_files6
tar_rc=$?
tar_elapsed=$(( $(date +%s) - tar_start ))
if [ "$tar_rc" -eq 1 ]; then
    note_warn "tar exited 1 (some files changed while being read) — archive is usable but not a point-in-time snapshot"
elif [ "$tar_rc" -ne 0 ]; then
    note_warn "tar FAILED (rc=$tar_rc) — this archive may be incomplete"
fi

# Print end status message.
echo
echo "Backup finished"
date

##############################################
#
# Retention / prune to save space.
#
# Keep every weekly backup for the current month and the previous month.
# For any month older than that, keep only that month's most recent backup
# and delete the rest. Archives are named <hostname>-MM-DD-YY.tgz.
#
##############################################
echo
echo "Pruning old backups in $dest (keep weekly for current + previous month, one per older month)"

# Numeric YYMM keys (e.g. June 2026 -> 2606). Anything >= prev_ym is kept as-is.
cur_ym=$(date +%y%m)
prev_ym=$(date -d "$(date +%Y-%m-01) -1 month" +%y%m)

declare -A latest_day    # YYMM -> highest day (DD) seen for that month
declare -A latest_file   # YYMM -> file with that highest day

# Pass 1: for older months, find the most recent (highest-day) backup per month.
for f in "$dest/$hostname"-*.tgz; do
    [ -e "$f" ] || continue
    base=$(basename "$f")
    [[ "$base" =~ ^${hostname}-([0-9]{2})-([0-9]{2})-([0-9]{2})\.tgz$ ]] || continue
    mm="${BASH_REMATCH[1]}"; dd="${BASH_REMATCH[2]}"; yy="${BASH_REMATCH[3]}"
    ym="$yy$mm"                              # numeric YYMM, increases over time
    [ "$ym" -ge "$prev_ym" ] && continue     # current/previous month: keep all
    if [ -z "${latest_day[$ym]}" ] || [ "$dd" -gt "${latest_day[$ym]}" ]; then
        latest_day[$ym]="$dd"
        latest_file[$ym]="$f"
    fi
done

# Pass 2: delete older-month backups that are not their month's most recent.
for f in "$dest/$hostname"-*.tgz; do
    [ -e "$f" ] || continue
    base=$(basename "$f")
    [[ "$base" =~ ^${hostname}-([0-9]{2})-([0-9]{2})-([0-9]{2})\.tgz$ ]] || continue
    mm="${BASH_REMATCH[1]}"; dd="${BASH_REMATCH[2]}"; yy="${BASH_REMATCH[3]}"
    ym="$yy$mm"
    [ "$ym" -ge "$prev_ym" ] && continue
    if [ "$f" != "${latest_file[$ym]}" ]; then
        echo "  deleting $f"
        rm -f "$f"
    fi
done

# Pass 3: AGE CAP. Passes 1-2 keep one archive per month FOREVER, which is not a
# retention policy — it is unbounded growth with a slow slope. At ~40GB per archive
# (and rising: 21GB in Jun 2026 -> 43GB in Aug) that is ~480GB/year accumulating.
# Measured 2026-08-07: the 916GB backup HDD would fill in roughly 12-15 months and the
# 5.5TB NAS in about a decade — and a full backup disk means the weekly job silently
# stops producing backups, which is discovered exactly when you need one.
#
# So: monthly archives are also dropped once they exceed MAX_ARCHIVE_AGE_MONTHS. The
# current + previous month are untouched by this (Pass 1 skips them), so the newest
# backups are never at risk. Set to 0 to disable the cap and restore the old behaviour.
MAX_ARCHIVE_AGE_MONTHS="${MAX_ARCHIVE_AGE_MONTHS:-6}"
if [ "$MAX_ARCHIVE_AGE_MONTHS" -gt 0 ] 2>/dev/null; then
    cutoff_ym=$(date -d "$(date +%Y-%m-01) -${MAX_ARCHIVE_AGE_MONTHS} month" +%y%m)
    echo "  age cap: dropping monthly archives older than ${MAX_ARCHIVE_AGE_MONTHS} months (before $cutoff_ym)"
    for f in "$dest/$hostname"-*.tgz; do
        [ -e "$f" ] || continue
        base=$(basename "$f")
        [[ "$base" =~ ^${hostname}-([0-9]{2})-([0-9]{2})-([0-9]{2})\.tgz$ ]] || continue
        mm="${BASH_REMATCH[1]}"; yy="${BASH_REMATCH[3]}"
        ym="$yy$mm"
        if [ "$ym" -lt "$cutoff_ym" ]; then
            echo "  deleting (age cap) $f"
            rm -f "$f"
        fi
    done
fi

# Long listing of files in $dest to check file sizes.
ls -lh $dest

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
#   # 2. Persistent, boot-safe mount. hard => writes retry instead of erroring
#   #    (a soft mount can return EIO / truncate a large archive if the NAS is slow
#   #    to fsync — unacceptable for a backup); nofail + x-systemd.automount keep a
#   #    dark NAS from ever blocking boot (it mounts on first access instead).
#   sudo mkdir -p /mnt/wdcloud
#   #   add to /etc/fstab:
#   #   192.168.50.169:/nfs/private-cloud  /mnt/wdcloud  nfs  _netdev,nofail,hard,timeo=600,retrans=3,x-systemd.automount  0 0
#   sudo mount /mnt/wdcloud    # archives land at the share root
##############################################
WD_HOST="192.168.50.169"                 # WD Cloud 6TB on the LAN
WD_EXPORT="/nfs/private-cloud"            # dedicated NFS share (backed by /mnt/HD/HD_a2/private-cloud)
WD_MOUNT="/mnt/wdcloud"                   # persistent NFS mount (see setup above)
WD_DEST="$WD_MOUNT"                       # dedicated share — archives live at the mount root

echo
echo "Off-site: copying $archive_file to $WD_DEST (WD Cloud, NFS)"

WD_STATUS="skipped"     # -> reported in the weekly push: copied | skipped | FAILED
if ! mountpoint -q "$WD_MOUNT"; then
    echo "WARNING: $WD_MOUNT is not mounted — skipping off-site WD backup. See setup notes above." >&2
    note_warn "off-site SKIPPED: $WD_MOUNT not mounted (WD Cloud NAS dark?) — this week exists on ONE disk only"
elif ! mkdir -p "$WD_DEST" 2>/dev/null || [ ! -w "$WD_DEST" ]; then
    echo "WARNING: $WD_DEST missing/unwritable — skipping off-site WD backup." >&2
    note_warn "off-site SKIPPED: $WD_DEST unwritable — this week exists on ONE disk only"
else
    if cp "$dest/$archive_file" "$WD_DEST/"; then
        echo "Off-site copy OK: $WD_DEST/$archive_file"
        WD_STATUS="copied"
    else
        echo "WARNING: off-site copy of $archive_file to $WD_DEST failed." >&2
        WD_STATUS="FAILED"
        note_warn "off-site copy to the WD Cloud FAILED — this week exists on ONE disk only"
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

    # Pass 3: the SAME age cap as local. The NAS is 5.5TB so it has far more runway
    # than the 916GB local disk, but "one per month forever" is still unbounded — at
    # ~40GB/archive it reaches ~2.8TB in five years and fills the share in about ten.
    # A deeper history off-site than on-site would be defensible, in which case set
    # MAX_ARCHIVE_AGE_MONTHS_WD higher than MAX_ARCHIVE_AGE_MONTHS; it defaults to the
    # same value so there is one number to reason about.
    MAX_ARCHIVE_AGE_MONTHS_WD="${MAX_ARCHIVE_AGE_MONTHS_WD:-$MAX_ARCHIVE_AGE_MONTHS}"
    if [ "$MAX_ARCHIVE_AGE_MONTHS_WD" -gt 0 ] 2>/dev/null; then
        wd_cutoff_ym=$(date -d "$(date +%Y-%m-01) -${MAX_ARCHIVE_AGE_MONTHS_WD} month" +%y%m)
        echo "  age cap: dropping monthly archives older than ${MAX_ARCHIVE_AGE_MONTHS_WD} months (before $wd_cutoff_ym)"
        for f in "$WD_DEST/$hostname"-*.tgz; do
            [ -e "$f" ] || continue
            base=$(basename "$f")
            [[ "$base" =~ ^${hostname}-([0-9]{2})-([0-9]{2})-([0-9]{2})\.tgz$ ]] || continue
            mm="${BASH_REMATCH[1]}"; yy="${BASH_REMATCH[3]}"
            ym="$yy$mm"
            if [ "$ym" -lt "$wd_cutoff_ym" ]; then
                echo "  deleting (age cap) $f"
                rm -f "$f"
            fi
        done
    fi

    unset wd_latest_day wd_latest_file
fi

# ============================================================================
# GCS Coldline fallback (DISABLED — the WD Cloud NFS block above is the active
# off-site copy). To re-enable a cloud copy, uncomment this block. It uploads to
# gs://$GCS_BUCKET and prunes with the month rule + a 90-day age floor (Coldline
# has a 90-day minimum-storage duration; earlier deletes incur a fee). One-time
# setup (bucket + step0-backup service-account key) is in this file's git history
# and docs/architecture.md §7.
# ============================================================================
# GCS_BUCKET="private_cloud_backup"                     # GCP project: igtrader-296013
# GCS_KEY="/home/cloud/.gcp/step0-backup-key.json"      # service-account key (0600, root-readable)
# GCLOUD_BIN="/home/cloud/google-cloud-sdk/bin/gcloud"
# export CLOUDSDK_CONFIG="/home/cloud/.gcp/cloudsdk-config"  # isolated gcloud state for the root cron
# GCS_MIN_AGE_DAYS=93   # Coldline 90-day minimum + 3-day margin; never delete below this age.
#
# echo
# echo "Off-site: uploading $archive_file to gs://$GCS_BUCKET (Coldline)"
#
# if [ ! -x "$GCLOUD_BIN" ]; then
#     echo "WARNING: gcloud not found at $GCLOUD_BIN — skipping off-site GCS backup. See setup notes above." >&2
# elif [ "$GCS_BUCKET" = "REPLACE_WITH_BUCKET_NAME" ]; then
#     echo "WARNING: GCS_BUCKET not configured — skipping off-site GCS backup. See setup notes above." >&2
# elif [ ! -s "$GCS_KEY" ]; then
#     echo "WARNING: GCS key $GCS_KEY missing/empty — skipping off-site GCS backup. See setup notes above." >&2
# elif ! "$GCLOUD_BIN" auth activate-service-account --key-file="$GCS_KEY" --quiet; then
#     echo "WARNING: gcloud service-account auth failed — skipping off-site GCS backup." >&2
# else
#     # Upload this week's archive (the .tgz already exists; local prune never removes
#     # the current month, so it is still present here).
#     if "$GCLOUD_BIN" storage cp "$dest/$archive_file" "gs://$GCS_BUCKET/" --quiet; then
#         echo "Off-site upload OK: gs://$GCS_BUCKET/$archive_file"
#     else
#         echo "WARNING: off-site upload of $archive_file failed." >&2
#     fi
#
#     # --- Cloud prune: same month retention as local, with a 90-day age floor. ---
#     echo "Pruning gs://$GCS_BUCKET (month retention + >= ${GCS_MIN_AGE_DAYS}d Coldline floor)"
#     now_epoch=$(date +%s)
#     declare -A gcs_latest_day    # YYMM -> highest day (DD) seen for that older month
#     declare -A gcs_latest_file   # YYMM -> object with that highest day
#
#     # Single listing reused by both passes (no per-object metadata calls).
#     mapfile -t gcs_objs < <("$GCLOUD_BIN" storage ls "gs://$GCS_BUCKET/${hostname}-"*.tgz 2>/dev/null)
#
#     # Pass 1: for older months, find the most recent (highest-day) backup per month.
#     for obj in "${gcs_objs[@]}"; do
#         base=$(basename "$obj")
#         [[ "$base" =~ ^${hostname}-([0-9]{2})-([0-9]{2})-([0-9]{2})\.tgz$ ]] || continue
#         mm="${BASH_REMATCH[1]}"; dd="${BASH_REMATCH[2]}"; yy="${BASH_REMATCH[3]}"
#         ym="$yy$mm"
#         [ "$ym" -ge "$prev_ym" ] && continue     # current/previous month: keep all
#         if [ -z "${gcs_latest_day[$ym]}" ] || [ "$dd" -gt "${gcs_latest_day[$ym]}" ]; then
#             gcs_latest_day[$ym]="$dd"
#             gcs_latest_file[$ym]="$obj"
#         fi
#     done
#
#     # Pass 2: delete older-month non-latest objects — but only once past the floor.
#     for obj in "${gcs_objs[@]}"; do
#         base=$(basename "$obj")
#         [[ "$base" =~ ^${hostname}-([0-9]{2})-([0-9]{2})-([0-9]{2})\.tgz$ ]] || continue
#         mm="${BASH_REMATCH[1]}"; dd="${BASH_REMATCH[2]}"; yy="${BASH_REMATCH[3]}"
#         ym="$yy$mm"
#         [ "$ym" -ge "$prev_ym" ] && continue
#         [ "$obj" = "${gcs_latest_file[$ym]}" ] && continue   # keep month's most recent
#         obj_epoch=$(date -d "20$yy-$mm-$dd" +%s 2>/dev/null) || continue
#         age_days=$(( (now_epoch - obj_epoch) / 86400 ))
#         if [ "$age_days" -ge "$GCS_MIN_AGE_DAYS" ]; then
#             echo "  deleting $obj (age ${age_days}d)"
#             "$GCLOUD_BIN" storage rm "$obj" --quiet || echo "WARNING: failed to delete $obj" >&2
#         else
#             echo "  keeping $obj (age ${age_days}d < ${GCS_MIN_AGE_DAYS}d Coldline floor)"
#         fi
#     done
#
#     unset gcs_latest_day gcs_latest_file
# fi

##############################################
#
# Weekly push notification -> ntfy `yolo-private-cloud-backup`.
#
# Runs LAST, after the local prune and the off-site copy+prune, so the counts and
# totals it reports are the post-retention truth rather than a mid-run snapshot.
# The message answers the three questions you actually have on a Monday morning:
# did it run, how big was it, and how many restore points do I still have (here AND
# off-site). Any warning collected along the way is appended, and its presence — not
# the tar exit code alone — is what raises the priority.
#
##############################################
# Local: post-prune count + total bytes across every retained archive.
local_count=$(ls -1 "$dest/$hostname"-*.tgz 2>/dev/null | wc -l)
local_total=$(du -cb "$dest/$hostname"-*.tgz 2>/dev/null | tail -1 | cut -f1)
this_size=$(stat -c %s "$dest/$archive_file" 2>/dev/null)
local_avail=$(df -B1 --output=avail "$dest" 2>/dev/null | tail -1 | tr -d ' ')

# Off-site: only meaningful while the NFS mount is up. Guarded so a dark NAS yields
# "n/a" instead of a stat error (and the WARNING above already explains why).
if mountpoint -q "$WD_MOUNT" 2>/dev/null; then
    wd_count=$(ls -1 "$WD_DEST/$hostname"-*.tgz 2>/dev/null | wc -l)
    wd_total=$(du -cb "$WD_DEST/$hostname"-*.tgz 2>/dev/null | tail -1 | cut -f1)
    wd_avail=$(df -B1 --output=avail "$WD_MOUNT" 2>/dev/null | tail -1 | tr -d ' ')
    wd_line="off-site (WD Cloud): $wd_count backups, $(ntfy_human_bytes "$wd_total") total, $(ntfy_human_bytes "$wd_avail") free"
else
    wd_count=0
    wd_line="off-site (WD Cloud): n/a — NAS not mounted"
fi

if [ "$tar_rc" -eq 0 ] && [ -z "$NTFY_WARNINGS" ]; then
    ntfy_title="Weekly backup OK - $(ntfy_human_bytes "$this_size")"
    ntfy_prio="default"; ntfy_tags="floppy_disk,cloud"
elif [ "$tar_rc" -ne 0 ] && [ "$tar_rc" -ne 1 ]; then
    ntfy_title="Weekly backup FAILED (tar rc=$tar_rc)"
    ntfy_prio="urgent"; ntfy_tags="rotating_light,floppy_disk"
else
    ntfy_title="Weekly backup completed with warnings - $(ntfy_human_bytes "$this_size")"
    ntfy_prio="high"; ntfy_tags="warning,floppy_disk"
fi

ntfy_push "$NTFY_TOPIC_BACKUP" "$ntfy_title" \
"$archive_file
this run: $(ntfy_human_bytes "$this_size") in ${tar_elapsed}s (tar rc=$tar_rc)
local ($dest): $local_count backups, $(ntfy_human_bytes "$local_total") total, $(ntfy_human_bytes "$local_avail") free
$wd_line
off-site copy: $WD_STATUS${NTFY_WARNINGS:+
warnings:$NTFY_WARNINGS}" \
    "$ntfy_prio" "$ntfy_tags"
