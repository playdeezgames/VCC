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
	k, ok := char_to_key('A')
	testing.expect(t, ok && k.sc == .A && !k.shift)
	k, ok = char_to_key('a')
	testing.expect(t, ok && k.sc == .A && k.shift)
	k, ok = char_to_key('"')
	testing.expect(t, ok && k.sc == .NUM2 && k.shift) // CoCo: shift+2
	k, ok = char_to_key(':')
	testing.expect(t, ok && k.sc == .MINUS && !k.shift)
	k, ok = char_to_key('+')
	testing.expect(t, ok && k.sc == .SEMICOLON && k.shift)
	k, ok = char_to_key('\n')
	testing.expect(t, ok && k.sc == .RETURN)
	_, ok = char_to_key('~')
	testing.expect(t, !ok)
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
	testing.expect(t, contains(text, "DISK EXTENDED COLOR BASIC 1.1"), "disk banner")
	testing.expect(t, contains(text, "\nOK"), "prompt")
}

contains :: proc(s, sub: string) -> bool {return strings.contains(s, sub)}
