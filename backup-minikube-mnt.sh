#!/bin/bash
####################################
#
# Backup to NFS mount script.
#
####################################

# What to backup. 
backup_files="/home/cloud/Ideaprojects/minikube-mnt"
backup_files2="/home/cloud/Ideaprojects/nginx"

# Where to backup to.
dest="/mnt/backup/minikube-mnt-backups/"

# Create archive filename.
day=$(date +%m-%d-%y)
hostname=$(hostname -s)
archive_file="$hostname-$day.tgz"

# Print start status message.
echo "Backing up $backup_files and $backup_files2 to $dest/$archive_file"
date
echo

# Backup the files using tar.
tar -czf $dest/$archive_file $backup_files $backup_files2

# Print end status message.
echo
echo "Backup finished"
date

# Long listing of files in $dest to check file sizes.
ls -lh $dest
