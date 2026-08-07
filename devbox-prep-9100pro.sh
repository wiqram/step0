#!/usr/bin/env bash
# prep-9100pro.sh — lay down the DEVBOX-9100PRO-MIGRATION.md §1 partition table on the
# blank Samsung 9100 PRO 4TB, BEFORE the Ubuntu 26.04 install.
#
# Why do this now instead of in the installer: a partition table is not data, so it is
# safe to create ahead of time (unlike files, which the installer would format away).
# Pre-creating it means the installer's manual step is "assign mount points to existing,
# labelled partitions" — no typing sizes into a GUI, no chance of a fat-fingered size,
# and partitions 3/4 (/var, /var/lib/docker) exist ready for post-install fstab even if
# the desktop installer will not accept those mount points directly.
#
# It DESTROYS everything on the target. Guards below refuse to run unless the target is
# the 4TB 9100 PRO, is unmounted, and carries no partitions.
#
#   sudo bash prep-9100pro.sh            # dry run: prints the plan, changes nothing
#   sudo bash prep-9100pro.sh --commit   # actually partition + format

set -euo pipefail

DEV=/dev/nvme0n1
EXPECT_MODEL='Samsung SSD 9100 PRO 4TB'
COMMIT=0
[ "${1:-}" = "--commit" ] && COMMIT=1

# ---------------------------------------------------------------- guards
[ -b "$DEV" ] || { echo "FAIL: $DEV is not a block device"; exit 1; }

model=$(cat /sys/block/$(basename $DEV)/device/model 2>/dev/null | xargs || true)
[ "$model" = "$EXPECT_MODEL" ] || { echo "FAIL: $DEV model is '$model', expected '$EXPECT_MODEL'"; exit 1; }

# Nothing on this disk (or any child of it) may be mounted.
if lsblk -nro MOUNTPOINT "$DEV" | grep -q .; then
  echo "FAIL: $DEV has mounted filesystems:"; lsblk -o NAME,SIZE,FSTYPE,MOUNTPOINT "$DEV"; exit 1
fi

# The disk must still be blank — refuse to silently eat a table someone already made.
parts=$(lsblk -nro NAME "$DEV" | tail -n +2 | wc -l)
if [ "$parts" -ne 0 ]; then
  echo "FAIL: $DEV already has $parts partition(s). Refusing. Inspect first:"
  lsblk -o NAME,SIZE,FSTYPE,LABEL "$DEV"; exit 1
fi

# Sanity: the CURRENT root must NOT be on this disk (it is on the old 980).
root_src=$(findmnt -no SOURCE /)
case "$root_src" in "$DEV"*) echo "FAIL: current / ($root_src) is on $DEV"; exit 1;; esac

echo "Target : $DEV  ($model, $(lsblk -dno SIZE $DEV | xargs))"
echo "Current / lives on $root_src  (the old 980 — untouched by this script)"
echo

# ---------------------------------------------------------------- plan
# num size    type  label         mount (assigned later)
PLAN=(
  "1 1G     ef00 ESP           /boot/efi"
  "2 120G   8300 ubuntu-root   /"
  "3 100G   8300 ubuntu-var    /var"
  "4 400G   8300 docker        /var/lib/docker"
  "5 1536G  8300 home          /home"
)
printf '%-4s %-8s %-14s %s\n' "#" "SIZE" "LABEL" "MOUNT"
for p in "${PLAN[@]}"; do read -r n s t l m <<<"$p"; printf '%-4s %-8s %-14s %s\n' "$n" "$s" "$l" "$m"; done
echo "-    ~1.5T   (unallocated tail — deliberate: future datasets/VMs/growing /home)"
echo

if [ "$COMMIT" -ne 1 ]; then
  echo "DRY RUN — nothing changed. Re-run with --commit to apply."
  exit 0
fi

read -r -p "Type ERASE to wipe and partition $DEV: " ans
[ "$ans" = "ERASE" ] || { echo "Aborted."; exit 1; }

# ---------------------------------------------------------------- apply
sgdisk --zap-all "$DEV"
sgdisk -n 1:0:+1G     -t 1:ef00 -c 1:"EFI System"    "$DEV"
sgdisk -n 2:0:+120G   -t 2:8300 -c 2:"ubuntu-root"   "$DEV"
sgdisk -n 3:0:+100G   -t 3:8300 -c 3:"ubuntu-var"    "$DEV"
sgdisk -n 4:0:+400G   -t 4:8300 -c 4:"docker"        "$DEV"
sgdisk -n 5:0:+1536G  -t 5:8300 -c 5:"home"          "$DEV"
partprobe "$DEV"; udevadm settle

# Format now so the installer shows friendly labels instead of bare block devices —
# it will re-format whatever you tell it to format; that is harmless.
mkfs.vfat -F32 -n ESP           "${DEV}p1"
mkfs.ext4 -F   -L ubuntu-root   "${DEV}p2"
mkfs.ext4 -F   -L ubuntu-var    "${DEV}p3"
mkfs.ext4 -F   -L docker        "${DEV}p4"
mkfs.ext4 -F   -L home          "${DEV}p5"

# Reserved-blocks: 5% of 400G/1.5T is 95G thrown away for a root-emergency margin that
# only matters on /. Same call as prod.
tune2fs -m 1 "${DEV}p4"
tune2fs -m 1 "${DEV}p5"

echo
lsblk -o NAME,SIZE,FSTYPE,LABEL,PARTLABEL "$DEV"
echo
echo "Done. Next: §3 physical (unplug the SATA data cable), then boot the 26.04 USB."
