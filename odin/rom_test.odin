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

// ---------------------------------------------------------------- rom/boot.asm

screen_row :: proc(m: ^Machine, row: int) -> string {
	lines := strings.split(screen_text(m), "\n", context.temp_allocator)
	return strings.trim_right(lines[row], " ")
}

// Raw VDG code at a screen cell.
screen_code :: proc(m: ^Machine, row, col: int) -> u8 {
	voff := (int(m.gime_regs[0x9D]) << 8 | int(m.gime_regs[0x9E])) & 0xE0FF
	start := (voff * 8 + int(m.sam_dis_offset) * 512) & (len(m.ram) - 1)
	return m.ram[start + row * 32 + col]
}

boot_machine :: proc(t: ^testing.T) -> ^Machine {
	m := asm_rom_machine(t, "rom/boot.asm")
	if m == nil {return nil}
	for _ in 0 ..< 5 {machine_run_frame(m)}
	return m
}

// Assemble `body` at $0600, run it on the booted machine until it reaches its
// "halt" label. The program calls ROM routines through the jump table.
run_ram_program :: proc(t: ^testing.T, m: ^Machine, body: string) -> bool {
	res := asm6809.assemble_text("ram.asm", body)
	defer asm6809.destroy(&res)
	if len(res.errors) > 0 {
		testing.expectf(t, false, "%s", asm6809.format_errors(&res, context.temp_allocator))
		return false
	}
	for addr in 0 ..< 0x8000 {
		if res.written[addr] {mem_write8(m, u16(addr), res.mem[addr])}
	}
	halt, _ := asm6809.symbol_value(&res, "halt")
	m.cpu.sync_waiting = false // the monitor sleeps in SYNC while it waits for a key
	m.cpu.pc = 0x0600
	for _ in 0 ..< 2_000_000 {
		if int(m.cpu.pc) == halt {return true}
		cpu_exec(&m.cpu, 1)
	}
	testing.expectf(t, false, "program did not halt (pc=$%04X)", m.cpu.pc)
	return false
}

BLANK :: 0x60 // VDG code of a normal-video space (rom/hw.asm)

API_CLS :: "$8003"
API_PUTC :: "$8006"
API_PUTS :: "$8009"
API_NEWLINE :: "$800C"
API_PUTHEX8 :: "$800F"
API_PUTHEX16 :: "$8012"

@(test)
boot_rom_shows_banner_and_prompt :: proc(t: ^testing.T) {
	m := boot_machine(t)
	if m == nil {return}
	defer test_machine_free(m)
	testing.expect_value(t, screen_row(m, 0), "COCO 3 OPEN ROM V0.1")
	testing.expect_value(t, screen_row(m, 1), "ORIGINAL BOOT ROM, GPLV3")
	testing.expect_value(t, screen_row(m, 2), "H FOR HELP")
	testing.expect_value(t, screen_row(m, 3), "")
	testing.expect_value(t, screen_row(m, 4), ">")
	// the cursor is the cell after the prompt, shown in inverse video
	testing.expect_value(t, screen_code(m, 4, 0), 0x40 | '>' & 0x3F)
	testing.expect_value(t, screen_code(m, 4, 1), BLANK ~ 0x40)
	// boot state: IRQ on (vertical sync tick), FIRQ masked, SAM/GIME set up for the compat text screen
	testing.expect(t, !flag(&m.cpu, .I) && flag(&m.cpu, .F))
	testing.expect_value(t, m.sam_dis_offset, 2)
	testing.expect_value(t, m.gime_regs[0x90], 0x80)
}

@(test)
boot_rom_console_routines :: proc(t: ^testing.T) {
	m := boot_machine(t)
	if m == nil {return}
	defer test_machine_free(m)
	ok := run_ram_program(t, m, `
	org $0600
	jsr $8003		; cls
	ldx #msg
	jsr $8009		; puts
	lda #$A5
	jsr $800F		; puthex8
	ldd #$BEEF
	jsr $8012		; puthex16
	jsr $800C		; newline
	lda #'x
	jsr $8006		; putc
	lda #$08		; backspace erases the x
	jsr $8006
	lda #'Z
	jsr $8006
	lda #$0A		; ignored
	jsr $8006
halt	bra halt
msg	fcb "Hi",13,0
`)
	if !ok {return}
	testing.expect_value(t, screen_row(m, 0), "HI")
	testing.expect_value(t, screen_row(m, 1), "A5BEEF")
	testing.expect_value(t, screen_row(m, 2), "Z")
	testing.expect_value(t, screen_code(m, 0, 0), 0x48) // 'H': normal video
	testing.expect_value(t, screen_code(m, 0, 1), 0x09) // 'i': inverse upper case
	testing.expect_value(t, screen_code(m, 2, 1), BLANK ~ 0x40) // cursor after the Z
}

