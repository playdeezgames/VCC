package vcc

// Motorola MC6809 core. Behaviour and cycle counts follow mc6809.cpp / the
// 6809 datasheet. The core talks to memory through Bus and counts cycles in
// CPU6809.cycles; cpu_exec() runs whole instructions until a budget is spent.

Flag :: enum u8 {
	C, // carry / borrow
	V, // overflow
	Z, // zero
	N, // negative
	I, // IRQ mask
	H, // half carry
	F, // FIRQ mask
	E, // entire state saved
}
Flags :: bit_set[Flag;u8]

Bus :: struct {
	ctx:   rawptr,
	read:  proc(ctx: rawptr, addr: u16) -> u8,
	write: proc(ctx: rawptr, addr: u16, val: u8),
}

// Interrupt kinds (bit index in the per-source line masks).
Interrupt :: enum u8 {
	IRQ  = 1,
	FIRQ = 2,
	NMI  = 3,
}

Int_Source :: enum {
	NMI,
	PIA0_HSYNC,
	PIA0_VSYNC,
	PIA1_CD,
	PIA1_CART,
	GIME,
}

VEC_SWI3 :: 0xFFF2
VEC_SWI2 :: 0xFFF4
VEC_FIRQ :: 0xFFF6
VEC_IRQ :: 0xFFF8
VEC_SWI :: 0xFFFA
VEC_NMI :: 0xFFFC
VEC_RESET :: 0xFFFE

CPU6809 :: struct {
	bus:          Bus,
	a, b, dp:     u8,
	x, y, u, s:   u16,
	pc:           u16,
	cc:           Flags,
	cycles:       int, // cycles consumed in the current cpu_exec call
	sync_waiting: bool,
	int_lines:    [Int_Source]u8, // per-source asserted interrupt bits
	latch_d:      u8, // most recent latch input
	latch_q:      u8, // previous latch input (what the CPU acts on)

	// Optional hook: when execution reaches hook_pc the hook runs instead of
	// the instruction; returning true means it handled it (including any
	// cycles and PC change). Used to feed text into BASIC's keyboard routine.
	hook:         proc(ctx: rawptr, c: ^CPU6809) -> bool,
	hook_ctx:     rawptr,
	hook_pc:      u16,
}

Mode :: enum {
	Imm,
	Direct,
	Indexed,
	Extended,
}

// ---------------------------------------------------------------- bus helpers

read8 :: #force_inline proc(c: ^CPU6809, addr: u16) -> u8 {
	return c.bus.read(c.bus.ctx, addr)
}

write8 :: #force_inline proc(c: ^CPU6809, addr: u16, val: u8) {
	c.bus.write(c.bus.ctx, addr, val)
}

read16 :: proc(c: ^CPU6809, addr: u16) -> u16 {
	return u16(read8(c, addr)) << 8 | u16(read8(c, addr + 1))
}

write16 :: proc(c: ^CPU6809, addr: u16, val: u16) {
	write8(c, addr, u8(val >> 8))
	write8(c, addr + 1, u8(val))
}

fetch8 :: #force_inline proc(c: ^CPU6809) -> u8 {
	v := read8(c, c.pc)
	c.pc += 1
	return v
}

fetch16 :: proc(c: ^CPU6809) -> u16 {
	v := read16(c, c.pc)
	c.pc += 2
	return v
}

// ---------------------------------------------------------------- registers

get_d :: #force_inline proc(c: ^CPU6809) -> u16 {return u16(c.a) << 8 | u16(c.b)}
set_d :: #force_inline proc(c: ^CPU6809, v: u16) {
	c.a = u8(v >> 8)
	c.b = u8(v)
}

get_cc :: #force_inline proc(c: ^CPU6809) -> u8 {return transmute(u8)c.cc}
set_cc :: #force_inline proc(c: ^CPU6809, v: u8) {c.cc = transmute(Flags)v}

flag :: #force_inline proc(c: ^CPU6809, f: Flag) -> bool {return f in c.cc}
set_flag :: #force_inline proc(c: ^CPU6809, f: Flag, on: bool) {
	if on {c.cc += {f}} else {c.cc -= {f}}
}

