# sd_shred
A shell script that safely erases a sd flash drive. It creates a headerless dm-crypt plain mapping with a random throwaway key and writes a full pass of zeroes through that mapping.
