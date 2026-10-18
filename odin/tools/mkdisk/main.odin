package mkdisk

// mkdisk: create a blank disk image for the emulator.
//
//   odin build odin/tools/mkdisk -out:mkdisk
//   ./mkdisk work.dsk                  35 track single sided JVC (DECB size)
//   ./mkdisk -t 40 -s 2 big.dsk        40 tracks, double sided
//
// Every sector is filled with 0xFF, which DECB sees as an empty, formatted disk
// (DIR works at once; DSKINI is not needed, though it is harmless).

import "core:fmt"
import "core:os"
import "core:strconv"
import "../../disk"

main :: proc() {
	tracks := disk.DEFAULT_TRACKS
	sides := 1
	force := false
	path := ""

	args := os.args[1:]
	for i := 0; i < len(args); i += 1 {
		switch args[i] {
		case "-t", "--tracks":
			i += 1
			if i >= len(args) {usage()}
			v, ok := strconv.parse_int(args[i])
			if !ok || (v != 35 && v != 40 && v != 80) {fail("tracks must be 35, 40 or 80")}
			tracks = v
		case "-s", "--sides":
			i += 1
			if i >= len(args) {usage()}
			v, ok := strconv.parse_int(args[i])
			if !ok || (v != 1 && v != 2) {fail("sides must be 1 or 2")}
			sides = v
		case "-f", "--force":
			force = true
		case "-h", "--help":
			usage()
		case:
			if len(args[i]) > 0 && args[i][0] == '-' {usage()}
			if path != "" {usage()}
			path = args[i]
		}
	}
	if path == "" {usage()}

	if err := disk.create_blank(path, tracks, sides, force); err != .None {
		if err == .Exists {
			fail(fmt.tprintf("%s already exists (use -f to overwrite)", path))
		}
		fail(disk.error_text(err))
	}
	fmt.printfln("created %s: %d tracks, %d side(s), %d bytes", path, tracks, sides, tracks * sides * disk.DEFAULT_SECTORS * 256 + (2 if sides == 2 else 0))
}

usage :: proc() {
	fmt.eprintln("usage: mkdisk [-t 35|40|80] [-s 1|2] [-f] <file.dsk>")
	os.exit(2)
}

fail :: proc(msg: string) {
	fmt.eprintln("mkdisk:", msg)
	os.exit(1)
}
