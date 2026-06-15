#!/bin/bash
####################################
#
# Backup to NFS mount script.
#
####################################

# What to backup. 
backup_files="/home/cloud/Ideaprojects/minikube-mnt"
backup_files2="/home/cloud/Ideaprojects/nginx"
backup_files3="/home/cloud/Ideaprojects/STEP0"
backup_files4="/home/cloud/Ideaprojects/qcguy-ghost"

#First refresh the live vault config files into minikube-mnt so the backup captures
#the current per-app secrets (these can't live in GitHub).
cp /home/cloud/Ideaprojects/vault/helpmepdf-env-variables.sh $backup_files
cp /home/cloud/Ideaprojects/vault/yolo-env-variables.sh $backup_files
cp /home/cloud/Ideaprojects/vault/predictonomy-env-variables.sh $backup_files
cp /home/cloud/Ideaprojects/vault/ollama-env-variables.sh $backup_files

# Where to backup to.
dest="/mnt/minikube-backups"

# Create archive filename.
day=$(date +%m-%d-%y)
hostname=$(hostname -s)
archive_file="$hostname-$day.tgz"

# Print start status message.
echo "Backing up $backup_files and $backup_files2 and $backup_files3 and $backup_files4 to $dest/$archive_file"
date
echo

# Backup the files using tar.
tar -czf $dest/$archive_file $backup_files $backup_files2 $backup_files3 $backup_files4

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
