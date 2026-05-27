# sd_shred
A shell script that safely erases a sd flash drive. 

It creates a headerless dm-crypt plain mapping with a random throwaway key, i.e. the key is not stored on the disk.
It then writes a full pass of zeroes through that mapping.
The encrypted zeroes are thereafter indistinguishable from random.

usage: ./sd_shred.sh [device]

If no device is provided, the script shows an interactive list of eligible disks and asks the user to choose the drive to encrypt and overwrite.
The currently running system disk is excluded from that list by tracing the backing disks for `/`, `/boot`, and `/boot/efi`.
After the crypto-erase finishes, `sd_shred.sh` calls `sd_fat32.sh` for the same drive and creates one FAT32 partition with the label prompted before erasing.

note: pass a whole device (e.g. /dev/sda), not a partition (e.g. /dev/sda1)

For a desktop starter, call the script directly instead of prefixing it with `sudo`.
Use the absolute path, for example:

`/home/your-user/Scripts/sd_shred/sd_shred.sh`

The script will prompt for sudo itself when it needs root privileges.

## FAT32 SD card formatter

`sd_fat32.sh` creates one primary `0c` Win95 FAT32 (LBA) partition using the maximum available space on the given SD card, then formats it with `mkfs.vfat -F32`.

usage: sudo ./sd_fat32.sh /dev/device LABEL
