package mkboot

// mkboot: assemble a program and put it on a disk the open ROM can boot (B).
//
//   odin build odin/tools/mkboot -out:mkboot
//   ./mkboot programs/snake.asm programs/snake.dsk
//
// The program is assembled with asm6809; everything it writes becomes the
// payload (at most 17 sectors, track 0 sectors 2...), loaded at its lowest
// address. The entry point is the label `start` if there is one, else the
// lowest address. Track 0 sector 1 gets the boot header described in
// rom/README.md ('O' 'B', load address, sector count, entry address).

import "core:fmt"
import "core:os"
import "../../asm6809"
import "../../disk"

fail :: proc(format: string, args: ..any) {
	fmt.eprintfln(format, ..args)
	os.exit(1)
}

main :: proc() {
	if len(os.args) != 3 {
		fmt.eprintln("usage: mkboot program.asm disk.dsk")
		os.exit(2)
	}
	src, out := os.args[1], os.args[2]

	r := asm6809.assemble_file(src)
	if len(r.errors) > 0 {
		fmt.eprint(asm6809.format_errors(&r))
		os.exit(1)
	}
	if r.hi < r.lo {fail("%s produced no code", src)}
	load := r.lo
	size := r.hi - r.lo + 1
	sectors := (size + 255) / 256
	if sectors > 17 {fail("%d bytes do not fit the boot area (17 sectors of 256 bytes)", size)}
	entry, found := asm6809.symbol_value(&r, "start")
	if !found {entry = load}

	if err := disk.create_blank(out, overwrite = true); err != .None {
		fail("cannot create %s: %s", out, disk.error_text(err))
	}
	img, err := disk.mount(out)
	if err != .None {fail("cannot open %s: %s", out, disk.error_text(err))}
	defer disk.unmount(&img)

	boot: [256]u8
	for i in 0 ..< 256 {boot[i] = 0xFF}
	boot[0], boot[1] = 'O', 'B'
	boot[2], boot[3] = u8(load >> 8), u8(load)
	boot[4] = u8(sectors)
	boot[5], boot[6] = u8(entry >> 8), u8(entry)
	if !disk.write_sector(&img, 0, 0, 1, boot[:]) {fail("cannot write the boot sector")}
	for s in 0 ..< sectors {
		buf: [256]u8
		for i in 0 ..< 256 {
			a := load + s * 256 + i
			buf[i] = r.mem[a] if a <= r.hi else 0
		}
		if !disk.write_sector(&img, 0, 0, 2 + s, buf[:]) {fail("cannot write sector %d", 2 + s)}
	}
	fmt.printfln("%s: %d bytes at $%04X, entry $%04X, %d sectors", out, size, load, entry, sectors)
}