set_nz8 :: #force_inline proc(c: ^CPU6809, v: u8) {
	set_flag(c, .N, v & 0x80 != 0)
	set_flag(c, .Z, v == 0)
}

set_nz16 :: #force_inline proc(c: ^CPU6809, v: u16) {
	set_flag(c, .N, v & 0x8000 != 0)
	set_flag(c, .Z, v == 0)
}

cpu_reset :: proc(c: ^CPU6809) {
	c.a, c.b, c.dp = 0, 0, 0
	c.x, c.y, c.u, c.s, c.pc = 0, 0, 0, 0, 0
	c.cc = {.I, .F}
	c.sync_waiting = false
	c.int_lines = {}
	c.latch_d, c.latch_q = 0, 0
	c.pc = read16(c, VEC_RESET)
}

// ---------------------------------------------------------------- interrupts

int_bit :: #force_inline proc(i: Interrupt) -> u8 {return 1 << u8(i)}

cpu_assert_interrupt :: proc(c: ^CPU6809, src: Int_Source, i: Interrupt) {
	c.int_lines[src] |= int_bit(i)
	if c.sync_waiting || i == .NMI {
		latch_interrupts(c)
	}
	c.sync_waiting = false
}

cpu_deassert_interrupt :: proc(c: ^CPU6809, src: Int_Source, i: Interrupt) {
	c.int_lines[src] &= ~int_bit(i)
}

// Clock the interrupt latch. Done once per instruction (and while in SYNC).
latch_interrupts :: proc(c: ^CPU6809) {
	or_all: u8
	for l in c.int_lines {or_all |= l}
	c.latch_q = c.latch_d
	c.latch_d = or_all
}

push_s16 :: proc(c: ^CPU6809, v: u16) {
	c.s -= 1
	write8(c, c.s, u8(v))
	c.s -= 1
	write8(c, c.s, u8(v >> 8))
}

push_u16 :: proc(c: ^CPU6809, v: u16) {
	c.u -= 1
	write8(c, c.u, u8(v))
	c.u -= 1
	write8(c, c.u, u8(v >> 8))
}

push_s8 :: proc(c: ^CPU6809, v: u8) {
	c.s -= 1
	write8(c, c.s, v)
}

pull_s8 :: proc(c: ^CPU6809) -> u8 {
	v := read8(c, c.s)
	c.s += 1
	return v
}

pull_s16 :: proc(c: ^CPU6809) -> u16 {
	hi := pull_s8(c)
	lo := pull_s8(c)
	return u16(hi) << 8 | u16(lo)
}

// Push the entire register set (IRQ, NMI, SWI*): sets E.
push_entire :: proc(c: ^CPU6809) {
	c.cc += {.E}
	push_s16(c, c.pc)
	push_s16(c, c.u)
	push_s16(c, c.y)
	push_s16(c, c.x)
	push_s8(c, c.dp)
	push_s8(c, c.b)
	push_s8(c, c.a)
	push_s8(c, get_cc(c))
}

service_firq :: proc(c: ^CPU6809) {
	c.cc -= {.E}
	push_s16(c, c.pc)
	push_s8(c, get_cc(c))
	c.cc += {.I, .F}
	c.pc = read16(c, VEC_FIRQ)
	c.cycles += 15
}

service_irq :: proc(c: ^CPU6809) {
	push_entire(c)
	c.pc = read16(c, VEC_IRQ)
	c.cc += {.I}
	c.cycles += 24
}

service_nmi :: proc(c: ^CPU6809) {
	push_entire(c)
	c.cc += {.I, .F}
	c.pc = read16(c, VEC_NMI)
	c.cycles += 24
	// Edge triggered: drop the NMI request.
	c.int_lines[.NMI] &= ~int_bit(.NMI)
	latch_interrupts(c)
}

// ---------------------------------------------------------------- addressing

index_reg :: proc(c: ^CPU6809, n: u8) -> ^u16 {
	switch n & 3 {
	case 0:
		return &c.x
	case 1:
		return &c.y
	case 2:
		return &c.u
	}
	return &c.s
}

sext8 :: #force_inline proc(v: u8) -> u16 {return u16(i16(i8(v)))}

