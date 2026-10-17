package vcc

import "core:log"
import "core:os"
import "core:testing"

// Machine with a recognisable ROM: rom[i] = i & 0xFF, except the reset vector.
test_machine :: proc(ram_config := 1) -> ^Machine {
	m := new(Machine)
	machine_init(m, ram_config)
	rom: [0x8000]u8
	for i in 0 ..< len(rom) {rom[i] = u8(i)}
	rom[0x7FFE] = 0x80 // reset vector -> $8000
	rom[0x7FFF] = 0x00
	machine_load_rom(m, rom[:])
	machine_reset(m)
	return m
}

test_machine_free :: proc(m: ^Machine) {
	machine_destroy(m)
	free(m)
}

@(test)
reset_vector_from_rom :: proc(t: ^testing.T) {
	m := test_machine()
	defer test_machine_free(m)
	testing.expect_value(t, m.cpu.pc, 0x8000)
}

@(test)
default_map_rom_and_cart :: proc(t: ^testing.T) {
	m := test_machine()
	defer test_machine_free(m)
	cart := [?]u8{0xC0, 0xC1}
	m.cart = cart[:]
	testing.expect_value(t, mem_read8(m, 0x8005), 0x05) // internal ROM
	testing.expect_value(t, mem_read8(m, 0xA010), 0x10) // second 8K of ROM: rom[0x2010] = $10
	testing.expect_value(t, mem_read8(m, 0xC000), 0xC0) // cartridge
	testing.expect_value(t, mem_read8(m, 0xC001), 0xC1)
	testing.expect_value(t, mem_read8(m, 0xC002), 0) // past end of cart
}

@(test)
ram_rw_and_rom_write_protect :: proc(t: ^testing.T) {
	m := test_machine()
	defer test_machine_free(m)
	mem_write8(m, 0x1234, 0x99)
	testing.expect_value(t, mem_read8(m, 0x1234), 0x99)
	mem_write8(m, 0x8005, 0x77) // ROM: ignored
	testing.expect_value(t, mem_read8(m, 0x8005), 0x05)
}

@(test)
all_ram_mode_via_sam :: proc(t: ^testing.T) {
	m := test_machine()
	defer test_machine_free(m)
	mem_write8(m, 0xFFDF, 0) // SAM: map type 1 = all RAM
	mem_write8(m, 0x8005, 0x77)
	testing.expect_value(t, mem_read8(m, 0x8005), 0x77)
	// the physical page is the top of 512K: $78000 + 5
	testing.expect_value(t, m.ram[0x78005], 0x77)
	mem_write8(m, 0xFFDE, 0) // back to ROM
	testing.expect_value(t, mem_read8(m, 0x8005), 0x05)
}

@(test)
rom_map_32k_internal :: proc(t: ^testing.T) {
	m := test_machine()
	defer test_machine_free(m)
	mem_write8(m, 0xFF90, 2) // MC1:MC0 = 10 -> 32K internal
	testing.expect_value(t, mem_read8(m, 0xC010), 0x10) // rom[0x4010]
	testing.expect_value(t, mem_read8(m, 0xE005), 0x05) // rom[0x6005]
}

@(test)
vectors_come_from_rom :: proc(t: ^testing.T) {
	m := test_machine()
	defer test_machine_free(m)
	testing.expect_value(t, mem_read8(m, 0xFFF2), 0xF2) // rom[0x7FF2]
}

@(test)
mmu_task_mapping :: proc(t: ^testing.T) {
	m := test_machine()
	defer test_machine_free(m)
	// Task 0: bank 0 ($0000) -> physical page 5; task 1: bank 0 -> page 9
	mem_write8(m, 0xFFA0, 5)
	mem_write8(m, 0xFFA8, 9)
	mem_write8(m, 0xFF90, 0x40) // MMU enable
	mem_write8(m, 0x0010, 0xAA)
	testing.expect_value(t, m.ram[5 * 0x2000 + 0x10], 0xAA)
	mem_write8(m, 0xFF91, 1) // task 1
	mem_write8(m, 0x0010, 0xBB)
	testing.expect_value(t, m.ram[9 * 0x2000 + 0x10], 0xBB)
	testing.expect_value(t, mem_read8(m, 0x0010), 0xBB)
	mem_write8(m, 0xFF91, 0)
	testing.expect_value(t, mem_read8(m, 0x0010), 0xAA)
}

@(test)
mmu_disabled_uses_top_64k :: proc(t: ^testing.T) {
	m := test_machine()
	defer test_machine_free(m)
	mem_write8(m, 0x0000, 0x42)
	testing.expect_value(t, m.ram[56 * 0x2000], 0x42) // pages 56-63 of 512K
	// MMU register writes do not matter while disabled
	mem_write8(m, 0xFFA0, 1)
	testing.expect_value(t, mem_read8(m, 0x0000), 0x42)
}

@(test)
mmu_register_readback_masks_high_bits :: proc(t: ^testing.T) {
	m := test_machine()
	defer test_machine_free(m)
	mem_write8(m, 0xFFA3, 0xFF)
	// 512K: only low 6 bits driven; upper 2 come from the last bus value
	got := mem_read8(m, 0xFFA3)
	testing.expect_value(t, got & 0x3F, 0x3F)
}

