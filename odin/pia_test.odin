package vcc

import "core:testing"
import SDL "vendor:sdl2"

// Configure PIA0 like the ROM: B = outputs (column strobes), A = inputs.
pia0_setup_keyboard :: proc(m: ^Machine) {
	mem_write8(m, 0xFF01, 0) // select DDR
	mem_write8(m, 0xFF00, 0) // A all inputs
	mem_write8(m, 0xFF03, 0)
	mem_write8(m, 0xFF02, 0xFF) // B all outputs
	mem_write8(m, 0xFF01, 0x04) // select data registers
	mem_write8(m, 0xFF03, 0x04)
}

scan_col :: proc(m: ^Machine, col: u8) -> u8 {
	mem_write8(m, 0xFF02, ~(u8(1) << col))
	return mem_read8(m, 0xFF00)
}

@(test)
no_key_reads_all_rows_high :: proc(t: ^testing.T) {
	m := test_machine()
	defer test_machine_free(m)
	pia0_setup_keyboard(m)
	testing.expect_value(t, scan_col(m, 1), 0x7F)
}

@(test)
key_a_appears_in_its_column :: proc(t: ^testing.T) {
	m := test_machine()
	defer test_machine_free(m)
	pia0_setup_keyboard(m)
	machine_key_event(m, .A, true) // row 1, column 1
	testing.expect_value(t, scan_col(m, 1), 0x7E) // row bit 0 pulled low
	testing.expect_value(t, scan_col(m, 0), 0x7F) // other columns unaffected
	testing.expect_value(t, scan_col(m, 2), 0x7F)
	machine_key_event(m, .A, false)
	testing.expect_value(t, scan_col(m, 1), 0x7F)
}

@(test)
all_columns_strobed_sees_any_key :: proc(t: ^testing.T) {
	m := test_machine()
	defer test_machine_free(m)
	pia0_setup_keyboard(m)
	machine_key_event(m, .RETURN, true) // row 64, col 0
	mem_write8(m, 0xFF02, 0) // strobe every column (what the ROM does to poll for any key)
	testing.expect_value(t, mem_read8(m, 0xFF00), 127 - 64)
}

@(test)
shift_and_key_combine :: proc(t: ^testing.T) {
	m := test_machine()
	defer test_machine_free(m)
	pia0_setup_keyboard(m)
	machine_key_event(m, .RSHIFT, true)
	machine_key_event(m, .NUM1, true)
	testing.expect_value(t, scan_col(m, 7), 127 - 64) // shift: row 64, col 7
	testing.expect_value(t, scan_col(m, 1), 127 - 16) // '1': row 16, col 1
}

@(test)
keypress_raises_gime_keyboard_interrupt :: proc(t: ^testing.T) {
	m := test_machine()
	defer test_machine_free(m)
	mem_write8(m, 0xFF90, 0x20)
	mem_write8(m, 0xFF92, u8(GIME_INTR_KEYB))
	machine_key_event(m, .Z, true)
	testing.expect(t, m.cpu.int_lines[.GIME] & int_bit(.IRQ) != 0)
}

@(test)
hsync_irq_flag_and_clear :: proc(t: ^testing.T) {
	m := test_machine()
	defer test_machine_free(m)
	mem_write8(m, 0xFF01, 0x05) // data regs, HSYNC IRQ enabled, falling edge
	irq_hs(m, .Rising) // wrong edge: ignored
	testing.expect_value(t, m.pia0.reg[1] & 0x80, 0)
	irq_hs(m, .Falling)
	testing.expect(t, m.pia0.reg[1] & 0x80 != 0)
	testing.expect(t, m.cpu.int_lines[.PIA0_HSYNC] & int_bit(.IRQ) != 0)
	testing.expect(t, mem_read8(m, 0xFF01) & 0x80 != 0) // flag visible in control reg
	mem_read8(m, 0xFF00) // reading port A clears flag and line
	testing.expect_value(t, m.pia0.reg[1] & 0x80, 0)
	testing.expect_value(t, m.cpu.int_lines[.PIA0_HSYNC], 0)
}

@(test)
hsync_not_enabled_sets_flag_only :: proc(t: ^testing.T) {
	m := test_machine()
	defer test_machine_free(m)
	mem_write8(m, 0xFF01, 0x04) // HSYNC IRQ disabled
	irq_hs(m, .Falling)
	testing.expect(t, m.pia0.reg[1] & 0x80 != 0)
	testing.expect_value(t, m.cpu.int_lines[.PIA0_HSYNC], 0)
}

@(test)
vsync_irq_via_pia0_b :: proc(t: ^testing.T) {
	m := test_machine()
	defer test_machine_free(m)
	mem_write8(m, 0xFF03, 0x37) // data regs, enabled, rising-edge flag
	irq_fs(m, .Falling) // ignored
	testing.expect_value(t, m.cpu.int_lines[.PIA0_VSYNC], 0)
	irq_fs(m, .Rising)
	testing.expect(t, m.cpu.int_lines[.PIA0_VSYNC] & int_bit(.IRQ) != 0)
	mem_read8(m, 0xFF02)
	testing.expect_value(t, m.cpu.int_lines[.PIA0_VSYNC], 0)
}

