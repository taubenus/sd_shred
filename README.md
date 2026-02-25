# sd_shred
A shell script that safely erases a sd flash drive. 

It creates a headerless dm-crypt plain mapping with a random throwaway key, i.e. the key is not stored on the disk.
It then writes a full pass of zeroes through that mapping.
The encrypted zeroes are thereafter indistinguishable from random.

usage: sd_shred /dev/sdX

note: pass a device (e.g. /dev/sda), not a partition (e.g. /dev/sda1)
