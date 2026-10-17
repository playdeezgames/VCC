package vcc

// The whole CoCo 3: CPU, RAM/ROM, GIME (TCC1014) MMU + registers, and SAM
// (MC6883). Ports tcc1014mmu.cpp, tcc1014registers.cpp and iobus.cpp.
//
// A Machine must not be moved or copied after machine_init(): the CPU bus
// holds a pointer back to it.

// RAM configurations: 128K, 512K, 2M, 8M (indexes match VCC's RamConfig).
RAM_SIZE := [4]int{0x20000, 0x80000, 0x200000, 0x800000}
RAM_MASK := [4]u16{15, 63, 255, 1023}
STATE_SWITCH := [4]u16{8, 56, 56, 56}
VECTOR_MASK := [4]u16{15, 63, 63, 63}
VECTOR_MASKA := [4]u16{12, 60, 60, 60}

// GIME interrupt source bits ($FF92/$FF93)
GIME_INTR_TIMER :: u32(1) << 5
GIME_INTR_HSYNC :: u32(1) << 4
GIME_INTR_VSYNC :: u32(1) << 3
GIME_INTR_RS232 :: u32(1) << 2
GIME_INTR_KEYB :: u32(1) << 1
GIME_INTR_CART :: u32(1) << 0

Machine :: struct {
	cpu:             CPU6809,

	// memory
	ram_config:      int,
	ram:             []u8,
	rom:             [0x8000]u8, // internal ROM image (coco3.rom)
	cart:            []u8, // external ROM (e.g. disk11.rom at $C000), may be empty

	// MMU
	mmu_regs:        [4][8]u16, // [state][bank]: state = (!enabled)<<1 | task
	mmu_task:        u8,
	mmu_enabled:     bool,
	mmu_state:       int,
	mmu_prefix:      u16,
	ram_vectors:     bool, // INIT0 bit 3: constant vector page at $FE00
	rom_map:         u8, // INIT0 bits 1-0
	map_type:        u8, // SAM $FFDE/$FFDF: 1 = all RAM

	// GIME
	gime_regs:       [256]u8, // raw register file, indexed by low address byte
	gime_irq_state:  u32,
	gime_firq_state: u32,
	gime_last_irq:   u32,
	gime_last_firq:  u32,

	// SAM
	sam_vdg_mode:    u8,
	sam_dis_offset:  u8,
	cpu_fast_ram:    bool, // $FFD9: RAM high speed poke
}

machine_init :: proc(m: ^Machine, ram_config := 1) {
	m.ram_config = ram_config
	m.ram = make([]u8, RAM_SIZE[ram_config])
	// VCC powers up RAM as FF 00 FF 00 ...
	for i := 0; i < len(m.ram); i += 1 {
		m.ram[i] = 0 if i & 1 != 0 else 0xFF
	}
	for i in 0 ..< len(m.rom) {m.rom[i] = 0xFF}
	m.cpu.bus = Bus{m, machine_bus_read, machine_bus_write}
}

machine_destroy :: proc(m: ^Machine) {
	delete(m.ram)
	m.ram = nil
}

machine_load_rom :: proc(m: ^Machine, data: []u8) {
	n := min(len(data), len(m.rom))
	copy(m.rom[:n], data[:n])
}

machine_reset :: proc(m: ^Machine) {
	mmu_reset(m)
	gime_registers_reset(m)
	m.sam_vdg_mode = 0
	m.sam_dis_offset = 0
	m.cpu_fast_ram = false
	cpu_reset(&m.cpu)
}

// ---------------------------------------------------------------- MMU

mmu_reset :: proc(m: ^Machine) {
	m.mmu_task = 0
	m.mmu_enabled = false
	m.ram_vectors = false
	m.rom_map = 0
	m.map_type = 0
	m.mmu_prefix = 0
	for task in 0 ..< 4 {
		for bank in 0 ..< 8 {
			m.mmu_regs[task][bank] = u16(bank) + STATE_SWITCH[m.ram_config]
		}
	}
	mmu_update_state(m) // disabled MMU -> fixed map (VCC leaves state 0 until INIT0 is written)
}

