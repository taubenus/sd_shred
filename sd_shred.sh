#!/usr/bin/env bash
# Headerless crypto-erase: one full pass via dm-crypt plain with a random key.
# Writes through dm-crypt (slow but correct) and shows final device status.

set -euo pipefail

DEVICE="${1-}"
[[ -z "$DEVICE" || ! -b "$DEVICE" ]] && { echo "Usage: sudo $0 /dev/sdX"; exit 1; }

DEV_TYPE="$(lsblk -no TYPE "$DEVICE" 2>/dev/null || true)"
if [[ "$DEV_TYPE" != "disk" ]]; then
  echo "❌ Refusing to run on $DEVICE (type: ${DEV_TYPE:-unknown})."
  echo "👉 Please pass the whole device (e.g., /dev/sda), not a partition (e.g., /dev/sda1)."
  exit 1
fi

echo "⚠️  This will overwrite ALL sectors on $DEVICE through dm-crypt (slow, but correct)."
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
# oflag=direct avoids page cache; sync to be sure data is on the device.
dd if=/dev/zero of="/dev/mapper/$MAP" bs=4M status=progress oflag=direct conv=fsync

# Tear down: key vanishes with the mapping
cryptsetup close "$MAP"
wipefs -a "$DEVICE" || true

echo "✅ Done: prior plaintext is now unrecoverable (headerless crypto-erase completed)."
echo
echo "📦 Current device state:"
lsblk -o NAME,TYPE,SIZE,FSTYPE,MOUNTPOINT | grep -E "$(basename "$DEVICE")"
