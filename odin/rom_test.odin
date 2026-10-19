package vcc

// Tests that assemble the ROM sources in rom/ in-process and run them on the
// emulated machine.

import "core:os"
import "core:strings"
import "core:testing"
import "asm6809"
import "disk"

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
run_ram_program :: proc(t: ^testing.T, m: ^Machine, body: string, timed := false, max_frames := 600) -> bool {
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
	if timed {
		// whole frames, so the scanline events (disk controller, interrupts) run
		for _ in 0 ..< max_frames {
			machine_run_frame(m)
			if int(m.cpu.pc) == halt {return true}
		}
		testing.expectf(t, false, "program did not halt (pc=$%04X)", m.cpu.pc)
		return false
	}
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
	testing.expect_value(t, m.gime_regs[0x90], 0x84) // compat, standard SCS
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

// ---------------------------------------------------------------- disk driver

// Booted ROM machine with a blank disk in drive 0.
disk_rom_machine :: proc(t: ^testing.T, file: string) -> (m: ^Machine, path: string) {
	path = join2(DISK_DIR, file)
	disk.create_blank(path, overwrite = true)
	m = boot_machine(t)
	if m == nil {return}
	m.fdc.enabled = true
	fdc_mount(m, 0, path)
	return
}

disk_rom_free :: proc(m: ^Machine, path: string) {
	test_machine_free(m)
	os.remove(path)
}

// Let the ROM finish a disk command (the motor spin-up alone takes ~40 frames).
settle :: proc(m: ^Machine, frames := 120) {
	for _ in 0 ..< frames {machine_run_frame(m)}
}

@(test)
disk_driver_write_read_and_errors :: proc(t: ^testing.T) {
	m, path := disk_rom_machine(t, "rom_drv.dsk")
	if m == nil {return}
	defer disk_rom_free(m, path)
	ok := run_ram_program(t, m, `
	org $0600
	clr $0A00
	clr $0A01
	ldx #$0800		; pattern 0,1,2,...255
	clrb
fill	stb ,x+
	incb
	bne fill
	lda #0			; write track 5 sector 3
	ldb #5
	ldy #3
	ldx #$0800
	jsr $801E
	bcc w_ok
	sta $0A00
w_ok	lda #0			; read it back to $0900
	ldb #5
	ldy #3
	ldx #$0900
	jsr $801B
	bcc r_ok
	sta $0A01
r_ok	lda #1			; drive 1 has no disk
	ldb #0
	ldy #1
	ldx #$0B00
	jsr $801B
	bcs e1
	lda #$EE
e1	sta $0A02
	lda #0			; sector 40 does not exist
	ldb #0
	ldy #40
	ldx #$0B00
	jsr $801B
	bcs e2
	lda #$EE
e2	sta $0A03
	lda #9			; no such drive
	ldb #0
	ldy #1
	ldx #$0B00
	jsr $801B
	bcs e3
	lda #$EE
e3	sta $0A04
	ldy #$1234		; registers other than A survive
	ldx #$5678
	ldb #$9A
	lda #0
	jsr $801B
halt	bra halt
`, timed = true)
	if !ok {return}
	testing.expect_value(t, mem_read8(m, 0x0A00), 0) // no write error
	testing.expect_value(t, mem_read8(m, 0x0A01), 0)
	testing.expect_value(t, mem_read8(m, 0x0A02), 2) // DE_NOTFOUND
	testing.expect_value(t, mem_read8(m, 0x0A03), 2)
	testing.expect_value(t, mem_read8(m, 0x0A04), 7) // DE_BADARG
	for i in 0 ..< 256 {
		if mem_read8(m, u16(0x0900 + i)) != u8(i) {
			testing.expectf(t, false, "read back byte %d is $%02X", i, mem_read8(m, u16(0x0900 + i)))
			break
		}
	}
	// it really is in the image, at track 5 sector 3
	buf: [256]u8
	disk.read_sector(&m.fdc.drives[0], 0, 5, 3, buf[:])
	for i in 0 ..< 256 {
		if buf[i] != u8(i) {
			testing.expectf(t, false, "image byte %d is $%02X", i, buf[i])
			break
		}
	}
	testing.expect_value(t, m.cpu.x, 0x5678)
	testing.expect_value(t, m.cpu.y, 0x1234)
	testing.expect_value(t, m.cpu.b, 0x9A)
	testing.expect(t, !flag(&m.cpu, .I), "the interrupt mask is restored")
}

@(test)
monitor_disk_load_and_write :: proc(t: ^testing.T) {
	m, path := disk_rom_machine(t, "rom_lw.dsk")
	if m == nil {return}
	defer disk_rom_free(m, path)
	type_text(m, "F 0800 08FF 5A\nW 0 3 2 0800\n")
	settle(m)
	buf: [256]u8
	disk.read_sector(&m.fdc.drives[0], 0, 3, 2, buf[:])
	testing.expect_value(t, buf[0], 0x5A)
	testing.expect_value(t, buf[255], 0x5A)
	type_text(m, "F 0900 09FF 00\nL 0 3 2 0900\n")
	settle(m)
	testing.expect_value(t, mem_read8(m, 0x0900), 0x5A)
	testing.expect_value(t, mem_read8(m, 0x09FF), 0x5A)
	// several sectors: 18 is followed by sector 1 of the next track
	type_text(m, "F 0800 0AFF 77\nW 0 4 12 0800 2\n")
	settle(m)
	disk.read_sector(&m.fdc.drives[0], 0, 4, 18, buf[:])
	testing.expect_value(t, buf[0], 0x77)
	disk.read_sector(&m.fdc.drives[0], 0, 5, 1, buf[:])
	testing.expect_value(t, buf[100], 0x77)
	// errors are reported, and the monitor carries on
	type_text(m, "L 1 0 1 0900\n")
	settle(m)
	expect_row(t, m, "DISK ERROR 02")
	type_text(m, "L 0 0 13 0900\n") // sector 19 is out of range: syntax error
	expect_row(t, m, "?")
	// the motor stops by itself
	settle(m, 300)
	testing.expect(t, !m.fdc.motor, "the motor was left running")
}

@(test)
monitor_boot_from_disk :: proc(t: ^testing.T) {
	m, path := disk_rom_machine(t, "rom_boot.dsk")
	if m == nil {return}
	defer disk_rom_free(m, path)

	type_text(m, "B\n") // a blank disk has no boot sector
	settle(m)
	expect_row(t, m, "NO BOOT")

	// boot sector: signature, load $0800, 1 sector, entry $0800; payload sets a marker
	res := asm6809.assemble_text("payload.asm", "\torg $0800\n\tlda #$42\n\tsta $0A10\n\trts\n")
	defer asm6809.destroy(&res)
	if len(res.errors) > 0 {
		testing.expectf(t, false, "%s", asm6809.format_errors(&res, context.temp_allocator))
		return
	}
	boot: [256]u8
	boot[0], boot[1] = 'O', 'B'
	boot[2], boot[3] = 0x08, 0x00
	boot[4] = 1
	boot[5], boot[6] = 0x08, 0x00
	payload: [256]u8
	for i in 0 ..< 16 {payload[i] = res.mem[0x0800 + i]}
	disk.write_sector(&m.fdc.drives[0], 0, 0, 1, boot[:])
	disk.write_sector(&m.fdc.drives[0], 0, 0, 2, payload[:])
	type_text(m, "B\n")
	settle(m)
	testing.expect_value(t, mem_read8(m, 0x0A10), 0x42)
	expect_row(t, m, ">") // back at the prompt
	// no disk in drive 1
	type_text(m, "B 1\n")
	settle(m)
	expect_row(t, m, "DISK ERROR 02")
}

// ---------------------------------------------------------------- sound

// Steps in the audio stream (a jump of at least 4000 between neighbouring
// samples): a square wave makes two a period. The output filter removes DC only
// slowly, so counting sign changes would miss short tones.
audio_crossings :: proc(m: ^Machine) -> int {
	n := 0
	for i in 1 ..< len(m.audio_samples) {
		if abs(int(m.audio_samples[i].x) - int(m.audio_samples[i - 1].x)) >= 4000 {n += 1}
	}
	return n
}

@(test)
sound_beep_bell_and_tone :: proc(t: ^testing.T) {
	m := boot_machine(t)
	if m == nil {return}
	defer test_machine_free(m)
	machine_enable_audio(m)
	machine_run_frame(m)
	clear(&m.audio_samples)
	ok := run_ram_program(t, m, `
	org $0600
	ldx #$5678
	ldy #$9ABC
	ldb #$77
	jsr $8021		; beep: 100 periods
	lda #$07		; BEL through putc: another 100 periods
	jsr $8006
	ldx #20			; a short higher tone: 10 periods
	ldy #10
	jsr $8024
halt	bra halt
`, timed = true)
	if !ok {return}
	for _ in 0 ..< 4 {machine_run_frame(m)}
	crossings := audio_crossings(m)
	testing.expectf(t, crossings >= 400 && crossings <= 460, "square wave crossings: %d", crossings)
	testing.expect_value(t, m.cpu.x, 20)
	testing.expect_value(t, m.cpu.y, 10)
	testing.expect_value(t, m.cpu.b, 0x77)
	testing.expect_value(t, m.pia1.reg[3] & 0x3F, 0x34) // sound enable put back
	testing.expect_value(t, m.asample, 0) // DAC left at zero
	testing.expect(t, !flag(&m.cpu, .I), "the interrupt mask is restored")
}

@(test)
monitor_sound_command :: proc(t: ^testing.T) {
	m := boot_machine(t)
	if m == nil {return}
	defer test_machine_free(m)
	machine_enable_audio(m)
	clear(&m.audio_samples)
	type_text(m, "S\n")
	settle(m, 20)
	testing.expect(t, audio_crossings(m) >= 150, "S makes the beep")
	clear(&m.audio_samples)
	type_text(m, "S 20 14\n") // 20 loops, 20 periods
	settle(m, 20)
	crossings := audio_crossings(m)
	testing.expectf(t, crossings >= 30 && crossings <= 50, "S with arguments: %d crossings", crossings)
	expect_row(t, m, ">")
}

// ---------------------------------------------------------------- joystick

@(test)
joystick_axes_and_buttons :: proc(t: ^testing.T) {
	m := boot_machine(t)
	if m == nil {return}
	defer test_machine_free(m)
	machine_set_axis(m, .Right_X, 0x2000) // centre
	machine_set_axis(m, .Right_Y, STICK_MAX)
	machine_set_axis(m, .Left_X, 0x1000)
	// Left_Y left at 0: no stick
	machine_set_button(m, BUTTON_LEFT_1 | BUTTON_RIGHT_2, true)
	ok := run_ram_program(t, m, `
	org $0600
	lda #0
	jsr $8027
	sta $0A00
	lda #1
	jsr $8027
	sta $0A01
	lda #2
	jsr $8027
	sta $0A02
	lda #3
	jsr $8027
	sta $0A03
	jsr $802A
	sta $0A04
halt	bra halt
`)
	if !ok {return}
	testing.expect_value(t, mem_read8(m, 0x0A00), 32)
	testing.expect_value(t, mem_read8(m, 0x0A01), 63)
	testing.expect_value(t, mem_read8(m, 0x0A02), 16)
	testing.expect_value(t, mem_read8(m, 0x0A03), 0)
	testing.expect_value(t, mem_read8(m, 0x0A04), 0x06) // left 1 and right 2
	// the multiplexer is back on the sound source and the DAC is quiet
	testing.expect_value(t, get_mux_state(m), 0)
	testing.expect_value(t, m.pia1.reg[0] & 0xFC, 0)
	testing.expect_value(t, m.pia0.reg[3] & 0x3F, 0x35) // vertical sync IRQ still enabled
}

@(test)
monitor_joystick_command :: proc(t: ^testing.T) {
	m := boot_machine(t)
	if m == nil {return}
	defer test_machine_free(m)
	machine_set_axis(m, .Right_X, 0x2000)
	machine_set_axis(m, .Right_Y, 0x3FFF)
	machine_set_axis(m, .Left_X, 0x0400)
	// (a pressed button reads as a key in the keyboard matrix, so none is held while typing)
	type_text(m, "J\n")
	expect_row(t, m, "RX=20 RY=3F LX=04 LY=00")
	expect_row(t, m, "BUTTONS=00")
}

// ---------------------------------------------------------------- tape

TAPE_PROGRAM_SAVE :: `
	org $0600
	ldx #$0800		; 300 bytes of pattern: i*7+3
	ldy #300
	ldb #3
fill	stb ,x+
	addb #7
	leay -1,y
	bne fill
	ldx #hdr
	jsr $802D		; tape_save
	bcc saved
	sta $0A00
	bra halt
saved	clr $0A00
halt	bra halt
hdr	fcb "TESTFILE",'M'
	fdb $0800,300,$0810
`

@(test)
tape_wav_codec :: proc(t: ^testing.T) {
	samples := []u8{128, 200, 50, 128, 255, 0}
	file := wav_encode(samples, 22050)
	defer delete(file)
	got, rate, ok := wav_decode(file)
	defer delete(got)
	testing.expect(t, ok)
	testing.expect_value(t, rate, 22050)
	testing.expect_value(t, len(got), 6)
	for s, i in samples {testing.expect_value(t, got[i], s)}

	// 16 bit stereo: the first channel, scaled to 8 bits
	d := make([]u8, 44 + 8, context.temp_allocator)
	copy(d, file[:44])
	d[22] = 2 // channels
	d[34] = 16 // bits
	d[40] = 8 // data size
	d[44], d[45] = 0x00, 0x40 // +16384 -> 192
	d[48], d[49] = 0x00, 0xC0 // -16384 -> 64
	got2, _, ok2 := wav_decode(d)
	defer delete(got2)
	testing.expect(t, ok2)
	testing.expect_value(t, len(got2), 2)
	testing.expect_value(t, got2[0], 192)
	testing.expect_value(t, got2[1], 64)

	_, _, bad := wav_decode([]u8{1, 2, 3})
	testing.expect(t, !bad)
}

@(test)
tape_save_writes_fsk_wav :: proc(t: ^testing.T) {
	path := join2(DISK_DIR, "rom_tape_a.wav")
	defer os.remove(path)
	m := boot_machine(t)
	if m == nil {return}
	defer test_machine_free(m)
	tape_record_to(m, path)
	if !run_ram_program(t, m, TAPE_PROGRAM_SAVE, timed = true) {return}
	testing.expect_value(t, mem_read8(m, 0x0A00), 0)
	data, err := os.read_entire_file(path, context.allocator)
	if err != nil {
		testing.expect(t, false, "no WAV file was written")
		return
	}
	defer delete(data)
	samples, rate, ok := wav_decode(data)
	defer delete(samples)
	testing.expect(t, ok)
	testing.expect_value(t, rate, 44100)
	// measure the cycles: rising crossings of the middle
	ones, zeros, other := 0, 0, 0
	last := -1
	prev_high := false
	for s, i in samples {
		high := s >= 128
		if high && !prev_high {
			if last >= 0 {
				p := i - last
				switch {
				case p >= 33 && p <= 42: ones += 1
				case p >= 15 && p <= 24: zeros += 1
				case: other += 1
				}
			}
			last = i
		}
		prev_high = high
	}
	testing.expect(t, ones > 1000 && zeros > 1000, "both tones are present")
	testing.expect(t, other < 10, "every cycle is a clean 1200 or 2400 Hz one")
}

// A tape made by the ROM's own tape_save, as a file for the tests that read it.
make_tape :: proc(t: ^testing.T, path: string) -> bool {
	m := boot_machine(t)
	if m == nil {return false}
	defer test_machine_free(m)
	tape_record_to(m, path)
	return run_ram_program(t, m, TAPE_PROGRAM_SAVE, timed = true)
}

@(test)
tape_save_then_load_roundtrip :: proc(t: ^testing.T) {
	path := join2(DISK_DIR, "rom_tape_b.wav")
	defer os.remove(path)
	if !make_tape(t, path) {return}

	m := boot_machine(t)
	if m == nil {return}
	defer test_machine_free(m)
	testing.expect(t, tape_play(m, path))
	ok := run_ram_program(t, m, `
	org $0600
	ldx #$0800		; clear the destination
clr	clr ,x+
	cmpx #$0A00
	bne clr
	ldx #name
	ldy #0
	jsr $8030		; tape_load
	bcc loaded
	sta $0A00
	bra halt
loaded	clr $0A00
halt	bra halt
name	fcb "TESTFILE"
`, timed = true)
	if !ok {return}
	testing.expect_value(t, mem_read8(m, 0x0A00), 0)
	for i in 0 ..< 300 {
		want := u8(i * 7 + 3)
		if mem_read8(m, u16(0x0800 + i)) != want {
			testing.expectf(t, false, "byte %d is $%02X, want $%02X", i, mem_read8(m, u16(0x0800 + i)), want)
			break
		}
	}
	testing.expect_value(t, mem_read8(m, 0x0800 + 300), 0) // nothing beyond the file
	// the header was left behind
	testing.expect_value(t, mem_read8(m, TAPEHDR_ADDR + 0), 'T')
	testing.expect_value(t, mem_read8(m, TAPEHDR_ADDR + 8), 'M')
	testing.expect_value(t, int(mem_read8(m, TAPEHDR_ADDR + 11)) << 8 | int(mem_read8(m, TAPEHDR_ADDR + 12)), 300)
	testing.expect_value(t, int(mem_read8(m, TAPEHDR_ADDR + 13)) << 8 | int(mem_read8(m, TAPEHDR_ADDR + 14)), 0x0810)
	testing.expect(t, !m.cass_motor, "the motor is off again")
}

TAPEHDR_ADDR :: 0x0130

@(test)
tape_load_override_address_and_errors :: proc(t: ^testing.T) {
	path := join2(DISK_DIR, "rom_tape_c.wav")
	defer os.remove(path)
	if !make_tape(t, path) {return}

	// load at another address, any name
	m := boot_machine(t)
	if m == nil {return}
	defer test_machine_free(m)
	testing.expect(t, tape_play(m, path))
	ok := run_ram_program(t, m, `
	org $0600
	ldx #name
	ldy #$1000
	jsr $8030
	bcc loaded
	sta $0A00
	bra halt
loaded	clr $0A00
halt	bra halt
name	fcb 0,0,0,0,0,0,0,0
`, timed = true)
	if !ok {return}
	testing.expect_value(t, mem_read8(m, 0x0A00), 0)
	testing.expect_value(t, mem_read8(m, 0x1000), 3)
	testing.expect_value(t, mem_read8(m, 0x1000 + 299), u8((299 * 7 + 3) & 255))

	// a name that is not on the tape: the file is skipped, then the tape runs out
	testing.expect(t, tape_play(m, path))
	ok = run_ram_program(t, m, `
	org $0600
	ldx #name
	ldy #0
	jsr $8030
	bcc found
	sta $0A00
	bra halt
found	lda #$EE
	sta $0A00
halt	bra halt
name	fcb "NOSUCH  "
`, timed = true, max_frames = 1500)
	if !ok {return}
	testing.expect_value(t, mem_read8(m, 0x0A00), 1) // TE_NOSIGNAL

	// no tape at all and BREAK held: the wait is abandoned
	tape_eject(m)
	machine_key_event(m, .ESCAPE, true)
	for _ in 0 ..< 5 {machine_run_frame(m)}
	ok = run_ram_program(t, m, `
	org $0600
	ldx #name
	ldy #0
	jsr $8030
	sta $0A00
halt	bra halt
name	fcb 0,0,0,0,0,0,0,0
`, timed = true)
	machine_key_event(m, .ESCAPE, false)
	if !ok {return}
	testing.expect_value(t, mem_read8(m, 0x0A00), 4) // TE_BREAK
}

@(test)
monitor_tape_commands :: proc(t: ^testing.T) {
	path := join2(DISK_DIR, "rom_tape_d.wav")
	defer os.remove(path)
	m := boot_machine(t)
	if m == nil {return}
	defer test_machine_free(m)
	tape_record_to(m, path)
	type_text(m, "F 0800 08FF 5A\nO HELLO 0800 100 0840\n")
	settle(m, 400)
	expect_row(t, m, "SAVED")
	// rewind (play what was recorded) and read it back to another place
	testing.expect(t, tape_play(m, path))
	type_text(m, "I HELLO 1000\n")
	settle(m, 400)
	expect_row(t, m, "FOUND HELLO")
	expect_row(t, m, "LOAD 1000 LEN 0100 ENTRY 0840")
	testing.expect_value(t, mem_read8(m, 0x1000), 0x5A)
	testing.expect_value(t, mem_read8(m, 0x10FF), 0x5A)
	testing.expect(t, mem_read8(m, 0x1100) != 0x5A, "nothing beyond the file")
	// the monitor takes commands again
	type_text(m, "T\n")
	expect_screen_contains(t, m, "TICKS")
}

// The real Color BASIC as a foreign tape writer and reader (skipped without coco3.rom):
// proves the emulated cassette timing is right, independently of the ROM in rom/.
@(test)
real_basic_csave_then_cload :: proc(t: ^testing.T) {
	path := join2(DISK_DIR, "real_tape.wav")
	defer os.remove(path)
	{
		m := real_rom_machine()
		if m == nil {return}
		defer test_machine_free(m)
		for _ in 0 ..< 200 {machine_run_frame(m)}
		tape_record_to(m, path)
		type_basic(m, "10 PRINT \"FROM TAPE\"\nCSAVE \"T\"\n", 900)
		for _ in 0 ..< 900 {machine_run_frame(m)}
		testing.expect(t, !m.cass_motor, "CSAVE finished")
		expect_screen_contains(t, m, "OK")
	}
	if _, err := os.stat(path, context.temp_allocator); err != nil {
		testing.expect(t, false, "CSAVE wrote no tape")
		return
	}
	m := real_rom_machine()
	if m == nil {return}
	defer test_machine_free(m)
	for _ in 0 ..< 200 {machine_run_frame(m)}
	testing.expect(t, tape_play(m, path))
	type_basic(m, "CLOAD \"T\"\n", 900)
	for _ in 0 ..< 600 {machine_run_frame(m)}
	type_basic(m, "LIST\n", 100)
	expect_screen_contains(t, m, "10 PRINT \"FROM TAPE\"")
}
