package vcc

import "core:os"
import "core:strings"
import "core:testing"
import SDL "vendor:sdl2"

// Select an analog axis by setting the mux bits (PIA0 FF01 bit 3 = LSB, FF03 bit 3 = MSB)
select_axis :: proc(m: ^Machine, axis: Axis) {
	n := u8(axis)
	mem_write8(m, 0xFF01, 0x04 | (n & 1) << 3)
	mem_write8(m, 0xFF03, 0x04 | (n >> 1) << 3)
}

// Output a DAC level (6 bit value) the way BASIC's JOYSTK routine does.
set_dac :: proc(m: ^Machine, level6: u8) {
	mem_write8(m, 0xFF21, 0)
	mem_write8(m, 0xFF20, 0xFE)
	mem_write8(m, 0xFF21, 0x04)
	mem_write8(m, 0xFF20, level6 << 2)
}

@(test)
no_stick_comparator_low :: proc(t: ^testing.T) {
	m := test_machine()
	defer test_machine_free(m)
	pia0_setup_keyboard(m)
	select_axis(m, .Right_X)
	set_dac(m, 0)
	testing.expect_value(t, mem_read8(m, 0xFF00) & 0x80, 0)
}

@(test)
stick_comparator_follows_dac :: proc(t: ^testing.T) {
	m := test_machine()
	defer test_machine_free(m)
	pia0_setup_keyboard(m)
	machine_set_axis(m, .Right_X, 0x2000) // half deflection ~ 32 of 63
	select_axis(m, .Right_X)
	set_dac(m, 10)
	testing.expect(t, mem_read8(m, 0xFF00) & 0x80 != 0, "stick above DAC level")
	set_dac(m, 50)
	testing.expect_value(t, mem_read8(m, 0xFF00) & 0x80, 0)
}

@(test)
axis_select_uses_mux :: proc(t: ^testing.T) {
	m := test_machine()
	defer test_machine_free(m)
	pia0_setup_keyboard(m)
	machine_set_axis(m, .Left_Y, STICK_MAX)
	select_axis(m, .Right_X)
	set_dac(m, 30)
	testing.expect_value(t, mem_read8(m, 0xFF00) & 0x80, 0) // right X not connected
	select_axis(m, .Left_Y)
	testing.expect(t, mem_read8(m, 0xFF00) & 0x80 != 0)
}

@(test)
buttons_pull_row_bits_low :: proc(t: ^testing.T) {
	m := test_machine()
	defer test_machine_free(m)
	pia0_setup_keyboard(m)
	mem_write8(m, 0xFF02, 0xFF) // no column strobed
	testing.expect_value(t, mem_read8(m, 0xFF00) & 0x0F, 0x0F)
	machine_set_button(m, BUTTON_RIGHT_1, true)
	testing.expect_value(t, mem_read8(m, 0xFF00) & 0x0F, 0x0E)
	machine_set_button(m, BUTTON_LEFT_1, true)
	testing.expect_value(t, mem_read8(m, 0xFF00) & 0x0F, 0x0C)
	machine_set_button(m, BUTTON_RIGHT_2 | BUTTON_LEFT_2, true)
	testing.expect_value(t, mem_read8(m, 0xFF00) & 0x0F, 0x00)
	machine_set_button(m, BUTTON_RIGHT_1 | BUTTON_LEFT_1 | BUTTON_RIGHT_2 | BUTTON_LEFT_2, false)
	testing.expect_value(t, mem_read8(m, 0xFF00) & 0x0F, 0x0F)
}

@(test)
char_mapping :: proc(t: ^testing.T) {
	check :: proc(t: ^testing.T, c: u8, sc: SDL.Scancode, shift: bool, loc := #caller_location) {
		k, ok := char_to_key(c)
		testing.expectf(t, ok && k.sc == sc && k.shift == shift, "char_to_key(%c)", c, loc = loc)
	}
	check(t, 'A', .A, false)
	check(t, 'a', .A, true)
	check(t, '"', .APOSTROPHE, true)
	check(t, ':', .SEMICOLON, true)
	check(t, '+', .EQUALS, true)
	check(t, '=', .EQUALS, false)
	check(t, '-', .MINUS, false)
	check(t, '*', .NUM8, true)
	check(t, '@', .NUM2, true)
	check(t, '\n', .RETURN, false)
	_, ok := char_to_key(0x7F)
	testing.expect(t, !ok)
}