@(test)
dac_sample_from_pia1 :: proc(t: ^testing.T) {
	m := test_machine()
	defer test_machine_free(m)
	mem_write8(m, 0xFF21, 0) // DDR select
	mem_write8(m, 0xFF20, 0xFE) // bits 7-1 outputs
	mem_write8(m, 0xFF21, 0x04)
	mem_write8(m, 0xFF23, 0x08) // sound enable (select line B high), DDR select bit clear
	mem_write8(m, 0xFF23, 0x0C)
	mem_write8(m, 0xFF20, 0xFC) // 6-bit DAC full scale
	// mux state 0 requires FF01 bit3 = 0 and FF03 bit 3 = 0 on PIA0 (power-up state)
	testing.expect_value(t, m.asample, 0xFC >> 1)
	mem_write8(m, 0xFF20, 0x08)
	testing.expect_value(t, m.asample, 0x08 >> 1)
}

@(test)
single_bit_sound :: proc(t: ^testing.T) {
	m := test_machine()
	defer test_machine_free(m)
	mem_write8(m, 0xFF23, 0) // DDR select (ddb)
	mem_write8(m, 0xFF22, 0xFE) // direction: bit 1 out
	mem_write8(m, 0xFF23, 0x04)
	mem_write8(m, 0xFF22, 0x02)
	testing.expect_value(t, m.ssample, 0x80)
	mem_write8(m, 0xFF22, 0x00)
	testing.expect_value(t, m.ssample, 0)
}

@(test)
vdg_mode_from_pia1_b :: proc(t: ^testing.T) {
	m := test_machine()
	defer test_machine_free(m)
	mem_write8(m, 0xFF23, 0)
	mem_write8(m, 0xFF22, 0xF8) // top 5 bits output
	mem_write8(m, 0xFF23, 0x04)
	mem_write8(m, 0xFF22, 0xA8) // A/G=1, GM1=1, CSS=1
	testing.expect_value(t, pia_vdg_mode(m), 0xA8 >> 3)
}

@(test)
cart_line_sets_flag_at_reset_and_survives_pia_init :: proc(t: ^testing.T) {
	m := test_machine()
	defer test_machine_free(m)
	cart := [?]u8{0x44, 0x4B}
	machine_load_cart(m, cart[:])
	machine_reset(m)
	testing.expect(t, m.pia1.reg[3] & 0x80 != 0, "CART flag is set at power-up")
	// BASIC's PIA init writes the control registers: flag bits are read-only and must survive
	mem_write8(m, 0xFF23, 0x00)
	mem_write8(m, 0xFF23, 0x34)
	testing.expect(t, m.pia1.reg[3] & 0x80 != 0, "control register writes do not clear the flag")
	testing.expect_value(t, m.cpu.int_lines[.PIA1_CART], 0) // FIRQ not enabled yet
	mem_write8(m, 0xFF23, 0x35) // enabling the interrupt raises FIRQ because the flag is pending
	// (the flag is only reported; the line follows the enable on the next assert/clear)
	mem_read8(m, 0xFF22) // reading the data register clears the flag
	testing.expect_value(t, m.pia1.reg[3] & 0x80, 0)
	testing.expect_value(t, m.cpu.int_lines[.PIA1_CART], 0)
}

@(test)
cart_assert_raises_firq_when_enabled :: proc(t: ^testing.T) {
	m := test_machine()
	defer test_machine_free(m)
	mem_write8(m, 0xFF23, 0x05) // FIRQ enabled, data register selected
	pia_assert_cart(m)
	testing.expect(t, m.cpu.int_lines[.PIA1_CART] & int_bit(.FIRQ) != 0)
	mem_read8(m, 0xFF22)
	testing.expect_value(t, m.cpu.int_lines[.PIA1_CART], 0)
}

@(test)
control_writes_keep_interrupt_flags :: proc(t: ^testing.T) {
	m := test_machine()
	defer test_machine_free(m)
	mem_write8(m, 0xFF01, 0x05)
	irq_hs(m, .Falling)
	testing.expect(t, m.pia0.reg[1] & 0x80 != 0)
	mem_write8(m, 0xFF01, 0x04) // rewriting the control register leaves the pending flag alone
	testing.expect(t, m.pia0.reg[1] & 0x80 != 0)
	mem_read8(m, 0xFF00)
	testing.expect_value(t, m.pia0.reg[1] & 0x80, 0)
}

@(test)
mux_state_from_control_bits :: proc(t: ^testing.T) {
	m := test_machine()
	defer test_machine_free(m)
	mem_write8(m, 0xFF01, 0x0C)
	mem_write8(m, 0xFF03, 0x00)
	testing.expect_value(t, get_mux_state(m), 1)
	mem_write8(m, 0xFF03, 0x08)
	testing.expect_value(t, get_mux_state(m), 3)
}

@(test)
rom_keyboard_poll_idle_smoke :: proc(t: ^testing.T) {
	// The CPU can read the matrix through the bus: LDA $FF00 after strobing.
	m := test_machine()
	defer test_machine_free(m)
	pia0_setup_keyboard(m)
	machine_key_event(m, .SPACE, true) // row 8, col 7
	mem_write8(m, 0xFF02, 0x7F) // strobe column 7 only
	prog := [?]u8{0xB6, 0xFF, 0x00} // LDA $FF00
	for b, i in prog {mem_write8(m, 0x0400 + u16(i), b)}
	m.cpu.pc = 0x0400
	cpu_exec(&m.cpu, 1)
	testing.expect_value(t, m.cpu.a, 127 - 8)
}

_ :: SDL.Scancode