mmu_update_state :: proc(m: ^Machine) {
	m.mmu_state = (0 if m.mmu_enabled else 2) | int(m.mmu_task)
}

set_mmu_register :: proc(m: ^Machine, reg, data: u8) {
	bank := reg & 7
	task := (reg >> 3) & 1
	m.mmu_regs[task][bank] = m.mmu_prefix | (u16(data) & RAM_MASK[m.ram_config])
}

// Physical page lookup result for a CPU address in $0000-$FEFF.
Page_Target :: enum {
	RAM,
	Internal_ROM,
	Cart,
}

// Where does a page number point, given the current map? Returns the target
// and the byte offset (page offset not included) into it.
page_target :: proc(m: ^Machine, page: u16) -> (Page_Target, int) {
	v := VECTOR_MASK[m.ram_config]
	if m.map_type == 0 && page >= v - 3 && page <= v {
		idx := int(page - (v - 3)) // 0..3 : $8000,$A000,$C000,$E000 style pages
		switch m.rom_map {
		case 0, 1: // 16K internal, 16K external
			if idx < 2 {return .Internal_ROM, idx * 0x2000}
			return .Cart, (idx - 2) * 0x2000
		case 2: // 32K internal
			return .Internal_ROM, idx * 0x2000
		case 3: // 32K external (offsets as in VCC's UpdateMmuArray)
			offsets := [4]int{0x4000, 0x6000, 0, 0x2000}
			return .Cart, offsets[idx]
		}
	}
	return .RAM, 0
}

page_read :: proc(m: ^Machine, addr: u16) -> u8 {
	page := m.mmu_regs[m.mmu_state][addr >> 13]
	off := int(addr & 0x1FFF)
	target, base := page_target(m, page)
	switch target {
	case .RAM:
		return m.ram[int(page & RAM_MASK[m.ram_config]) * 0x2000 + off]
	case .Internal_ROM:
		return m.rom[base + off]
	case .Cart:
		i := base + off
		if i < len(m.cart) {return m.cart[i]}
		return 0
	}
	return 0
}

mem_read8 :: proc(m: ^Machine, addr: u16) -> u8 {
	if addr < 0xFE00 {return page_read(m, addr)}
	if addr > 0xFEFF {return port_read(m, u8(addr))}
	if m.ram_vectors {
		return m.ram[int(0x2000 * u32(VECTOR_MASK[m.ram_config])) | int(addr & 0x1FFF)]
	}
	return page_read(m, addr)
}

mem_write8 :: proc(m: ^Machine, addr: u16, val: u8) {
	if addr > 0xFEFF {
		port_write(m, u8(addr), val)
		return
	}
	if addr >= 0xFE00 && m.ram_vectors {
		m.ram[int(0x2000 * u32(VECTOR_MASK[m.ram_config])) | int(addr & 0x1FFF)] = val
		return
	}
	page := m.mmu_regs[m.mmu_state][addr >> 13]
	if m.map_type != 0 || page < VECTOR_MASKA[m.ram_config] || page > VECTOR_MASK[m.ram_config] {
		m.ram[int(page & RAM_MASK[m.ram_config]) * 0x2000 + int(addr & 0x1FFF)] = val
	}
	// else: write to ROM space is ignored
}

machine_bus_read :: proc(ctx: rawptr, addr: u16) -> u8 {
	return mem_read8(cast(^Machine)ctx, addr)
}

machine_bus_write :: proc(ctx: rawptr, addr: u16, val: u8) {
	mem_write8(cast(^Machine)ctx, addr, val)
}

// ---------------------------------------------------------------- I/O bus
// $FF00-$FFFF, dispatched on the low address byte as in iobus.cpp.