// Indexed effective address (reads the postbyte). Adds the extra cycles.
indexed_ea :: proc(c: ^CPU6809) -> u16 {
	pb := fetch8(c)
	r := index_reg(c, pb >> 5)

	if pb & 0x80 == 0 {
		// 5 bit signed offset
		off := u16(pb & 0x1F)
		if off & 0x10 != 0 {off |= 0xFFE0}
		c.cycles += 1
		return r^ + off
	}

	ea: u16
	indirect := pb & 0x10 != 0
	switch pb & 0x0F {
	case 0x0:
		if indirect {return 0} // ",R+" has no indirect form
		ea = r^
		r^ += 1
		c.cycles += 2
	case 0x1:
		ea = r^
		r^ += 2
		c.cycles += 3
	case 0x2:
		if indirect {return 0} // ",-R" has no indirect form
		r^ -= 1
		ea = r^
		c.cycles += 2
	case 0x3:
		r^ -= 2
		ea = r^
		c.cycles += 3
	case 0x4:
		ea = r^
	case 0x5:
		ea = r^ + sext8(c.b)
		c.cycles += 1
	case 0x6:
		ea = r^ + sext8(c.a)
		c.cycles += 1
	case 0x8:
		ea = r^ + sext8(fetch8(c))
		c.cycles += 1
	case 0x9:
		ea = r^ + fetch16(c)
		c.cycles += 4
	case 0xB:
		ea = r^ + get_d(c)
		c.cycles += 4
	case 0xC:
		off := sext8(fetch8(c))
		ea = c.pc + off
		c.cycles += 1
	case 0xD:
		off := fetch16(c)
		ea = c.pc + off
		c.cycles += 5
	case 0xF:
		// [nnnn] extended indirect (only valid with indirect bit set)
		if !indirect {return 0}
		ea = fetch16(c)
		c.cycles += 2 // total 5 with the indirect read (datasheet Table 2; VCC uses 8)
	case:
		// reserved postbytes
		return 0
	}

	if indirect {
		ea = read16(c, ea)
		c.cycles += 3
	}
	return ea
}

// Resolve the operand address for a mode. For Imm the operand sits at PC and
// PC is advanced by size (1 or 2).
operand_addr :: proc(c: ^CPU6809, mode: Mode, size: u16) -> u16 {
	switch mode {
	case .Imm:
		a := c.pc
		c.pc += size
		return a
	case .Direct:
		return u16(c.dp) << 8 | u16(fetch8(c))
	case .Indexed:
		return indexed_ea(c)
	case .Extended:
		return fetch16(c)
	}
	return 0
}

// ---------------------------------------------------------------- ALU

sub8 :: proc(c: ^CPU6809, a, b, carry: u8) -> u8 {
	r := u16(a) - u16(b) - u16(carry)
	res := u8(r)
	set_flag(c, .C, r & 0x100 != 0)
	set_flag(c, .V, (a ~ b) & (a ~ res) & 0x80 != 0)
	set_nz8(c, res)
	return res
}

add8 :: proc(c: ^CPU6809, a, b, carry: u8) -> u8 {
	r := u16(a) + u16(b) + u16(carry)
	res := u8(r)
	set_flag(c, .C, r & 0x100 != 0)
	set_flag(c, .H, (a ~ b ~ res) & 0x10 != 0)
	set_flag(c, .V, ~(a ~ b) & (a ~ res) & 0x80 != 0)
	set_nz8(c, res)
	return res
}

sub16 :: proc(c: ^CPU6809, a, b: u16) -> u16 {
	r := u32(a) - u32(b)
	res := u16(r)
	set_flag(c, .C, r & 0x10000 != 0)
	set_flag(c, .V, (a ~ b) & (a ~ res) & 0x8000 != 0)
	set_nz16(c, res)
	return res
}

add16 :: proc(c: ^CPU6809, a, b: u16) -> u16 {
	r := u32(a) + u32(b)
	res := u16(r)
	set_flag(c, .C, r & 0x10000 != 0)
	set_flag(c, .V, ~(a ~ b) & (a ~ res) & 0x8000 != 0)
	set_nz16(c, res)
	return res
}