// Which matrix keys does a set of held PC keys produce? Returns a bitmap
// indexed [col] of row masks.
matrix_for :: proc(keys: ..SDL.Scancode) -> [8]u8 {
	kb: Keyboard
	for k in keys {kb.down[int(k)] = true}
	keyboard_update_rollover(&kb)
	return kb.rollover
}

has :: proc(r: [8]u8, row: u8, col: int) -> bool {return r[col] & row != 0}
only :: proc(r: [8]u8, row: u8, col: int) -> bool {
	for c in 0 ..< 8 {
		want := row if c == col else 0
		if r[c] != want {return false}
	}
	return true
}

@(test)
natural_layout_symbols :: proc(t: ^testing.T) {
	// '-' is -, '=' is =: CoCo "-" key alone, CoCo shift + "-" key
	testing.expect(t, only(matrix_for(.MINUS), 32, 5), "- types -")
	r := matrix_for(.EQUALS)
	testing.expect(t, has(r, 32, 5) && has(r, 64, 7), "= types = (shift-minus)")
	// '*' is shift+8, '+' is shift+=
	r = matrix_for(.LSHIFT, .NUM8)
	testing.expect(t, has(r, 32, 2) && has(r, 64, 7), "*")
	r = matrix_for(.RSHIFT, .EQUALS)
	testing.expect(t, has(r, 32, 3) && has(r, 64, 7), "+")
	// '@' is shift+2 and needs no CoCo shift
	testing.expect(t, only(matrix_for(.LSHIFT, .NUM2), 1, 0), "@")
	// ':' is shift+; and needs no CoCo shift
	testing.expect(t, only(matrix_for(.LSHIFT, .SEMICOLON), 32, 2), ":")
	// '"' is shift+'
	r = matrix_for(.LSHIFT, .APOSTROPHE)
	testing.expect(t, has(r, 16, 2) && has(r, 64, 7), "\"")
	// digits keep their meaning, shift+1 is !
	testing.expect(t, only(matrix_for(.NUM5), 16, 5))
	r = matrix_for(.LSHIFT, .NUM1)
	testing.expect(t, has(r, 16, 1) && has(r, 64, 7), "!")
	// letters: plain = CoCo letter, shifted adds CoCo shift
	testing.expect(t, only(matrix_for(.Q), 4, 1))
	r = matrix_for(.LSHIFT, .Q)
	testing.expect(t, has(r, 4, 1) && has(r, 64, 7))
	// a lone shift is the CoCo shift key
	testing.expect(t, only(matrix_for(.LSHIFT), 64, 7))
	testing.expect(t, only(matrix_for(.RSHIFT), 64, 7))
}

@(test)
natural_layout_arrows_and_specials :: proc(t: ^testing.T) {
	testing.expect(t, only(matrix_for(.UP), 8, 3), "up")
	testing.expect(t, only(matrix_for(.DOWN), 8, 4), "down")
	testing.expect(t, only(matrix_for(.LEFT), 8, 5), "left")
	testing.expect(t, only(matrix_for(.RIGHT), 8, 6), "right")
	testing.expect(t, only(matrix_for(.KP_8), 8, 3), "numpad up")
	testing.expect(t, only(matrix_for(.KP_2), 8, 4), "numpad down")
	testing.expect(t, only(matrix_for(.KP_4), 8, 5), "numpad left")
	testing.expect(t, only(matrix_for(.KP_6), 8, 6), "numpad right")
	testing.expect(t, only(matrix_for(.BACKSPACE), 8, 5), "backspace = left arrow")
	testing.expect(t, only(matrix_for(.ESCAPE), 64, 2), "esc = break")
	testing.expect(t, only(matrix_for(.HOME), 64, 1), "home = clear")
	testing.expect(t, only(matrix_for(.RETURN), 64, 0), "enter")
	// shift + arrow = CoCo shift + arrow
	r := matrix_for(.LSHIFT, .UP)
	testing.expect(t, has(r, 8, 3) && has(r, 64, 7))
	// all four at once
	r = matrix_for(.UP, .DOWN, .LEFT, .RIGHT)
	testing.expect(t, has(r, 8, 3) && has(r, 8, 4) && has(r, 8, 5) && has(r, 8, 6))
}

