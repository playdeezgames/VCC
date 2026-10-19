package vcc

// Tests that assemble the ROM sources in rom/ in-process and run them on the
// emulated machine.

import "core:strings"
import "core:testing"
import "asm6809"

// Assemble rom/<name> into a 32K image and boot a machine from it.
asm_rom_machine :: proc(t: ^testing.T, name: string) -> ^Machine {
	r := asm6809.assemble_file(name)
	defer asm6809.destroy(&r)
	if len(r.errors) > 0 {
		testing.expectf(t, false, "%s", asm6809.format_errors(&r, context.temp_allocator))
		return nil
	}
	img := asm6809.image(&r, 0x8000, 0x8000, 0xFF)
	defer delete(img)
	m := new(Machine)
	machine_init(m)
	machine_load_rom(m, img)
	machine_reset(m)
	return m
}

@(test)
hello_rom_shows_message :: proc(t: ^testing.T) {
	m := asm_rom_machine(t, "rom/hello.asm")
	if m == nil {return}
	defer test_machine_free(m)
	for _ in 0 ..< 3 {machine_run_frame(m)}
	text := screen_text(m)
	testing.expectf(t, strings.contains(text, "HELLO FROM OUR OWN ROM"), "screen:\n%s", text)
}