// 8 bit accumulator operations of the $80/$C0 blocks. Returns the new value
// and whether it must be stored back to the register.
alu8 :: proc(c: ^CPU6809, col: u8, r, m: u8) -> (res: u8, store: bool) {
	carry := u8(1) if flag(c, .C) else 0
	switch col {
	case 0x0:
		return sub8(c, r, m, 0), true
	case 0x1:
		_ = sub8(c, r, m, 0)
		return r, false
	case 0x2:
		return sub8(c, r, m, carry), true
	case 0x4:
		res = r & m
	case 0x5:
		res = r & m
		set_nz8(c, res)
		set_flag(c, .V, false)
		return r, false
	case 0x6:
		res = m
	case 0x8:
		res = r ~ m
	case 0x9:
		return add8(c, r, m, carry), true
	case 0xA:
		res = r | m
	case 0xB:
		return add8(c, r, m, 0), true
	}
	// logical ops / load: N,Z set, V cleared
	set_nz8(c, res)
	set_flag(c, .V, false)
	return res, true
}

// Single operand read-modify-write operations (low nibble of $0x/$4x/$5x/$6x/$7x).
// ok is false for illegal encodings; write is false for TST.
rmw_op :: proc(c: ^CPU6809, nib: u8, v: u8) -> (res: u8, write: bool, ok: bool) {
	write = true
	ok = true
	switch nib {
	case 0x0: // NEG
		res = 0 - v
		set_flag(c, .C, res != 0)
		set_flag(c, .V, v == 0x80)
		set_nz8(c, res)
	case 0x3: // COM
		res = ~v
		set_flag(c, .C, true)
		set_flag(c, .V, false)
		set_nz8(c, res)
	case 0x4: // LSR
		set_flag(c, .C, v & 1 != 0)
		res = v >> 1
		set_flag(c, .N, false)
		set_flag(c, .Z, res == 0)
	case 0x6: // ROR
		old := u8(0x80) if flag(c, .C) else 0
		set_flag(c, .C, v & 1 != 0)
		res = v >> 1 | old
		set_nz8(c, res)
	case 0x7: // ASR
		set_flag(c, .C, v & 1 != 0)
		res = v & 0x80 | v >> 1
		set_nz8(c, res)
	case 0x8: // ASL / LSL
		set_flag(c, .C, v & 0x80 != 0)
		set_flag(c, .V, (v ~ v << 1) & 0x80 != 0)
		res = v << 1
		set_nz8(c, res)
	case 0x9: // ROL
		old := u8(1) if flag(c, .C) else 0
		set_flag(c, .C, v & 0x80 != 0)
		set_flag(c, .V, (v ~ v << 1) & 0x80 != 0)
		res = v << 1 | old
		set_nz8(c, res)
	case 0xA: // DEC
		res = v - 1
		set_flag(c, .V, res == 0x7F)
		set_nz8(c, res)
	case 0xC: // INC
		res = v + 1
		set_flag(c, .V, res == 0x80)
		set_nz8(c, res)
	case 0xD: // TST
		res = v
		write = false
		set_flag(c, .V, false)
		set_nz8(c, res)
	case 0xF: // CLR
		res = 0
		set_flag(c, .C, false)
		set_flag(c, .V, false)
		set_flag(c, .N, false)
		set_flag(c, .Z, true)
	case:
		ok = false
		write = false
	}
	return
}

branch_cond :: proc(c: ^CPU6809, n: u8) -> bool {
	C := flag(c, .C)
	Z := flag(c, .Z)
	N := flag(c, .N)
	V := flag(c, .V)
	switch n & 0xF {
	case 0x0:
		return true
	case 0x1:
		return false
	case 0x2:
		return !(C || Z)
	case 0x3:
		return C || Z
	case 0x4:
		return !C
	case 0x5:
		return C
	case 0x6:
		return !Z
	case 0x7:
		return Z
	case 0x8:
		return !V
	case 0x9:
		return V
	case 0xA:
		return !N
	case 0xB:
		return N
	case 0xC:
		return N == V
	case 0xD:
		return N != V
	case 0xE:
		return !Z && N == V
	case 0xF:
		return Z || N != V
	}
	return false
}