@(test)
paste_presses_keys_in_order :: proc(t: ^testing.T) {
	m := test_machine()
	defer test_machine_free(m)
	park_cpu(m)
	pia0_setup_keyboard(m)
	paste_text(m, "AB")
	testing.expect(t, paste_active(m))
	seen_a, seen_b := false, false
	for _ in 0 ..< 40 {
		paste_step(m)
		if m.kb.down[int(SDL.Scancode.A)] {seen_a = true}
		if m.kb.down[int(SDL.Scancode.B)] {seen_b = true; testing.expect(t, seen_a, "A before B")}
	}
	testing.expect(t, seen_a && seen_b)
	testing.expect(t, !paste_active(m))
	testing.expect(t, !m.kb.down[int(SDL.Scancode.A)] && !m.kb.down[int(SDL.Scancode.B)], "released")
}

@(test)
paste_cancel_releases_keys :: proc(t: ^testing.T) {
	m := test_machine()
	defer test_machine_free(m)
	paste_text(m, "aXYZ")
	paste_step(m) // presses shift + A
	testing.expect(t, m.kb.down[int(SDL.Scancode.A)] && m.kb.down[int(SDL.Scancode.LSHIFT)])
	paste_cancel(m)
	testing.expect(t, !m.kb.down[int(SDL.Scancode.A)] && !m.kb.down[int(SDL.Scancode.LSHIFT)])
	testing.expect(t, !paste_active(m))
}

@(test)
paste_crlf_is_one_enter :: proc(t: ^testing.T) {
	m := test_machine()
	defer test_machine_free(m)
	paste_text(m, "1\r\n2\n")
	testing.expect_value(t, len(m.paste.queue), 4) // 1 ENTER 2 ENTER
}

@(test)
real_rom_paste_runs_program :: proc(t: ^testing.T) {
	m := real_rom_machine()
	if m == nil {return}
	defer test_machine_free(m)
	for _ in 0 ..< 200 {machine_run_frame(m)}
	paste_text(m, "10 FOR I=1 TO 3:PRINT I*11;:NEXT\nRUN\n")
	for _ in 0 ..< 600 {
		paste_step(m)
		machine_run_frame(m)
	}
	text := screen_text(m)
	testing.expect(t, contains(text, " 11  22  33"), "program output")
}

@(test)
disk_basic_boots_with_disk_rom :: proc(t: ^testing.T) {
	m := real_rom_machine()
	if m == nil {return}
	defer test_machine_free(m)
	cart, err := os.read_entire_file("disk11.rom", context.allocator)
	if err != nil {return}
	defer delete(cart)
	machine_load_cart(m, cart)
	machine_reset(m)
	for _ in 0 ..< 400 {machine_run_frame(m)}
	text := screen_text(m)
	testing.expect(t, contains(text, "DISK EXTENDED COLOR BASIC 2.1"), "disk banner")
	testing.expect(t, contains(text, "\nOK"), "prompt")
}

contains :: proc(s, sub: string) -> bool {return strings.contains(s, sub)}

@(test)
real_rom_natural_symbols :: proc(t: ^testing.T) {
	m := real_rom_machine()
	if m == nil {return}
	defer test_machine_free(m)
	for _ in 0 ..< 200 {machine_run_frame(m)}
	// Exercises - = * + : " @ through the paste -> PC key -> CoCo matrix path.
	paste_text(m, "PRINT 2+3*4-1\nPRINT 5=5\nPRINT \"@:\"\n")
	for _ in 0 ..< 700 {
		paste_step(m)
		machine_run_frame(m)
	}
	text := screen_text(m)
	testing.expect(t, contains(text, " 13"), "2+3*4-1")
	testing.expect(t, contains(text, "-1"), "5=5 is true")
	testing.expect(t, contains(text, "@:"), "string with @ and :")
}

@(test)
real_rom_text_fed_through_polcat_hook :: proc(t: ^testing.T) {
	m := real_rom_machine()
	if m == nil {return}
	defer test_machine_free(m)
	for _ in 0 ..< 200 {machine_run_frame(m)}
	// a line longer than the 32 column screen, typed without a single dropped character
	long := "A$=\"0123456789012345678901234567890123456789012345678901234567890123456789\":PRINT LEN(A$)\n"
	rom_paste_text(m, long)
	for rom_paste_active(m) {machine_run_frame(m)}
	for _ in 0 ..< 60 {machine_run_frame(m)}
	testing.expect(t, contains(screen_text(m), "70"), "LEN(A$) = 70")
	testing.expect(t, !rom_paste_active(m))
	// a hook-less machine is unaffected
	m2 := test_machine()
	defer test_machine_free(m2)
	testing.expect(t, m2.cpu.hook == nil)
}
