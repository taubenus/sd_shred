#!/usr/bin/env bash
# Create one Win95 FAT32 (LBA) partition that spans an SD card and format it.

set -euo pipefail

usage() {
  echo "Usage: sudo $0 [--yes] /dev/device LABEL"
  echo "Example: sudo $0 /dev/sdb SDCARD"
}

trim() {
  local value="${1-}"
  value="${value#"${value%%[![:space:]]*}"}"
  value="${value%"${value##*[![:space:]]}"}"
  printf '%s' "$value"
}

lsblk_pair_value() {
  local line="${1-}"
  local key="${2-}"
  local rest

  rest="${line#*${key}=\"}"
  [[ "$rest" != "$line" ]] || return 1
  printf '%s' "${rest%%\"*}"
}

partition_path_for() {
  local disk="${1-}"

  case "$disk" in
    *[0-9])
      printf '%sp1' "$disk"
      ;;
    *)
      printf '%s1' "$disk"
      ;;
  esac
}

require_command() {
  local command_name="${1-}"

  if ! command -v "$command_name" >/dev/null 2>&1; then
    echo "Missing required command: $command_name" >&2
    exit 1
  fi
}

is_system_disk() {
  local disk="${1-}"
  local disk_name mountpoint source parent line path pkname dev_type mountpoints mount

  disk_name="$(basename "$disk")"

  for mountpoint in / /boot /boot/efi; do
    source="$(findmnt -nro SOURCE "$mountpoint" 2>/dev/null || true)"
    source="$(trim "$source")"
    [[ -n "$source" ]] || continue

    while read -r parent dev_type; do
      [[ "$dev_type" == "disk" && "$parent" == "$disk" ]] && return 0
    done < <(lsblk -s -nro PATH,TYPE "$source" 2>/dev/null || true)
  done

  while IFS= read -r line; do
    path="$(lsblk_pair_value "$line" "PATH" || true)"
    pkname="$(lsblk_pair_value "$line" "PKNAME" || true)"
    dev_type="$(lsblk_pair_value "$line" "TYPE" || true)"
    mountpoints="$(lsblk_pair_value "$line" "MOUNTPOINTS" || true)"

    [[ -n "$path" && -n "$dev_type" && -n "$mountpoints" ]] || continue

    for mount in / /boot /boot/efi; do
      [[ "$mountpoints" == "$mount" ]] || continue
      [[ "$dev_type" == "disk" && "$path" == "$disk" ]] && return 0
      [[ -n "$pkname" && "$pkname" == "$disk_name" ]] && return 0
    done
  done < <(lsblk -P -o PATH,PKNAME,TYPE,MOUNTPOINTS 2>/dev/null || true)

  return 1
}

device_type_for() {
  local disk="${1-}"
  local dev_type path

  dev_type="$(lsblk -ndo TYPE "$disk" 2>/dev/null || true)"
  dev_type="$(trim "$dev_type")"
  if [[ -n "$dev_type" ]]; then
    printf '%s' "$dev_type"
    return 0
  fi

  while read -r path dev_type; do
    [[ "$path" == "$disk" ]] || continue
    printf '%s' "$dev_type"
    return 0
  done < <(lsblk -dnpo PATH,TYPE 2>/dev/null || true)
}

ASSUME_YES=0
if [[ "${1-}" == "--yes" || "${1-}" == "-y" ]]; then
  ASSUME_YES=1
  shift
fi

DEVICE="${1-}"
LABEL="${2-}"

if [[ -z "$DEVICE" || -z "$LABEL" || $# -ne 2 ]]; then
  usage
  exit 1
fi

for command_name in findmnt lsblk sfdisk mkfs.vfat partprobe udevadm; do
  require_command "$command_name"
done

if (( EUID != 0 )); then
  echo "Run this script with sudo/root privileges." >&2
  exit 1
fi

if [[ ! -b "$DEVICE" ]]; then
  echo "Not a block device: $DEVICE" >&2
  usage
  exit 1
fi

DEV_TYPE="$(device_type_for "$DEVICE")"
if [[ "$DEV_TYPE" != "disk" ]]; then
  echo "Refusing to run on $DEVICE (type: ${DEV_TYPE:-unknown})." >&2
  echo "Pass the whole SD card device, e.g. /dev/sdb, not /dev/sdb1." >&2
  exit 1
fi

if is_system_disk "$DEVICE"; then
  echo "Refusing to partition system disk: $DEVICE" >&2
  exit 1
fi

if (( ${#LABEL} > 11 )); then
  echo "FAT32 labels are limited to 11 characters." >&2
  exit 1
fi

MOUNTED_INFO="$(lsblk -rno NAME,MOUNTPOINT "$DEVICE" | awk '$2!="" {print "/dev/"$1" -> "$2}')"
if [[ -n "$MOUNTED_INFO" ]]; then
  echo "Device or partitions are mounted:" >&2
  echo "$MOUNTED_INFO" >&2
  echo "Unmount them before retrying." >&2
  exit 1
fi

PARTITION="$(partition_path_for "$DEVICE")"

echo "This will erase the partition table on $DEVICE and create:"
echo "  $PARTITION: primary type 0c (Win95 FAT32 LBA), maximum available space"
echo "Then it will run: mkfs.vfat -F32 -n \"$LABEL\" \"$PARTITION\""
if (( ASSUME_YES == 0 )); then
  read -rp "Type YES to proceed: " CONFIRM
  if [[ "$CONFIRM" != "YES" ]]; then
    echo "Aborted."
    exit 1
  fi
fi

sfdisk --wipe always "$DEVICE" <<SFDISK
label: dos
unit: sectors

,,c
SFDISK

partprobe "$DEVICE"
udevadm settle

if [[ ! -b "$PARTITION" ]]; then
  echo "Expected partition was not created: $PARTITION" >&2
  exit 1
fi

mkfs.vfat -F32 -n "$LABEL" "$PARTITION"

echo "Done."
lsblk -o NAME,TYPE,SIZE,FSTYPE,LABEL,MOUNTPOINT "$DEVICE"
