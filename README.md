# sd_shred
A shell script that safely erases a sd flash drive. 

It creates a headerless dm-crypt plain mapping with a random throwaway key, i.e. the key is not stored on the disk.
It then writes a full pass of zeroes through that mapping.
The encrypted zeroes are thereafter indistinguishable from random.

usage: sd_shred [device]

If no device is provided, the script shows an interactive list of eligible disks and asks the user to choose one.
The currently running system disk is excluded from that list by tracing the backing disks for `/`, `/boot`, and `/boot/efi`.

note: pass a whole device (e.g. /dev/sda), not a partition (e.g. /dev/sda1)