// ---------------------------------------------------------------- TFR / EXG

// For EXG with a 16 bit first register, 8 bit registers read as $FFxx.
read_tfr_reg :: proc(c: ^CPU6809, r: u8, tfr_style: bool) -> u16 {
	switch r & 0xF {
	case 0:
		return get_d(c)
	case 1:
		return c.x
	case 2:
		return c.y
	case 3:
		return c.u
	case 4:
		return c.s
	case 5:
		return c.pc
	case 8:
		return 0xFF00 | u16(c.a)
	case 9:
		return 0xFF00 | u16(c.b)
	case 10:
		v := u16(get_cc(c))
		return (v << 8 | v) if tfr_style else 0xFF00 | v
	case 11:
		v := u16(c.dp)
		return (v << 8 | v) if tfr_style else 0xFF00 | v
	}
	return 0xFFFF
}

write_tfr_reg :: proc(c: ^CPU6809, r: u8, v: u16) {
	switch r & 0xF {
	case 0:
		set_d(c, v)
	case 1:
		c.x = v
	case 2:
		c.y = v
	case 3:
		c.u = v
	case 4:
		c.s = v
	case 5:
		c.pc = v
	case 8:
		c.a = u8(v)
	case 9:
		c.b = u8(v)
	case 10:
		set_cc(c, u8(v))
	case 11:
		c.dp = u8(v)
	}
}

// ---------------------------------------------------------------- execution

// Run instructions until at least cycle_for cycles have elapsed. Returns the
// number of cycles run beyond the budget (0 when waiting in SYNC).
cpu_exec :: proc(c: ^CPU6809, cycle_for: int) -> int {
	c.cycles = 0
	for c.cycles < cycle_for {
		latch_interrupts(c)
		if c.latch_q & int_bit(.NMI) != 0 {
			service_nmi(c)
		} else if c.latch_q & int_bit(.FIRQ) != 0 && !flag(c, .F) {
			service_firq(c)
		} else if c.latch_q & int_bit(.IRQ) != 0 && !flag(c, .I) {
			service_irq(c)
		}

		if c.sync_waiting {
			return 0
		}

		step(c, cycle_for)
	}
	return c.cycles - cycle_for
}

step :: proc(c: ^CPU6809, cycle_for: int) {
	if c.hook != nil && c.pc == c.hook_pc {
		if c.hook(c.hook_ctx, c) {return}
	}
	op := fetch8(c)
	switch {
	case op < 0x10 || (op >= 0x60 && op < 0x80):
		mem_rmw(c, op)
	case op >= 0x40 && op < 0x60:
		acc_rmw(c, op)
	case op >= 0x80:
		alu_block(c, op)
	case:
		misc_op(c, op, cycle_for)
	}
}

// $00-$0F direct, $60-$6F indexed, $70-$7F extended.
mem_rmw :: proc(c: ^CPU6809, op: u8) {
	mode: Mode = .Direct
	if op >= 0x70 {mode = .Extended} else if op >= 0x60 {mode = .Indexed}
	nib := op & 0xF

	switch nib {
	case 0x1, 0x2, 0x5, 0xB:
		c.cycles += 1 // illegal
		return
	case 0xE: // JMP
		c.pc = operand_addr(c, mode, 0)
		c.cycles += 4 if mode == .Extended else 3
		return
	}

	ea := operand_addr(c, mode, 0)
	v: u8
	if nib != 0xF {v = read8(c, ea)} // CLR does not read (as in VCC)
	res, write, _ := rmw_op(c, nib, v)
	if write {write8(c, ea, res)}
	c.cycles += 7 if mode == .Extended else 6
}

// $40-$4F (A) and $50-$5F (B)
acc_rmw :: proc(c: ^CPU6809, op: u8) {
	reg := &c.a if op < 0x50 else &c.b
	res, write, ok := rmw_op(c, op & 0xF, reg^)
	if ok && write {reg^ = res}
	c.cycles += 2
}