port_read :: proc(m: ^Machine, port: u8) -> u8 {
	switch port {
	case 0x00 ..= 0x03:
		return pia0_read(m, port)
	case 0x20 ..= 0x23:
		return pia1_read(m, port)
	case 0x90 ..= 0xBF:
		return gime_read(m, port)
	case 0xC0 ..= 0xDF:
		return 0 // SAM registers are write-only
	case 0xF0 ..= 0xFF:
		return m.rom[0x7F00 + int(port)] // interrupt vectors come from ROM
	}
	return 0 // no cartridge answering (as VCC)
}

port_write :: proc(m: ^Machine, port: u8, val: u8) {
	switch port {
	case 0x00 ..= 0x03:
		pia0_write(m, port, val)
	case 0x20 ..= 0x23:
		pia1_write(m, port, val)
	case 0x90 ..= 0xBF:
		gime_write(m, port, val)
	case 0xC0 ..= 0xDF:
		sam_write(m, port)
	}
}

// PIA stand-ins until milestone 4.
pia0_read :: proc(m: ^Machine, port: u8) -> u8 {return 0}
pia0_write :: proc(m: ^Machine, port: u8, val: u8) {}
pia1_read :: proc(m: ^Machine, port: u8) -> u8 {return 0}
pia1_write :: proc(m: ^Machine, port: u8, val: u8) {}

// ---------------------------------------------------------------- SAM

sam_write :: proc(m: ^Machine, port_in: u8) {
	port := port_in
	if port >= 0xC6 && port <= 0xD3 { 	// VDG display offset
		p := port - 0xC6
		mask := u8(1) << ((p & 0x0E) >> 1)
		m.sam_dis_offset &= ~mask
		if p & 1 != 0 {m.sam_dis_offset |= mask}
	}
	if port >= 0xC0 && port <= 0xC5 { 	// VDG mode
		p := port - 0xC0
		mask := u8(1) << ((p & 0x0E) >> 1)
		m.sam_vdg_mode &= ~mask
		if p & 1 != 0 {m.sam_vdg_mode |= mask}
	}
	if port == 0xDE || port == 0xDF {
		m.map_type = port & 1
	}
	if port == 0xD8 {m.cpu_fast_ram = false}
	if port == 0xD9 {m.cpu_fast_ram = true}
}

// ---------------------------------------------------------------- GIME

gime_irq_to_cpu :: proc(m: ^Machine) -> bool {return m.gime_regs[0x90] & 0x20 != 0}
gime_firq_to_cpu :: proc(m: ^Machine) -> bool {return m.gime_regs[0x90] & 0x10 != 0}

gime_timer_counter :: proc(m: ^Machine) -> u16 {
	return (u16(m.gime_regs[0x94]) << 8 | u16(m.gime_regs[0x95])) & 0xFFF
}

gime_registers_reset :: proc(m: ^Machine) {
	m.gime_regs = {}
	m.gime_irq_state = 0
	m.gime_firq_state = 0
	m.gime_last_irq = 0
	m.gime_last_firq = 0
}

// Raise a GIME_INTR_* source; merged into the IRQ/FIRQ state when enabled.
gime_set_interrupt :: proc(m: ^Machine, flag: u32) {
	m.gime_irq_state |= (flag & u32(m.gime_regs[0x92])) & 0x3F
	m.gime_firq_state |= (flag & u32(m.gime_regs[0x93])) & 0x3F

	prev_irq := m.gime_last_irq
	prev_firq := m.gime_last_firq
	m.gime_last_irq = m.gime_irq_state if gime_irq_to_cpu(m) else 0
	m.gime_last_firq = m.gime_firq_state if gime_firq_to_cpu(m) else 0

	if prev_irq != m.gime_last_irq {
		if m.gime_last_irq != 0 {
			cpu_assert_interrupt(&m.cpu, .GIME, .IRQ)
		} else {
			cpu_deassert_interrupt(&m.cpu, .GIME, .IRQ)
		}
	}
	if prev_firq != m.gime_last_firq {
		if m.gime_last_firq != 0 {
			cpu_assert_interrupt(&m.cpu, .GIME, .FIRQ)
		} else {
			cpu_deassert_interrupt(&m.cpu, .GIME, .FIRQ)
		}
	}
}

