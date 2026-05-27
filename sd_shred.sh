#!/usr/bin/env bash
# Headerless crypto-erase: one full pass via dm-crypt plain with a random key.
# Writes through dm-crypt (slow but correct) and shows final device status.

set -euo pipefail

usage() {
  echo "Usage: sudo $0 [device]"
  echo "If no device is provided, you will be prompted to select the target drive."
}

trim() {
  local value="${1-}"
  value="${value#"${value%%[![:space:]]*}"}"
  value="${value%"${value##*[![:space:]]}"}"
  printf '%s' "$value"
}

declare -a SYSTEM_DISKS=()
declare -A SYSTEM_DISK_SET=()

add_system_disk() {
  local disk="${1-}"
  [[ -n "$disk" ]] || return 0
  [[ -n "${SYSTEM_DISK_SET[$disk]+x}" ]] && return 0
  SYSTEM_DISK_SET["$disk"]=1
  SYSTEM_DISKS+=("$disk")
}

lsblk_pair_value() {
  local line="${1-}"
  local key="${2-}"
  local rest

  rest="${line#*${key}=\"}"
  [[ "$rest" != "$line" ]] || return 1
  printf '%s' "${rest%%\"*}"
}

collect_parent_disks() {
  local source="${1-}"
  [[ -n "$source" ]] || return 0

  while read -r path dev_type; do
    [[ "$dev_type" == "disk" ]] && add_system_disk "$path"
  done < <(lsblk -s -nro PATH,TYPE "$source" 2>/dev/null || true)
}

discover_system_disks_from_lsblk_mounts() {
  local line path pkname dev_type mountpoints mount

  while IFS= read -r line; do
    path="$(lsblk_pair_value "$line" "PATH" || true)"
    pkname="$(lsblk_pair_value "$line" "PKNAME" || true)"
    dev_type="$(lsblk_pair_value "$line" "TYPE" || true)"
    mountpoints="$(lsblk_pair_value "$line" "MOUNTPOINTS" || true)"

    [[ -n "$path" && -n "$dev_type" && -n "$mountpoints" ]] || continue

    for mount in / /boot /boot/efi; do
      [[ "$mountpoints" == "$mount" ]] || continue
      if [[ "$dev_type" == "disk" ]]; then
        add_system_disk "$path"
      elif [[ -n "$pkname" ]]; then
        add_system_disk "/dev/$pkname"
      fi
    done
  done < <(lsblk -P -o PATH,PKNAME,TYPE,MOUNTPOINTS 2>/dev/null || true)
}

discover_system_disks() {
  local mountpoint source

  for mountpoint in / /boot /boot/efi; do
    source="$(findmnt -nro SOURCE "$mountpoint" 2>/dev/null || true)"
    source="$(trim "$source")"
    [[ -n "$source" ]] && collect_parent_disks "$source"
  done

  discover_system_disks_from_lsblk_mounts
}

is_system_disk() {
  local disk="${1-}"
  [[ -n "${SYSTEM_DISK_SET[$disk]+x}" ]]
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

describe_disk() {
  local disk="${1-}"
  local size model transport labels

  size="$(trim "$(lsblk -ndo SIZE "$disk" 2>/dev/null || true)")"
  model="$(trim "$(lsblk -ndo MODEL "$disk" 2>/dev/null || true)")"
  transport="$(trim "$(lsblk -ndo TRAN "$disk" 2>/dev/null || true)")"
  labels="$(describe_disk_labels "$disk")"

  printf '%s' "${size:-unknown size}"
  [[ -n "$labels" ]] && printf ' | labels: %s' "$labels"
  [[ -n "$transport" ]] && printf ' | %s' "$transport"
  [[ -n "$model" ]] && printf ' | %s' "$model"
}

describe_disk_labels() {
  local disk="${1-}"
  local disk_name line path pkname label partlabel value
  local -a labels=()

  disk_name="$(basename "$disk")"

  while IFS= read -r line; do
    path="$(lsblk_pair_value "$line" "PATH" || true)"
    pkname="$(lsblk_pair_value "$line" "PKNAME" || true)"
    label="$(lsblk_pair_value "$line" "LABEL" || true)"
    partlabel="$(lsblk_pair_value "$line" "PARTLABEL" || true)"

    [[ "$path" == "$disk" || "$pkname" == "$disk_name" ]] || continue

    for value in "$label" "$partlabel"; do
      [[ -n "$value" ]] || continue
      labels+=("$value")
    done
  done < <(lsblk -P -o PATH,PKNAME,LABEL,PARTLABEL 2>/dev/null || true)

  if (( ${#labels[@]} > 0 )); then
    local IFS=', '
    printf '%s' "${labels[*]}"
  fi
}

prompt_fat32_label() {
  local label

  while true; do
    read -rp "Enter FAT32 label for the reformatted drive (max 11 chars): " label
    label="$(trim "$label")"

    if [[ -z "$label" ]]; then
      echo "❌ Label cannot be empty."
    elif (( ${#label} > 11 )); then
      echo "❌ FAT32 labels are limited to 11 characters."
    else
      FAT32_LABEL="$label"
      return 0
    fi
  done
}

select_device() {
  local choice disk dev_type
  local -a candidates=()

  while read -r disk dev_type; do
    [[ "$dev_type" == "disk" ]] || continue
    is_system_disk "$disk" && continue
    candidates+=("$disk")
  done < <(lsblk -dnpo PATH,TYPE)

  if (( ${#candidates[@]} == 0 )); then
    echo "❌ No eligible non-system disks were found."
    exit 1
  fi

  echo "🧭 Select the drive to encrypt and overwrite:"
  for i in "${!candidates[@]}"; do
    printf '  %d) %s | %s\n' "$((i + 1))" "${candidates[$i]}" "$(describe_disk "${candidates[$i]}")"
  done
  if (( ${#SYSTEM_DISKS[@]} > 0 )); then
    echo "🔒 Excluded system disks: ${SYSTEM_DISKS[*]}"
  fi

  while true; do
    read -rp "Select drive number to encrypt and overwrite (or q to quit): " choice
    case "$choice" in
      q|Q)
        echo "Aborted."
        exit 1
        ;;
      ''|*[!0-9]*)
        echo "❌ Invalid selection."
        ;;
      *)
        if (( choice >= 1 && choice <= ${#candidates[@]} )); then
          DEVICE="${candidates[$((choice - 1))]}"
          return 0
        fi
        echo "❌ Invalid selection."
        ;;
    esac
  done
}

DEVICE="${1-}"
FAT32_LABEL=""
discover_system_disks

if [[ -z "$DEVICE" ]]; then
  select_device
elif [[ ! -b "$DEVICE" ]]; then
  usage
  exit 1
fi

DEV_TYPE="$(device_type_for "$DEVICE")"
if [[ "$DEV_TYPE" != "disk" ]]; then
  echo "❌ Refusing to run on $DEVICE (type: ${DEV_TYPE:-unknown})."
  echo "👉 Please pass the whole device (e.g., /dev/sda), not a partition (e.g., /dev/sda1)."
  exit 1
fi

if is_system_disk "$DEVICE"; then
  echo "❌ Refusing to run on system disk $DEVICE."
  if (( ${#SYSTEM_DISKS[@]} > 0 )); then
    echo "🔒 System disks: ${SYSTEM_DISKS[*]}"
  fi
  exit 1
fi

prompt_fat32_label

SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
FAT32_SCRIPT="$SCRIPT_DIR/sd_fat32.sh"
if [[ ! -x "$FAT32_SCRIPT" ]]; then
  echo "❌ Missing or non-executable formatter script: $FAT32_SCRIPT"
  exit 1
fi

echo "⚠️  This will overwrite ALL sectors on $DEVICE through dm-crypt (slow, but correct)."
echo "Afterwards it will repartition $DEVICE as FAT32 with label \"$FAT32_LABEL\"."
read -rp "Type YES to proceed: " CONFIRM
[[ "$CONFIRM" != "YES" ]] && { echo "Aborted."; exit 1; }

# Safety: refuse if in use
MOUNTED_INFO="$(lsblk -rno NAME,MOUNTPOINT "$DEVICE" | awk '$2!="" {print "/dev/"$1" -> "$2}')"
if [[ -n "$MOUNTED_INFO" ]]; then
  echo "❌ Device/partitions are in use:"; echo "$MOUNTED_INFO"
  echo "👉 Unmount (and swapoff) before retrying."; exit 1
fi

# aes-xts-plain64 with 512-bit key (256-bit per XTS half)
MAP=wipe_crypt
cleanup() {
  # Best-effort removal to avoid leaving the mapping around
  cryptsetup close "$MAP" 2>/dev/null || dmsetup remove "$MAP" 2>/dev/null || true
}
trap cleanup EXIT

# Ensure no old mapping is left behind
cryptsetup close "$MAP" 2>/dev/null || dmsetup remove -f "$MAP" 2>/dev/null || true

# Create a headerless dm-crypt mapping with a throwaway random key
cryptsetup open --type plain \
  --cipher aes-xts-plain64 --key-size 512 \
  --key-file /dev/urandom \
  "$DEVICE" "$MAP"

# One full pass. Zeros are fine; on disk they become indistinguishable-from-random.
# Use an explicit size to avoid ENOSPC. oflag=direct avoids page cache; sync to be sure data is on the device.
BS=$((4 * 1024 * 1024))
DEV_BYTES="$(blockdev --getsize64 "$DEVICE")"
SEC_BYTES="$(blockdev --getss "$DEVICE")"
FULL_BLOCKS=$((DEV_BYTES / BS))
REM_BYTES=$((DEV_BYTES % BS))
ALIGN_REM=$((REM_BYTES % SEC_BYTES))

echo "📐 Size: ${DEV_BYTES} bytes | bs=${BS} | full_blocks=${FULL_BLOCKS} | remainder=${REM_BYTES} bytes | sector=${SEC_BYTES}"
if (( ALIGN_REM != 0 )); then
  echo "⚠️  Device size is not a multiple of sector size; tail write will drop direct I/O."
fi

if (( FULL_BLOCKS > 0 )); then
  dd if=/dev/zero of="/dev/mapper/$MAP" bs=$BS count=$FULL_BLOCKS status=progress oflag=direct conv=fsync
fi

if (( REM_BYTES > 0 )); then
  REM_BLOCKS=$((REM_BYTES / SEC_BYTES))
  SEEK_BLOCKS=$((FULL_BLOCKS * BS / SEC_BYTES))
  if (( REM_BLOCKS > 0 )); then
    dd if=/dev/zero of="/dev/mapper/$MAP" bs=$SEC_BYTES count=$REM_BLOCKS seek=$SEEK_BLOCKS oflag=direct conv=fsync status=none
  fi
  if (( ALIGN_REM != 0 )); then
    TAIL_OFFSET=$((FULL_BLOCKS * BS + REM_BLOCKS * SEC_BYTES))
    TAIL_BYTES=$ALIGN_REM
    dd if=/dev/zero of="/dev/mapper/$MAP" bs=1 count=$TAIL_BYTES seek=$TAIL_OFFSET conv=fsync status=none
  fi
fi

# Tear down: key vanishes with the mapping
cryptsetup close "$MAP"
wipefs -a "$DEVICE" || true

echo "✅ Done: prior plaintext is now unrecoverable (headerless crypto-erase completed)."
echo
echo "🧩 Creating one FAT32 partition with label \"$FAT32_LABEL\"..."
"$FAT32_SCRIPT" --yes "$DEVICE" "$FAT32_LABEL"
echo
echo "📦 Current device state:"
lsblk -o NAME,TYPE,SIZE,FSTYPE,LABEL,MOUNTPOINT | grep -E "$(basename "$DEVICE")"