// $80-$FF
alu_block :: proc(c: ^CPU6809, op: u8) {
	modes := [4]Mode{.Imm, .Direct, .Indexed, .Extended}
	mode := modes[(op >> 4) & 3]
	col := op & 0xF
	is_b := op >= 0xC0

	cyc8 := [Mode]int {
		.Imm      = 2,
		.Direct   = 4,
		.Indexed  = 4,
		.Extended = 5,
	}
	cyc16s := [Mode]int {
		.Imm      = 3,
		.Direct   = 5,
		.Indexed  = 5,
		.Extended = 6,
	}
	cyc16l := [Mode]int {
		.Imm      = 4,
		.Direct   = 6,
		.Indexed  = 6,
		.Extended = 7,
	}

	switch col {
	case 0x0, 0x1, 0x2, 0x4, 0x5, 0x6, 0x8, 0x9, 0xA, 0xB:
		ea := operand_addr(c, mode, 1)
		m := read8(c, ea)
		reg := &c.b if is_b else &c.a
		res, store := alu8(c, col, reg^, m)
		if store {reg^ = res}
		c.cycles += cyc8[mode]

	case 0x7: // STA / STB
		if mode == .Imm {c.cycles += 1; return}
		ea := operand_addr(c, mode, 1)
		v := c.b if is_b else c.a
		write8(c, ea, v)
		set_nz8(c, v)
		set_flag(c, .V, false)
		c.cycles += cyc8[mode]

	case 0x3: // SUBD / ADDD
		ea := operand_addr(c, mode, 2)
		m := read16(c, ea)
		if is_b {
			set_d(c, add16(c, get_d(c), m))
		} else {
			set_d(c, sub16(c, get_d(c), m))
		}
		c.cycles += cyc16l[mode]

	case 0xC: // CMPX / LDD
		ea := operand_addr(c, mode, 2)
		m := read16(c, ea)
		if is_b {
			set_d(c, m)
			set_nz16(c, m)
			set_flag(c, .V, false)
			c.cycles += cyc16s[mode]
		} else {
			_ = sub16(c, c.x, m)
			c.cycles += cyc16l[mode]
		}

	case 0xD: // BSR / JSR / STD
		if is_b {
			if mode == .Imm {c.cycles += 1; return}
			ea := operand_addr(c, mode, 2)
			d := get_d(c)
			write16(c, ea, d)
			set_nz16(c, d)
			set_flag(c, .V, false)
			c.cycles += cyc16s[mode]
		} else if mode == .Imm {
			off := sext8(fetch8(c))
			push_s16(c, c.pc)
			c.pc += off
			c.cycles += 7
		} else {
			ea := operand_addr(c, mode, 0)
			push_s16(c, c.pc)
			c.pc = ea
			c.cycles += 8 if mode == .Extended else 7
		}

	case 0xE: // LDX / LDU
		ea := operand_addr(c, mode, 2)
		m := read16(c, ea)
		if is_b {c.u = m} else {c.x = m}
		set_nz16(c, m)
		set_flag(c, .V, false)
		c.cycles += cyc16s[mode]

	case 0xF: // STX / STU
		if mode == .Imm {c.cycles += 1; return}
		ea := operand_addr(c, mode, 2)
		v := c.u if is_b else c.x
		write16(c, ea, v)
		set_nz16(c, v)
		set_flag(c, .V, false)
		c.cycles += cyc16s[mode]
	}
}

