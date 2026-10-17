package vcc

import "core:math"
import "core:testing"

poke :: proc(m: ^Machine, addr: u16, bytes: []u8) {
	for b, i in bytes {mem_write8(m, addr + u16(i), b)}
}

// Machine whose IRQ vector points to $0500.
irq_machine :: proc() -> ^Machine {
	m := test_machine()
	m.rom[0x7FF8] = 0x05
	m.rom[0x7FF9] = 0x00
	m.cpu.s = 0x7F00 // stack in RAM
	mem_write8(m, 0x0300, 0) // counter (RAM powers up as FF 00 FF 00)
	return m
}

@(test)
frame_geometry_adds_up :: proc(t: ^testing.T) {
	m := test_machine()
	defer test_machine_free(m)
	for vres in 0 ..< 4 {
		mem_write8(m, 0xFF99, u8(vres << 5))
		mem_write8(m, 0xFF90, 0) // GIME mode, not CoCo 2 compat
		g := video_geometry(m)
		total := 7 + g.top_offscreen + g.top_border + g.active_lines + g.bottom_border + g.bottom_offscreen
		// VCC's 199 line mode (vres index 1) makes a 261 line frame; the rest are 262.
		testing.expect_value(t, total, 261 if vres == 1 else 262)
	}
}

@(test)
frame_runs_expected_cycles :: proc(t: ^testing.T) {
	m := test_machine()
	defer test_machine_free(m)
	// loop: LEAX 1,X (5 cycles) ; BRA loop (3 cycles)
	poke(m, 0x0400, {0x30, 0x01, 0x20, 0xFC})
	m.cpu.pc = 0x0400
	machine_run_frame(m)
	cycles := f64(m.cpu.x) * 8
	expected := LINES_PER_SCREEN * CYCLES_PER_LINE
	testing.expect(t, math.abs(cycles - expected) < 24, "frame cycles out of range")
	log_expect := expected // ~14934 cycles at 0.895 MHz
	testing.expect(t, log_expect > 14900 && log_expect < 14970)
}

@(test)
high_speed_poke_doubles_cycles :: proc(t: ^testing.T) {
	m := test_machine()
	defer test_machine_free(m)
	poke(m, 0x0400, {0x30, 0x01, 0x20, 0xFC})
	mem_write8(m, 0xFFD9, 0) // SAM R1: high speed
	m.cpu.pc = 0x0400
	machine_run_frame(m)
	ratio := f64(m.cpu.x) * 8 / (LINES_PER_SCREEN * CYCLES_PER_LINE)
	testing.expect(t, math.abs(ratio - 2) < 0.01)
	mem_write8(m, 0xFF96, 1) // turbo on top: 4x
	m.cpu.x = 0
	machine_run_frame(m)
	ratio = f64(m.cpu.x) * 8 / (LINES_PER_SCREEN * CYCLES_PER_LINE)
	testing.expect(t, math.abs(ratio - 4) < 0.01)
}

@(test)
hsync_interrupt_once_per_line :: proc(t: ^testing.T) {
	m := irq_machine()
	defer test_machine_free(m)
	// main: ANDCC #$EF ; BRA *     handler: INC $0300 ; LDA $FF00 ; RTI
	poke(m, 0x0400, {0x1C, 0xEF, 0x20, 0xFE})
	poke(m, 0x0500, {0x7C, 0x03, 0x00, 0xB6, 0xFF, 0x00, 0x3B})
	mem_write8(m, 0xFF01, 0x05) // HSYNC IRQ enabled, falling edge, data register
	m.cpu.pc = 0x0400
	for _ in 0 ..< 100 {hline(m)}
	count := int(mem_read8(m, 0x0300))
	testing.expect(t, count >= 99 && count <= 101, "hsync IRQ count")
}

@(test)
vsync_interrupt_once_per_frame :: proc(t: ^testing.T) {
	m := irq_machine()
	defer test_machine_free(m)
	poke(m, 0x0400, {0x1C, 0xEF, 0x20, 0xFE})
	poke(m, 0x0500, {0x7C, 0x03, 0x00, 0xB6, 0xFF, 0x02, 0x3B}) // INC ; LDA $FF02 ; RTI
	mem_write8(m, 0xFF03, 0x35) // VSYNC IRQ enabled, falling edge
	m.cpu.pc = 0x0400
	for _ in 0 ..< 3 {machine_run_frame(m)}
	testing.expect_value(t, mem_read8(m, 0x0300), 3)
}

@(test)
gime_timer_period_in_scanlines :: proc(t: ^testing.T) {
	m := irq_machine()
	defer test_machine_free(m)
	poke(m, 0x0400, {0x1C, 0xEF, 0x20, 0xFE})
	poke(m, 0x0500, {0x7C, 0x03, 0x00, 0xB6, 0xFF, 0x92, 0x3B}) // INC ; LDA $FF92 ; RTI
	mem_write8(m, 0xFF90, 0x20) // IRQ to CPU
	mem_write8(m, 0xFF92, u8(GIME_INTR_TIMER))
	mem_write8(m, 0xFF94, 0)
	mem_write8(m, 0xFF95, 10) // 10+1 scanlines
	m.cpu.pc = 0x0400
	machine_run_frame(m)
	count := int(mem_read8(m, 0x0300))
	testing.expect(t, count >= 22 && count <= 25, "timer interrupts per frame")
}

@(test)
timer_zero_disables :: proc(t: ^testing.T) {
	// A zero counter stops the periodic timer. Enabling the source while it is
	// zero fires one interrupt right away (as VCC's GimeWrite does), then nothing.
	m := irq_machine()
	defer test_machine_free(m)
	poke(m, 0x0400, {0x1C, 0xEF, 0x20, 0xFE})
	poke(m, 0x0500, {0x7C, 0x03, 0x00, 0xB6, 0xFF, 0x92, 0x3B})
	mem_write8(m, 0xFF90, 0x20)
	mem_write8(m, 0xFF92, u8(GIME_INTR_TIMER))
	mem_write8(m, 0xFF94, 0)
	mem_write8(m, 0xFF95, 0)
	m.cpu.pc = 0x0400
	machine_run_frame(m)
	testing.expect_value(t, mem_read8(m, 0x0300), 1)
}

@(test)
timer_clock_rate_and_period :: proc(t: ^testing.T) {
	m := test_machine()
	defer test_machine_free(m)
	mem_write8(m, 0xFF94, 0)
	mem_write8(m, 0xFF95, 99)
	testing.expect(t, math.abs(m.timing.master_tick_counter - NANOS_PER_LINE * 100) < 1)
	mem_write8(m, 0xFF91, 0x20) // TINS: colorburst clock (279ns)
	expected := NANOSECOND / COLORBURST * 100
	testing.expect(t, math.abs(m.timing.master_tick_counter - expected) < 1)
}

@(test)
sync_wakes_on_interrupt_in_frame :: proc(t: ^testing.T) {
	m := irq_machine()
	defer test_machine_free(m)
	// ANDCC #$EF ; SYNC ; handler ... counts vsyncs while the CPU idles in SYNC
	poke(m, 0x0400, {0x1C, 0xEF, 0x13, 0x20, 0xFC}) // loop: SYNC ; BRA loop
	poke(m, 0x0500, {0x7C, 0x03, 0x00, 0xB6, 0xFF, 0x02, 0x3B})
	mem_write8(m, 0xFF03, 0x35)
	m.cpu.pc = 0x0400
	for _ in 0 ..< 2 {machine_run_frame(m)}
	testing.expect_value(t, mem_read8(m, 0x0300), 2)
}