// Clear IRQ flags (keeps those set in nflag). Returns the previous state.
gime_clear_irq :: proc(m: ^Machine, nflag: u32) -> u8 {
	prev_state := m.gime_irq_state
	prev := m.gime_last_irq
	m.gime_irq_state &= nflag
	m.gime_last_irq &= nflag
	if prev != 0 && m.gime_last_irq == 0 {
		cpu_deassert_interrupt(&m.cpu, .GIME, .IRQ)
	}
	return u8(prev_state)
}

gime_clear_firq :: proc(m: ^Machine, nflag: u32) -> u8 {
	prev_state := m.gime_firq_state
	prev := m.gime_last_firq
	m.gime_firq_state &= nflag
	m.gime_last_firq &= nflag
	if prev != 0 && m.gime_last_firq == 0 {
		cpu_deassert_interrupt(&m.cpu, .GIME, .FIRQ)
	}
	return u8(prev_state)
}

gime_assert_timer :: proc(m: ^Machine) {gime_set_interrupt(m, GIME_INTR_TIMER)}
gime_assert_hsync :: proc(m: ^Machine) {gime_set_interrupt(m, GIME_INTR_HSYNC)}
gime_assert_vsync :: proc(m: ^Machine) {gime_set_interrupt(m, GIME_INTR_VSYNC)}
gime_assert_keyboard :: proc(m: ^Machine) {gime_set_interrupt(m, GIME_INTR_KEYB)}
gime_assert_cart :: proc(m: ^Machine) {gime_set_interrupt(m, GIME_INTR_CART)}

gime_write :: proc(m: ^Machine, port: u8, data: u8) {
	changed := m.gime_regs[port] ~ data
	m.gime_regs[port] = data

	// With the timer at 0 and enabled it interrupts almost immediately.
	if_zero_timer :: proc(m: ^Machine, changed, data: u8) {
		if u32(data & changed) & GIME_INTR_TIMER != 0 && gime_timer_counter(m) == 0 {
			gime_assert_timer(m)
		}
	}

	switch port {
	case 0x90: // INIT0
		m.mmu_enabled = data & 0x40 != 0
		mmu_update_state(m)
		m.rom_map = data & 3
		m.ram_vectors = data & 8 != 0
		gime_set_interrupt(m, m.gime_irq_state | m.gime_firq_state)
	case 0x91: // INIT1
		m.mmu_task = data & 1
		mmu_update_state(m)
	case 0x92:
		gime_clear_irq(m, u32(data))
		if_zero_timer(m, changed, data)
	case 0x93:
		gime_clear_firq(m, u32(data))
		if_zero_timer(m, changed, data)
	case 0x9B: // video bank (2M/8M only)
		if m.ram_config == 3 {m.mmu_prefix = u16(data & 0x30) >> 4 << 8}
		if m.ram_config == 2 {m.mmu_prefix = 0}
	case 0xA0 ..= 0xAF:
		set_mmu_register(m, port, data)
	}
	// timer ($FF94/$FF95), video ($FF98-$FF9F) and palette ($FFB0-$FFBF)
	// registers are read straight from gime_regs by the video/timer code.
}

gime_read :: proc(m: ^Machine, port: u8) -> u8 {
	last_bus := proc(m: ^Machine) -> u8 {
		return mem_read8(m, m.cpu.pc) if m.cpu.pc < 0xFF00 else 0
	}
	switch port {
	case 0x92:
		// Reading clears the IRQ flags and drops the line (else Robocop's sound stutters).
		return gime_clear_irq(m, 0)
	case 0x93:
		return gime_clear_firq(m, 0)
	}
	data := m.gime_regs[port]
	if port >= 0xA0 && port <= 0xAF {
		if m.ram_config <= 1 {return last_bus(m) & 0xC0 | data & 0x3F}
		return data
	}
	if port >= 0xB0 && port <= 0xBF {
		return last_bus(m) & 0xC0 | data & 0x3F
	}
	return last_bus(m) // other GIME registers are unreadable
}