@(test)
ram_vectors_constant_page :: proc(t: ^testing.T) {
	m := test_machine()
	defer test_machine_free(m)
	mem_write8(m, 0xFF90, 0x08) // MC3: RAM vector page
	mem_write8(m, 0xFE10, 0x5A)
	testing.expect_value(t, mem_read8(m, 0xFE10), 0x5A)
	testing.expect_value(t, m.ram[0x2000 * 63 + 0x1E10], 0x5A)
}

@(test)
ram_size_128k :: proc(t: ^testing.T) {
	m := test_machine(0)
	defer test_machine_free(m)
	testing.expect_value(t, len(m.ram), 0x20000)
	mem_write8(m, 0x0000, 0x11)
	testing.expect_value(t, m.ram[8 * 0x2000], 0x11) // pages 8-15
	// ROM on pages 12-15: $8000 is page 12 + ... bank 4 -> page 12
	testing.expect_value(t, mem_read8(m, 0x8003), 0x03)
}

@(test)
gime_irq_enable_and_clear :: proc(t: ^testing.T) {
	m := test_machine()
	defer test_machine_free(m)
	mem_write8(m, 0xFF90, 0x20) // IRQ enabled to CPU
	mem_write8(m, 0xFF92, u8(GIME_INTR_VSYNC)) // enable VSYNC source
	gime_assert_hsync(m) // not enabled: ignored
	testing.expect_value(t, m.cpu.int_lines[.GIME], 0)
	gime_assert_vsync(m)
	testing.expect(t, m.cpu.int_lines[.GIME] & int_bit(.IRQ) != 0)
	got := mem_read8(m, 0xFF92) // returns state and clears
	testing.expect_value(t, u32(got), GIME_INTR_VSYNC)
	testing.expect_value(t, m.cpu.int_lines[.GIME] & int_bit(.IRQ), 0)
}

@(test)
gime_firq_separate :: proc(t: ^testing.T) {
	m := test_machine()
	defer test_machine_free(m)
	mem_write8(m, 0xFF90, 0x10) // FIRQ enabled
	mem_write8(m, 0xFF93, u8(GIME_INTR_TIMER))
	gime_assert_timer(m)
	testing.expect(t, m.cpu.int_lines[.GIME] & int_bit(.FIRQ) != 0)
	testing.expect_value(t, m.cpu.int_lines[.GIME] & int_bit(.IRQ), 0)
	mem_read8(m, 0xFF93)
	testing.expect_value(t, m.cpu.int_lines[.GIME] & int_bit(.FIRQ), 0)
}

@(test)
gime_irq_gated_by_init0 :: proc(t: ^testing.T) {
	m := test_machine()
	defer test_machine_free(m)
	mem_write8(m, 0xFF92, u8(GIME_INTR_KEYB))
	gime_assert_keyboard(m) // state latched but IRQ not enabled to CPU
	testing.expect_value(t, m.cpu.int_lines[.GIME], 0)
	mem_write8(m, 0xFF90, 0x20) // enabling reasserts pending state
	testing.expect(t, m.cpu.int_lines[.GIME] & int_bit(.IRQ) != 0)
}

@(test)
sam_vdg_bits :: proc(t: ^testing.T) {
	m := test_machine()
	defer test_machine_free(m)
	mem_write8(m, 0xFFC1, 0) // V0 set
	mem_write8(m, 0xFFC5, 0) // V2 set
	testing.expect_value(t, m.sam_vdg_mode, 5)
	mem_write8(m, 0xFFC0, 0) // V0 clear
	testing.expect_value(t, m.sam_vdg_mode, 4)
	mem_write8(m, 0xFFC7, 0) // F0 bit0... port C7 -> offset bit 0 set
	testing.expect_value(t, m.sam_dis_offset, 1)
	mem_write8(m, 0xFFD3, 0) // bit 6
	testing.expect_value(t, m.sam_dis_offset, 1 | 0x40)
}

@(test)
cpu_runs_from_rom_through_bus :: proc(t: ^testing.T) {
	m := test_machine()
	defer test_machine_free(m)
	// Put a program in RAM and jump to it: LDA #$5A ; STA $0100
	prog := [?]u8{0x86, 0x5A, 0xB7, 0x01, 0x00}
	for b, i in prog {mem_write8(m, 0x0400 + u16(i), b)}
	m.cpu.pc = 0x0400
	cpu_exec(&m.cpu, 1)
	cpu_exec(&m.cpu, 1)
	testing.expect_value(t, m.ram[0x0100 + 56 * 0x2000], 0x5A)
}

// Smoke test with the real ROM (skipped when coco3.rom is absent): the ROM
// must run its reset code without wandering off into unmapped space.
@(test)
real_rom_boot_smoke :: proc(t: ^testing.T) {
	data, err := os.read_entire_file("coco3.rom", context.allocator)
	if err != nil {return}
	defer delete(data)
	m := new(Machine)
	machine_init(m)
	defer test_machine_free(m)
	machine_load_rom(m, data)
	machine_reset(m)
	testing.expect(t, m.cpu.pc >= 0x8000)
	for _ in 0 ..< 200000 {
		cpu_exec(&m.cpu, 1)
	}
	// still executing from ROM or low RAM, not in the I/O page
	testing.expect(t, m.cpu.pc < 0xFF00)
	// The ROM has cleared/initialised text screen memory by now: count spaces ($60 or $20)
	spaces := 0
	for i in 0 ..< 512 {
		b := mem_read8(m, u16(0x0400 + i))
		if b == 0x60 || b == 0x20 {spaces += 1}
	}
	log.infof("pc=%04X spaces=%d", m.cpu.pc, spaces)
}
