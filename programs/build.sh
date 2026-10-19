#!/bin/sh
# Build the bootable game disks: programs/snake.dsk (boot it with B in the monitor).
set -e
cd "$(dirname "$0")/.."
odin build odin/tools/mkboot -out:mkboot
for p in snake; do
	./mkboot programs/$p.asm programs/$p.dsk
done