@(test)
boot_rom_putc_preserves_registers :: proc(t: ^testing.T) {
	m := boot_machine(t)
	if m == nil {return}
	defer test_machine_free(m)
	ok := run_ram_program(t, m, `
	org $0600
	ldb #$77
	ldx #$5678
	ldy #$9ABC
	ldu #$1357
	lda #'Q
	jsr $8006
	jsr $800C
	ldd #$BEEF
	jsr $8012
	ldx #$5678
	jsr $8009
halt	bra halt
`)
	if !ok {return}
	testing.expect_value(t, m.cpu.b, 0xEF)
	testing.expect_value(t, m.cpu.a, 0xBE)
	testing.expect_value(t, m.cpu.y, 0x9ABC)
	testing.expect_value(t, m.cpu.u, 0x1357)
}

@(test)
boot_rom_wraps_and_scrolls :: proc(t: ^testing.T) {
	m := boot_machine(t)
	if m == nil {return}
	defer test_machine_free(m)
	ok := run_ram_program(t, m, `
	org $0600
	jsr $8003
	ldb #40
wrap	lda #'A
	jsr $8006
	decb
	bne wrap
	jsr $8003
	ldb #0
lines	tfr b,a
	adda #'A
	jsr $8006
	jsr $800C
	incb
	cmpb #20
	bne lines
halt	bra halt
`)
	if !ok {return}
	// 20 lines were printed on a 16 row screen: F..T remain, cursor on the last row
	testing.expect_value(t, screen_row(m, 0), "F")
	testing.expect_value(t, screen_row(m, 14), "T")
	testing.expect_value(t, screen_row(m, 15), "")
	testing.expect_value(t, screen_code(m, 15, 0), BLANK ~ 0x40)

	// 40 characters wrap after 32 columns
	ok = run_ram_program(t, m, `
	org $0600
	jsr $8003
	ldb #40
wrap	lda #'A
	jsr $8006
	decb
	bne wrap
halt	bra halt
`)
	if !ok {return}
	testing.expect_value(t, screen_row(m, 0), "AAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAA")
	testing.expect_value(t, screen_row(m, 1), "AAAAAAAA")

	// filling the last cell of the screen scrolls
	ok = run_ram_program(t, m, `
	org $0600
	jsr $8003
	ldx #0
fill	lda #'B
	jsr $8006
	leax 1,x
	cmpx #512
	bne fill
halt	bra halt
`)
	if !ok {return}
	testing.expect_value(t, screen_row(m, 14), "BBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBB")
	testing.expect_value(t, screen_row(m, 15), "")
}

// ---------------------------------------------------------------- keyboard and monitor

// Type text on the emulated keyboard (CoCo style: unshifted letters are upper
// case) and let the ROM process it.
type_text :: proc(m: ^Machine, text: string) {
	saved := paste_enter_frames
	paste_enter_frames = 3
	defer paste_enter_frames = saved
	paste_text(m, text)
	for paste_active(m) {
		paste_step(m)
		machine_run_frame(m)
	}
	for _ in 0 ..< 8 {machine_run_frame(m)}
}

expect_screen_contains :: proc(t: ^testing.T, m: ^Machine, needle: string, loc := #caller_location) {
	text := screen_text(m)
	testing.expectf(t, strings.contains(text, needle), "screen lacks %q:\n%s", needle, text, loc = loc)
}

// Is there a screen row with exactly this text?
expect_row :: proc(t: ^testing.T, m: ^Machine, row: string, loc := #caller_location) {
	for r in 0 ..< 16 {
		if screen_row(m, r) == row {return}
	}
	testing.expectf(t, false, "no screen row %q:\n%s", row, screen_text(m), loc = loc)
}

