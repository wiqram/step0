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

# What to backup.
backup_files="/mnt/minikube-backups/minikube-mnt"
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
tar -czf $dest/$archive_file --exclude='*/ollama/models' --exclude='*/wd-backup/logs' $backup_files $backup_files2 $backup_files3 $backup_files4 $backup_files5 $backup_files6

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