// Page 2 ($10xx) and page 3 ($11xx)
page_op :: proc(c: ^CPU6809, page: u8) {
	op := fetch8(c)
	c.cycles += 1 // prefix

	if page == 2 && op >= 0x21 && op <= 0x2F {
		cond := branch_cond(c, op)
		off := fetch16(c)
		c.cycles += 4 // 5 total with the prefix cycle
		if cond && op != 0x21 {
			c.pc += off
			c.cycles += 1
		}
		return
	}
	if op == 0x3F {
		push_entire(c)
		c.pc = read16(c, VEC_SWI2 if page == 2 else VEC_SWI3)
		c.cycles += 19
		return
	}
	if page == 3 && op == 0x3E {
		c.cycles += 3 // VCC "break" opcode: no-op
		return
	}
	if op < 0x80 {
		c.cycles += 1
		return
	}

	modes := [4]Mode{.Imm, .Direct, .Indexed, .Extended}
	mode := modes[(op >> 4) & 3]
	col := op & 0xF
	cyc16s := [Mode]int {
		.Imm      = 3,
		.Direct   = 5,
		.Indexed  = 5,
		.Extended = 6,
	}
	cyc16l := [Mode]int {
		.Imm      = 4,
		.Direct   = 6,
		.Indexed  = 6,
		.Extended = 7,
	}

	switch {
	case (col == 0x3 || col == 0xC) && op < 0xC0: // CMPD/CMPY, CMPU/CMPS
		ea := operand_addr(c, mode, 2)
		m := read16(c, ea)
		r: u16
		if page == 2 {
			r = get_d(c) if col == 0x3 else c.y
		} else {
			r = c.u if col == 0x3 else c.s
		}
		_ = sub16(c, r, m)
		c.cycles += cyc16l[mode]

	case page == 2 && col == 0xE: // LDY / LDS
		ea := operand_addr(c, mode, 2)
		m := read16(c, ea)
		if op < 0xC0 {c.y = m} else {c.s = m}
		set_nz16(c, m)
		set_flag(c, .V, false)
		c.cycles += cyc16s[mode]

	case page == 2 && col == 0xF: // STY / STS
		if mode == .Imm {return}
		ea := operand_addr(c, mode, 2)
		v := c.y if op < 0xC0 else c.s
		write16(c, ea, v)
		set_nz16(c, v)
		set_flag(c, .V, false)
		c.cycles += cyc16s[mode]

	case:
		c.cycles += 1 // illegal
	}
}