@(test)
monitor_fill_and_dump :: proc(t: ^testing.T) {
	m := boot_machine(t)
	if m == nil {return}
	defer test_machine_free(m)
	type_text(m, "F 0600 060F AA\nD 0600 10\n")
	expect_screen_contains(t, m, "0600 AA AA AA AA AA AA AA AA")
	expect_screen_contains(t, m, "0608 AA AA AA AA AA AA AA AA")
	testing.expect_value(t, mem_read8(m, 0x0600), 0xAA)
	testing.expect_value(t, mem_read8(m, 0x060F), 0xAA)
	testing.expect(t, mem_read8(m, 0x0610) != 0xAA)
}

@(test)
monitor_modify_copy_and_lower_case :: proc(t: ^testing.T) {
	m := boot_machine(t)
	if m == nil {return}
	defer test_machine_free(m)
	type_text(m, "M 0620 01 02 03 04 05\n")
	for i in 0 ..< 5 {testing.expect_value(t, mem_read8(m, u16(0x620 + i)), u8(i + 1))}
	type_text(m, "C 0620 0622 5\n") // overlapping, destination above
	for i in 0 ..< 5 {testing.expect_value(t, mem_read8(m, u16(0x622 + i)), u8(i + 1))}
	type_text(m, "C 0622 0620 5\n") // overlapping, destination below
	for i in 0 ..< 5 {testing.expect_value(t, mem_read8(m, u16(0x620 + i)), u8(i + 1))}
	// shifted letters are lower case; commands and digits accept both
	type_text(m, "m $0630 0a Ff\n")
	testing.expect_value(t, mem_read8(m, 0x0630), 0x0A)
	testing.expect_value(t, mem_read8(m, 0x0631), 0xFF)
	type_text(m, "M 0630\n") // shows the byte
	expect_row(t, m, "0A")
}

@(test)
monitor_go_swi_and_registers :: proc(t: ^testing.T) {
	m := boot_machine(t)
	if m == nil {return}
	defer test_machine_free(m)
	type_text(m, "M 0630 86 55 39\nG 0630\nR\n") // lda #$55 ; rts
	expect_screen_contains(t, m, "A=55 B=30")
	// a routine ending in SWI lands back in the monitor too
	type_text(m, "M 0640 C6 77 3F\nG 0640\n") // ldb #$77 ; swi
	expect_screen_contains(t, m, "SWI AT 0642")
	type_text(m, "R\n")
	expect_screen_contains(t, m, "B=77")
	type_text(m, "F 0650 0650 5A\n") // and it still takes commands
	testing.expect_value(t, mem_read8(m, 0x0650), 0x5A)
}

@(test)
monitor_ticks_errors_help_backspace :: proc(t: ^testing.T) {
	m := boot_machine(t)
	if m == nil {return}
	defer test_machine_free(m)
	for _ in 0 ..< 20 {machine_run_frame(m)}
	ticks := int(mem_read8(m, 7)) << 8 | int(mem_read8(m, 8))
	testing.expect(t, ticks >= 20, "the tick counter did not run")
	type_text(m, "Z\n")
	expect_row(t, m, "?")
	type_text(m, "F 0600 05 1\n") // end below start
	expect_row(t, m, "?")
	type_text(m, "H\n")
	expect_screen_contains(t, m, "NUMBERS ARE HEX")
	// BACKSPACE edits the line: "H", back, "T" is the T command
	type_text(m, "")
	type_text(m, "H")
	tap_key(m, .BACKSPACE)
	type_text(m, "T\n")
	expect_screen_contains(t, m, "TICKS 0000")
}

@(test)
keyboard_repeat_and_cursor_blink :: proc(t: ^testing.T) {
	m := boot_machine(t)
	if m == nil {return}
	defer test_machine_free(m)
	// the cursor cell takes both values while the system idles
	seen: [256]bool
	for _ in 0 ..< 80 {
		machine_run_frame(m)
		seen[screen_code(m, 4, 1)] = true
	}
	testing.expect(t, seen[BLANK] && seen[BLANK ~ 0x40], "cursor does not blink")
	// hold A down: one character at once, then repeats
	machine_key_event(m, .A, true)
	for _ in 0 ..< 100 {machine_run_frame(m)}
	machine_key_event(m, .A, false)
	for _ in 0 ..< 8 {machine_run_frame(m)}
	row := screen_row(m, 4)
	testing.expectf(t, strings.count(row, "A") >= 8, "held key gave %q", row)
}
