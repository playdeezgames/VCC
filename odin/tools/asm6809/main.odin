package asm6809_tool

// asm6809: command line wrapper around the assembler package.
//
//   odin build odin/tools/asm6809 -out:asm6809
//   ./asm6809 rom/boot.asm -o rom/ourrom.rom [-l boot.lst] [-s boot.sym]
//             [-b 0x8000] [-n 0x8000] [-f 0xFF] [-I dir]...
//
// The output file is the image of [-b, -b+n) (default: the 32K CoCo 3 ROM at
// $8000), with bytes the source never wrote set to the fill value.

import "core:fmt"
import "core:os"
import "core:strconv"
import "../../asm6809"

usage :: proc() {
	fmt.eprintln("usage: asm6809 in.asm -o out.bin [-l listing] [-s symbols] [-b base] [-n size] [-f fill] [-I dir]")
	os.exit(2)
}

fail :: proc(format: string, args: ..any) {
	fmt.eprintfln(format, ..args)
	os.exit(1)
}

number :: proc(s: string) -> int {
	v, ok := strconv.parse_int(s, 0) // understands 0x.. prefixes
	if !ok {fail("bad number '%s'", s)}
	return v
}

main :: proc() {
	input, output, listing, symbols := "", "", "", ""
	base, size, fill := 0x8000, 0x8000, 0xFF
	dirs: [dynamic]string

	args := os.args[1:]
	for i := 0; i < len(args); i += 1 {
		next :: proc(args: []string, i: ^int) -> string {
			i^ += 1
			if i^ >= len(args) {usage()}
			return args[i^]
		}
		switch args[i] {
		case "-o": output = next(args, &i)
		case "-l": listing = next(args, &i)
		case "-s": symbols = next(args, &i)
		case "-b": base = number(next(args, &i))
		case "-n": size = number(next(args, &i))
		case "-f": fill = number(next(args, &i))
		case "-I": append(&dirs, next(args, &i))
		case "-h", "--help": usage()
		case:
			if len(args[i]) > 0 && args[i][0] == '-' {usage()}
			if input != "" {usage()}
			input = args[i]
		}
	}
	if input == "" || output == "" {usage()}
	if base < 0 || size <= 0 || base + size > 65536 || fill < 0 || fill > 255 {fail("bad -b/-n/-f")}

	r := asm6809.assemble_file(input, {include_dirs = dirs[:]})
	if len(r.errors) > 0 {
		fmt.eprint(asm6809.format_errors(&r))
		os.exit(1)
	}

	img := asm6809.image(&r, base, size, u8(fill))
	if r.lo < base || r.hi >= base + size {
		fmt.eprintfln("warning: code at $%04X-$%04X lies outside the image $%04X-$%04X", r.lo, r.hi, base, base + size - 1)
	}
	if err := os.write_entire_file(output, img); err != nil {fail("cannot write %s", output)}
	if listing != "" {
		if err := os.write_entire_file(listing, transmute([]u8)r.listing); err != nil {fail("cannot write %s", listing)}
	}
	if symbols != "" {
		s := asm6809.format_symbols(&r)
		if err := os.write_entire_file(symbols, transmute([]u8)s); err != nil {fail("cannot write %s", symbols)}
	}
	fmt.printfln("%s: %d bytes written to $%04X-$%04X (%d pass%s)", output, r.hi - r.lo + 1, r.lo, r.hi, r.passes, "" if r.passes == 1 else "es")
}
