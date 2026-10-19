package asm6809

// MC6809 instruction table. Opcodes above $FF carry their page prefix in the
// high byte ($10xx = page 2, $11xx = page 3). -1 marks a mode the instruction
// does not have.

Kind :: enum {
	Inherent,
	Imm8, // andcc, orcc, cwai: one immediate byte
	Reg2, // tfr, exg: register pair
	Stack_S, // pshs, puls: register list (U is the other stack)
	Stack_U, // pshu, pulu: register list (S is the other stack)
	Rel8, // short branch
	Rel16, // long branch
	Mem, // general memory operand (immediate / direct / indexed / extended)
}

Op :: struct {
	name:               string,
	kind:               Kind,
	code:               i32, // opcode of every kind but Mem
	imm, dir, idx, ext: i32, // Mem: opcode per addressing mode
	imm_size:           int, // Mem: bytes of immediate operand (0: no immediate mode)
}

Op_Table :: struct {
	ops:   map[string]Op,
	owned: [dynamic]string, // generated names (nega, lbne, ...), freed with the table
}

destroy_ops :: proc(t: ^Op_Table) {
	for s in t.owned {delete(s)}
	delete(t.owned)
	delete(t.ops)
}

build_ops :: proc() -> (t: Op_Table) {
	t.ops = make(map[string]Op)
	m := &t.ops

	// Inherent instructions.
	inh(m, "nop", 0x12);  inh(m, "sync", 0x13); inh(m, "daa", 0x19);  inh(m, "sex", 0x1D)
	inh(m, "rts", 0x39);  inh(m, "abx", 0x3A);  inh(m, "rti", 0x3B);  inh(m, "mul", 0x3D)
	inh(m, "swi", 0x3F);  inh(m, "swi2", 0x103F); inh(m, "swi3", 0x113F)

	// Accumulator forms of the unary operations.
	acc_ops := [?]struct {
		n: string,
		c: i32,
	}{{"neg", 0x40}, {"com", 0x43}, {"lsr", 0x44}, {"ror", 0x46}, {"asr", 0x47}, {"asl", 0x48},
		{"lsl", 0x48}, {"rol", 0x49}, {"dec", 0x4A}, {"inc", 0x4C}, {"tst", 0x4D}, {"clr", 0x4F}}
	for o in acc_ops {
		inh(m, strcat(&t, o.n, "a"), o.c)
		inh(m, strcat(&t, o.n, "b"), o.c + 0x10)
	}

	// Unary operations on memory (direct = base, indexed = +$60, extended = +$70).
	mem_ops := [?]struct {
		n: string,
		c: i32,
	}{{"neg", 0x00}, {"com", 0x03}, {"lsr", 0x04}, {"ror", 0x06}, {"asr", 0x07}, {"asl", 0x08},
		{"lsl", 0x08}, {"rol", 0x09}, {"dec", 0x0A}, {"inc", 0x0C}, {"tst", 0x0D}, {"jmp", 0x0E},
		{"clr", 0x0F}}
	for o in mem_ops {
		m[o.n] = Op{name = o.n, kind = .Mem, imm = -1, dir = o.c, idx = o.c + 0x60, ext = o.c + 0x70}
	}

	// 8-bit accumulator arithmetic and loads (A = base, B = base + $40).
	alu8 := [?]struct {
		n: string,
		c: i32,
		i: int,
	}{{"sub", 0x80, 1}, {"cmp", 0x81, 1}, {"sbc", 0x82, 1}, {"and", 0x84, 1}, {"bit", 0x85, 1},
		{"ld", 0x86, 1}, {"st", 0x87, 0}, {"eor", 0x88, 1}, {"adc", 0x89, 1}, {"or", 0x8A, 1},
		{"add", 0x8B, 1}}
	for o in alu8 {
		mem4(m, strcat(&t, o.n, "a"), o.c, o.i, 0)
		mem4(m, strcat(&t, o.n, "b"), o.c + 0x40, o.i, 0)
	}

	// 16-bit operations.
	mem4(m, "subd", 0x83, 2, 0);  mem4(m, "addd", 0xC3, 2, 0)
	mem4(m, "ldd", 0xCC, 2, 0);   mem4(m, "std", 0xCD, 0, 0)
	mem4(m, "cmpx", 0x8C, 2, 0);  mem4(m, "ldx", 0x8E, 2, 0);  mem4(m, "stx", 0x8F, 0, 0)
	mem4(m, "ldu", 0xCE, 2, 0);   mem4(m, "stu", 0xCF, 0, 0)
	mem4(m, "cmpd", 0x83, 2, 0x1000); mem4(m, "cmpy", 0x8C, 2, 0x1000)
	mem4(m, "ldy", 0x8E, 2, 0x1000);  mem4(m, "sty", 0x8F, 0, 0x1000)
	mem4(m, "lds", 0xCE, 2, 0x1000);  mem4(m, "sts", 0xCF, 0, 0x1000)
	mem4(m, "cmpu", 0x83, 2, 0x1100); mem4(m, "cmps", 0x8C, 2, 0x1100)
	mem4(m, "jsr", 0x8D, 0, 0)

	// Effective address loads take an indexed operand only.
	for n, i in ([?]string{"leax", "leay", "leas", "leau"}) {
		m[n] = Op{name = n, kind = .Mem, imm = -1, dir = -1, idx = i32(0x30 + i), ext = -1}
	}

	// Condition code and register operations.
	m["andcc"] = Op{name = "andcc", kind = .Imm8, code = 0x1C}
	m["orcc"] = Op{name = "orcc", kind = .Imm8, code = 0x1A}
	m["cwai"] = Op{name = "cwai", kind = .Imm8, code = 0x3C}
	m["exg"] = Op{name = "exg", kind = .Reg2, code = 0x1E}
	m["tfr"] = Op{name = "tfr", kind = .Reg2, code = 0x1F}
	m["pshs"] = Op{name = "pshs", kind = .Stack_S, code = 0x34}
	m["puls"] = Op{name = "puls", kind = .Stack_S, code = 0x35}
	m["pshu"] = Op{name = "pshu", kind = .Stack_U, code = 0x36}
	m["pulu"] = Op{name = "pulu", kind = .Stack_U, code = 0x37}

	// Branches. Long forms carry the $10 prefix; lbra/lbsr have their own opcodes.
	branches := [?]struct {
		n: string,
		c: i32,
	}{{"bra", 0x20}, {"brn", 0x21}, {"bhi", 0x22}, {"bls", 0x23}, {"bcc", 0x24}, {"bhs", 0x24},
		{"bcs", 0x25}, {"blo", 0x25}, {"bne", 0x26}, {"beq", 0x27}, {"bvc", 0x28}, {"bvs", 0x29},
		{"bpl", 0x2A}, {"bmi", 0x2B}, {"bge", 0x2C}, {"blt", 0x2D}, {"bgt", 0x2E}, {"ble", 0x2F}}
	for o in branches {
		m[o.n] = Op{name = o.n, kind = .Rel8, code = o.c}
		ln := strcat(&t, "l", o.n)
		m[ln] = Op{name = ln, kind = .Rel16, code = 0x1000 | o.c}
	}
	m["bsr"] = Op{name = "bsr", kind = .Rel8, code = 0x8D}
	m["lbra"] = Op{name = "lbra", kind = .Rel16, code = 0x16}
	m["lbsr"] = Op{name = "lbsr", kind = .Rel16, code = 0x17}

	return
}

@(private)
strcat :: proc(t: ^Op_Table, a, b: string) -> string {
	buf := make([]u8, len(a) + len(b))
	copy(buf, a)
	copy(buf[len(a):], b)
	s := string(buf)
	append(&t.owned, s)
	return s
}

@(private)
inh :: proc(m: ^map[string]Op, name: string, code: i32) {
	m[name] = Op{name = name, kind = .Inherent, code = code}
}

// The usual four-mode layout: immediate = base, direct = +$10, indexed = +$20,
// extended = +$30. imm_size 0 means the instruction has no immediate form.
@(private)
mem4 :: proc(m: ^map[string]Op, name: string, base: i32, imm_size: int, prefix: i32) {
	o := Op {
		name     = name,
		kind     = .Mem,
		imm      = -1,
		dir      = prefix + base + 0x10,
		idx      = prefix + base + 0x20,
		ext      = prefix + base + 0x30,
		imm_size = imm_size,
	}
	if imm_size > 0 {o.imm = prefix + base}
	m[name] = o
}