// $10-$3F plus a few leftovers
misc_op :: proc(c: ^CPU6809, op: u8, cycle_for: int) {
	switch op {
	case 0x10:
		page_op(c, 2)
	case 0x11:
		page_op(c, 3)
	case 0x12, 0x15: // NOP, VCC HALT (no-op here)
		c.cycles += 2
	case 0x13: // SYNC
		c.cycles = cycle_for
		c.sync_waiting = true
	case 0x16: // LBRA
		off := fetch16(c)
		c.pc += off
		c.cycles += 5
	case 0x17: // LBSR
		off := fetch16(c)
		push_s16(c, c.pc)
		c.pc += off
		c.cycles += 9
	case 0x19: // DAA
		msn := c.a & 0xF0
		lsn := c.a & 0x0F
		adj: u8
		if flag(c, .H) || lsn > 9 {adj |= 0x06}
		if msn > 0x80 && lsn > 9 {adj |= 0x60}
		if msn > 0x90 || flag(c, .C) {adj |= 0x60}
		sum := u16(c.a) + u16(adj)
		if sum & 0x100 != 0 {set_flag(c, .C, true)}
		c.a = u8(sum)
		set_nz8(c, c.a)
		c.cycles += 2
	case 0x1A: // ORCC
		set_cc(c, get_cc(c) | fetch8(c))
		c.cycles += 3
	case 0x1C: // ANDCC
		set_cc(c, get_cc(c) & fetch8(c))
		c.cycles += 3
	case 0x1D: // SEX
		c.a = 0xFF if c.b & 0x80 != 0 else 0
		set_nz16(c, get_d(c))
		c.cycles += 2
	case 0x1E: // EXG
		pb := fetch8(c)
		first := pb >> 4
		second := pb & 0xF
		tfr_style := pb & 0x80 != 0
		v1 := read_tfr_reg(c, first, tfr_style)
		v2 := read_tfr_reg(c, second, tfr_style)
		write_tfr_reg(c, second, v1)
		write_tfr_reg(c, first, v2)
		c.cycles += 8
	case 0x1F: // TFR
		pb := fetch8(c)
		write_tfr_reg(c, pb & 0xF, read_tfr_reg(c, pb >> 4, true))
		c.cycles += 6

	case 0x20 ..= 0x2F: // short branches
		off := sext8(fetch8(c))
		if branch_cond(c, op) {c.pc += off}
		c.cycles += 3

	case 0x30 ..= 0x33: // LEAX LEAY LEAS LEAU
		ea := indexed_ea(c)
		switch op {
		case 0x30:
			c.x = ea
			set_flag(c, .Z, ea == 0)
		case 0x31:
			c.y = ea
			set_flag(c, .Z, ea == 0)
		case 0x32:
			c.s = ea
		case 0x33:
			c.u = ea
		}
		c.cycles += 4

	case 0x34, 0x36: // PSHS / PSHU
		pb := fetch8(c)
		is_s := op == 0x34
		other := c.u if is_s else c.s
		push16 := push_s16 if is_s else push_u16
		push8 := proc(c: ^CPU6809, v: u8, is_s: bool) {
			if is_s {
				c.s -= 1
				write8(c, c.s, v)
			} else {
				c.u -= 1
				write8(c, c.u, v)
			}
		}
		if pb & 0x80 != 0 {push16(c, c.pc); c.cycles += 2}
		if pb & 0x40 != 0 {push16(c, other); c.cycles += 2}
		if pb & 0x20 != 0 {push16(c, c.y); c.cycles += 2}
		if pb & 0x10 != 0 {push16(c, c.x); c.cycles += 2}
		if pb & 0x08 != 0 {push8(c, c.dp, is_s); c.cycles += 1}
		if pb & 0x04 != 0 {push8(c, c.b, is_s); c.cycles += 1}
		if pb & 0x02 != 0 {push8(c, c.a, is_s); c.cycles += 1}
		if pb & 0x01 != 0 {push8(c, get_cc(c), is_s); c.cycles += 1}
		c.cycles += 5

	case 0x35, 0x37: // PULS / PULU
		pb := fetch8(c)
		is_s := op == 0x35
		sp := &c.s if is_s else &c.u
		pull8 :: proc(c: ^CPU6809, sp: ^u16) -> u8 {
			v := read8(c, sp^)
			sp^ += 1
			return v
		}
		pull16 :: proc(c: ^CPU6809, sp: ^u16) -> u16 {
			hi := pull8(c, sp)
			lo := pull8(c, sp)
			return u16(hi) << 8 | u16(lo)
		}
		if pb & 0x01 != 0 {set_cc(c, pull8(c, sp)); c.cycles += 1}
		if pb & 0x02 != 0 {c.a = pull8(c, sp); c.cycles += 1}
		if pb & 0x04 != 0 {c.b = pull8(c, sp); c.cycles += 1}
		if pb & 0x08 != 0 {c.dp = pull8(c, sp); c.cycles += 1}
		if pb & 0x10 != 0 {c.x = pull16(c, sp); c.cycles += 2}
		if pb & 0x20 != 0 {c.y = pull16(c, sp); c.cycles += 2}
		if pb & 0x40 != 0 {
			v := pull16(c, sp)
			if is_s {c.u = v} else {c.s = v}
			c.cycles += 2
		}
		if pb & 0x80 != 0 {c.pc = pull16(c, sp); c.cycles += 2}
		c.cycles += 5

	case 0x39: // RTS
		c.pc = pull_s16(c)
		c.cycles += 5
	case 0x3A: // ABX
		c.x += u16(c.b)
		c.cycles += 3
	case 0x3B: // RTI
		set_cc(c, pull_s8(c))
		c.cycles += 6
		if flag(c, .E) {
			c.a = pull_s8(c)
			c.b = pull_s8(c)
			c.dp = pull_s8(c)
			c.x = pull_s16(c)
			c.y = pull_s16(c)
			c.u = pull_s16(c)
			c.cycles += 9
		}
		c.pc = pull_s16(c)
	case 0x3C: // CWAI (simplified as in VCC: state is stacked when the interrupt hits)
		mask := fetch8(c)
		set_cc(c, get_cc(c) & mask)
		c.cycles = cycle_for
		c.sync_waiting = true
	case 0x3D: // MUL
		d := u16(c.a) * u16(c.b)
		set_d(c, d)
		set_flag(c, .C, c.b & 0x80 != 0)
		set_flag(c, .Z, d == 0)
		c.cycles += 11
	case 0x3E: // RESET (undocumented)
		cpu_reset(c)
	case 0x3F: // SWI
		push_entire(c)
		c.pc = read16(c, VEC_SWI)
		c.cc += {.I, .F}
		c.cycles += 19
	case:
		c.cycles += 1 // illegal
	}
}
