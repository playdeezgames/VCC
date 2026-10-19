package asm6809

// A two-pass (iterated) MC6809 assembler in the lwasm style.
//
// Source lines look like:  [label[:]]  mnemonic  operand  [; comment]
// A label must start in column 0; everything else is indented. The operand
// ends at the first blank (outside quotes), so write "lda #1,x" without spaces.
// A line starting with '*' or ';' is a comment.
//
// Passes run until no symbol changes value. Operand sizes (direct vs extended,
// 5/8/16 bit index offsets) depend only on whether a symbol is defined earlier
// in the source (known) or later (forward, always the long form), so they are
// the same in every pass and the symbol values converge.

import "base:runtime"
import "core:fmt"
import "core:os"
import "core:slice"
import "core:strings"

MAX_PASSES :: 10
MAX_INCLUDE_DEPTH :: 16
MAX_ERRORS :: 100

Error :: struct {
	file: string,
	line: int,
	msg:  string,
}

Symbol :: struct {
	name:      string,
	value:     int,
	def_index: int, // statement counter at the definition
	defined:   bool,
	is_set:    bool, // defined with SET, may be redefined
	is_label:  bool, // a location, as opposed to an EQU/SET constant
	stamp:     int, // pass of the latest definition
}

Options :: struct {
	// Returns the text of an include file. Default: read from disk.
	read_file:    proc(path: string) -> (text: string, ok: bool),
	include_dirs: []string,
}

Result :: struct {
	mem:      []u8, // 64K address space; only `written` bytes are meaningful
	written:  []bool,
	lo, hi:   int, // lowest / highest address written (lo > hi when nothing was)
	errors:   [dynamic]Error,
	symbols:  [dynamic]Symbol, // sorted by name
	listing:  string,
	passes:   int,
}

destroy :: proc(r: ^Result) {
	delete(r.mem)
	delete(r.written)
	for e in r.errors {
		delete(e.file)
		delete(e.msg)
	}
	delete(r.errors)
	for s in r.symbols {delete(s.name)}
	delete(r.symbols)
	delete(r.listing)
}

// The bytes at [base, base+size), unwritten bytes set to `fill`.
image :: proc(r: ^Result, base, size: int, fill: u8) -> []u8 {
	out := make([]u8, size)
	for i in 0 ..< size {
		a := base + i
		out[i] = r.mem[a] if a < 65536 && r.written[a] else fill
	}
	return out
}

symbol_value :: proc(r: ^Result, name: string) -> (int, bool) {
	for s in r.symbols {
		if s.name == name {return s.value, true}
	}
	return 0, false
}

format_errors :: proc(r: ^Result, allocator := context.allocator) -> string {
	b := strings.builder_make(allocator)
	for e in r.errors {
		fmt.sbprintf(&b, "%s:%d: error: %s\n", e.file, e.line, e.msg)
	}
	return strings.to_string(b)
}

format_symbols :: proc(r: ^Result, allocator := context.allocator) -> string {
	b := strings.builder_make(allocator)
	for s in r.symbols {
		fmt.sbprintf(&b, "%-24s $%04X\n", s.name, s.value & 0xFFFF)
	}
	return strings.to_string(b)
}

// ---------------------------------------------------------------- assembler state

Cond :: struct {
	active:        bool, // this branch is being assembled
	parent_active: bool,
	taken:         bool, // some branch of this if has been taken already
}

Assembler :: struct {
	opts:       Options,
	ops:        Op_Table,
	pass:       int,
	errors:     [dynamic]Error,
	syms:       map[string]Symbol,
	mem:        []u8,
	written:    []bool,
	lo, hi:     int,
	pc:         int,
	dp:         int, // -1: unknown
	index:      int, // statement counter, restarted every pass
	last_global: string,
	conds:      [dynamic]Cond,
	ended:      bool,
	changed:    bool, // a symbol was created or changed value in this pass
	depth:      int,
	listing:    strings.Builder,
	file:       string,
	line:       int,
	// current line, for the listing
	line_addr:  int,
	line_bytes: [dynamic]u8,
	show_addr:  bool,
}

err :: proc(a: ^Assembler, format: string, args: ..any) {
	if a.pass < 2 || len(a.errors) >= MAX_ERRORS {return}
	append(&a.errors, Error{file = strings.clone(a.file), line = a.line, msg = fmt.aprintf(format, ..args)})
}

// ---------------------------------------------------------------- entry points

assemble_file :: proc(path: string, opts := Options{}) -> Result {
	o := opts
	if o.read_file == nil {o.read_file = read_file_from_disk}
	text, ok := o.read_file(path)
	if !ok {
		r := Result{}
		r.mem = make([]u8, 65536)
		r.written = make([]bool, 65536)
		r.lo, r.hi = 65536, -1
		append(&r.errors, Error{file = strings.clone(path), line = 0, msg = strings.clone("cannot read file")})
		return r
	}
	defer delete(text)
	return assemble_text(path, text, o)
}

assemble_text :: proc(name, text: string, opts := Options{}) -> Result {
	a := Assembler {
		opts = opts,
		ops  = build_ops(),
		mem  = make([]u8, 65536),
		written = make([]bool, 65536),
	}
	if a.opts.read_file == nil {a.opts.read_file = read_file_from_disk}
	defer {
		destroy_ops(&a.ops)
		delete(a.conds)
		delete(a.line_bytes)
		delete(a.syms)
	}

	passes := 0
	for pass in 1 ..= MAX_PASSES {
		passes = pass
		begin_pass(&a, pass)
		process_text(&a, name, text)
		if len(a.conds) > 0 {
			a.file, a.line = name, 0
			err(&a, "if without matching endif")
		}
		if pass >= 2 && !a.changed {break}
	}
	if a.changed && len(a.errors) == 0 {
		a.file, a.line = name, 0
		append(&a.errors, Error{file = strings.clone(name), msg = strings.clone("symbol values do not settle")})
	}

	r := Result {
		mem     = a.mem,
		written = a.written,
		lo      = a.lo,
		hi      = a.hi,
		errors  = a.errors,
		listing = strings.to_string(a.listing),
		passes  = passes,
	}
	for _, s in a.syms {
		s2 := s
		s2.name = strings.clone(s.name)
		append(&r.symbols, s2)
	}
	for _, s in a.syms {delete(s.name)}
	slice.sort_by(r.symbols[:], proc(x, y: Symbol) -> bool {return x.name < y.name})
	return r
}

@(private)
read_file_from_disk :: proc(path: string) -> (string, bool) {
	data, e := os.read_entire_file(path, context.allocator)
	if e != nil {return "", false}
	return string(data), true
}

@(private)
begin_pass :: proc(a: ^Assembler, pass: int) {
	a.pass = pass
	if pass >= 2 {
		for e in a.errors {
			delete(e.file)
			delete(e.msg)
		}
		clear(&a.errors)
	}
	for i in 0 ..< 65536 {a.written[i] = false}
	a.lo, a.hi = 65536, -1
	a.pc = 0
	a.dp = -1
	a.index = 0
	a.last_global = ""
	clear(&a.conds)
	a.ended = false
	a.changed = false
	a.depth = 0
	strings.builder_destroy(&a.listing)
	a.listing = strings.builder_make()
}

@(private)
process_text :: proc(a: ^Assembler, name, text: string) {
	saved_file, saved_line := a.file, a.line
	defer {a.file, a.line = saved_file, saved_line}
	a.file = name
	rest := text
	n := 0
	for line in strings.split_lines_iterator(&rest) {
		if a.ended {break}
		n += 1
		a.line = n
		process_line(a, line)
	}
}

// ---------------------------------------------------------------- lines

@(private)
is_space :: proc(c: u8) -> bool {return c == ' ' || c == '\t'}

@(private)
cond_active :: proc(a: ^Assembler) -> bool {
	return len(a.conds) == 0 || a.conds[len(a.conds) - 1].active
}

@(private)
process_line :: proc(a: ^Assembler, text: string) {
	runtime.DEFAULT_TEMP_ALLOCATOR_TEMP_GUARD() // scratch strings of this line only
	a.index += 1
	a.line_addr = a.pc
	clear(&a.line_bytes)
	a.show_addr = false
	defer list_line(a, text)

	line := strings.trim_right(text, "\r\n")
	if len(line) == 0 {return}
	if line[0] == '*' || line[0] == ';' {return}

	rest := line
	label := ""
	if !is_space(line[0]) {
		i := 0
		for i < len(rest) && !is_space(rest[i]) && rest[i] != ':' && rest[i] != ';' {i += 1}
		label = rest[:i]
		rest = rest[i:]
		if len(rest) > 0 && rest[0] == ':' {rest = rest[1:]}
	}
	rest = strings.trim_left(rest, " \t")

	if len(rest) == 0 || rest[0] == ';' {
		if label != "" && cond_active(a) {define_label(a, label)}
		return
	}

	j := 0
	for j < len(rest) && !is_space(rest[j]) && rest[j] != ';' {j += 1}
	mnem := strings.to_lower(rest[:j], context.temp_allocator)
	rest = strings.trim_left(rest[j:], " \t")
	operand, _ := split_operand(rest)

	// Conditional assembly is handled even inside a skipped region.
	switch mnem {
	case "if", "ifne", "ifdef", "ifndef":
		parent := cond_active(a)
		cond := false
		if parent {
			switch mnem {
			case "ifdef", "ifndef":
				sym, found := a.syms[symbol_key(a, operand)]
				defined := found && sym.defined && sym.def_index < a.index
				cond = defined if mnem == "ifdef" else !defined
			case:
				v, fwd, ok := eval_expr(a, operand)
				if fwd {err(a, "forward reference in 'if'")}
				cond = ok && v != 0
			}
		}
		append(&a.conds, Cond{active = parent && cond, parent_active = parent, taken = cond})
		return
	case "else":
		if len(a.conds) == 0 {
			err(a, "else without if")
			return
		}
		c := &a.conds[len(a.conds) - 1]
		c.active = c.parent_active && !c.taken
		c.taken = true
		return
	case "endif":
		if len(a.conds) == 0 {
			err(a, "endif without if")
			return
		}
		pop(&a.conds)
		return
	}
	if !cond_active(a) {return}

	switch mnem {
	case "equ", "set":
		if label == "" {
			err(a, "'%s' needs a label", mnem)
			return
		}
		v, _, _ := eval_expr(a, operand)
		define_symbol(a, label, v, false, mnem == "set")
		return
	}

	if label != "" {define_label(a, label)}
	directive(a, mnem, operand, rest)
}

// Splits "operand  comment": the operand ends at the first blank or ';' outside
// quotes.
@(private)
split_operand :: proc(s: string) -> (operand, tail: string) {
	i := 0
	for i < len(s) {
		c := s[i]
		if is_space(c) || c == ';' {break}
		i = skip_quoted(s, i)
	}
	return s[:i], s[i:]
}

// Index after the character at s[i], stepping over a quoted string or a
// character literal that starts there.
@(private)
skip_quoted :: proc(s: string, i: int) -> int {
	switch s[i] {
	case '"':
		j := i + 1
		for j < len(s) && s[j] != '"' {j += 1}
		return min(j + 1, len(s))
	case '\'':
		j := i + 2 // quote and the character
		if j < len(s) && s[j] == '\'' {j += 1}
		return min(j, len(s))
	}
	return i + 1
}

// Splits at commas outside parentheses, brackets and quotes.
@(private)
split_commas :: proc(s: string) -> []string {
	parts := make([dynamic]string, context.temp_allocator)
	depth, start, i := 0, 0, 0
	for i < len(s) {
		switch s[i] {
		case '(', '[': depth += 1
		case ')', ']': depth -= 1
		case ',':
			if depth == 0 {
				append(&parts, s[start:i])
				start = i + 1
			}
		}
		i = skip_quoted(s, i)
	}
	append(&parts, s[start:])
	return parts[:]
}

@(private)
find_top_comma :: proc(s: string) -> int {
	depth, i := 0, 0
	for i < len(s) {
		switch s[i] {
		case '(', '[': depth += 1
		case ')', ']': depth -= 1
		case ',':
			if depth == 0 {return i}
		}
		i = skip_quoted(s, i)
	}
	return -1
}

// ---------------------------------------------------------------- symbols

@(private)
valid_label :: proc(s: string) -> bool {
	if len(s) == 0 || !is_ident_start(s[0]) {return false}
	for c in transmute([]u8)s {
		if !is_ident_char(c) {return false}
	}
	return true
}

@(private)
define_label :: proc(a: ^Assembler, name: string) {
	define_symbol(a, name, a.pc, true, false)
	a.show_addr = true
}

@(private)
define_symbol :: proc(a: ^Assembler, name: string, value: int, is_label, is_set: bool) {
	if !valid_label(name) {
		err(a, "invalid label '%s'", name)
		return
	}
	key := symbol_key(a, name)
	existing, found := a.syms[key]
	if found {
		if existing.stamp == a.pass && !(is_set && existing.is_set) {
			err(a, "duplicate symbol '%s'", name)
			return
		}
		if existing.value != value || !existing.defined {a.changed = true}
		existing.value = value
		existing.defined = true
		existing.def_index = a.index
		existing.is_set = is_set
		existing.is_label = is_label
		existing.stamp = a.pass
		a.syms[existing.name] = existing
		if is_label && name[0] != '.' {a.last_global = existing.name}
		return
	}
	owned := strings.clone(key)
	a.syms[owned] = Symbol {
		name      = owned,
		value     = value,
		def_index = a.index,
		defined   = true,
		is_set    = is_set,
		is_label  = is_label,
		stamp     = a.pass,
	}
	a.changed = true
	if is_label && name[0] != '.' {a.last_global = owned}
}

// ---------------------------------------------------------------- output

@(private)
emit :: proc(a: ^Assembler, b: u8) {
	if a.pc < 0 || a.pc > 0xFFFF {
		err(a, "location counter outside the 64K address space")
		a.pc += 1
		return
	}
	if a.written[a.pc] {err(a, "overlapping output at $%04X", a.pc)}
	a.mem[a.pc] = b
	a.written[a.pc] = true
	a.lo = min(a.lo, a.pc)
	a.hi = max(a.hi, a.pc)
	append(&a.line_bytes, b)
	a.pc += 1
	a.show_addr = true
}

@(private)
emit16 :: proc(a: ^Assembler, v: int) {
	emit(a, u8(v >> 8))
	emit(a, u8(v))
}

@(private)
list_line :: proc(a: ^Assembler, text: string) {
	b := &a.listing
	if a.show_addr {
		fmt.sbprintf(b, "%04X  ", a.line_addr & 0xFFFF)
	} else {
		fmt.sbprintf(b, "      ")
	}
	n := min(len(a.line_bytes), 4)
	for i in 0 ..< 4 {
		if i < n {
			fmt.sbprintf(b, "%02X ", a.line_bytes[i])
		} else {
			fmt.sbprintf(b, "   ")
		}
	}
	fmt.sbprintf(b, " %s\n", strings.trim_right(text, "\r\n"))
	for start := 4; start < len(a.line_bytes); start += 4 {
		fmt.sbprintf(b, "%04X  ", (a.line_addr + start) & 0xFFFF)
		for i in start ..< min(start + 4, len(a.line_bytes)) {
			fmt.sbprintf(b, "%02X ", a.line_bytes[i])
		}
		fmt.sbprintf(b, "\n")
	}
}

// ---------------------------------------------------------------- directives and instructions

@(private)
directive :: proc(a: ^Assembler, mnem, operand, raw_rest: string) {
	switch mnem {
	case "org":
		v, fwd, ok := eval_expr(a, operand)
		if fwd {err(a, "'org' needs a value that is already defined")}
		if ok {
			if v < 0 || v > 0xFFFF {err(a, "org address $%X is outside the address space", v)} else {a.pc = v}
		}
		a.show_addr = true
		a.line_addr = a.pc
	case "fcb":
		data_list(a, operand, 1)
	case "fdb":
		data_list(a, operand, 2)
	case "fcc", "fcn":
		s := raw_rest
		if len(s) < 2 {
			err(a, "'%s' needs a delimited string", mnem)
			return
		}
		end := strings.index_byte(s[1:], s[0])
		if end < 0 {
			err(a, "unterminated string")
			return
		}
		for c in transmute([]u8)s[1:1 + end] {emit(a, c)}
		if mnem == "fcn" {emit(a, 0)}
	case "rmb", "zmb":
		v, fwd, ok := eval_expr(a, operand)
		if fwd {err(a, "'%s' needs a count that is already defined", mnem)}
		if ok && (v < 0 || v > 0x10000) {
			err(a, "bad count %d", v)
			return
		}
		a.show_addr = true
		if mnem == "rmb" {
			a.pc += v
		} else {
			for _ in 0 ..< v {emit(a, 0)}
		}
	case "align":
		parts := split_commas(operand)
		v, fwd, ok := eval_expr(a, parts[0])
		if fwd {err(a, "'align' needs a value that is already defined")}
		fill := 0
		if len(parts) > 1 {fill, _, _ = eval_expr(a, parts[1])}
		if ok && v > 0 {
			for a.pc % v != 0 {emit(a, u8(fill))}
		} else if ok {
			err(a, "bad alignment %d", v)
		}
	case "setdp":
		v, _, ok := eval_expr(a, operand)
		if ok {
			if v < -1 || v > 255 {err(a, "setdp value must be 0-255 (or -1 for none)")} else {a.dp = v}
		}
	case "include":
		include_file(a, raw_rest)
	case "end":
		a.ended = true
	case "error":
		err(a, "%s", strings.trim_space(raw_rest))
	case:
		op, found := a.ops.ops[mnem]
		if !found {
			err(a, "unknown instruction or directive '%s'", mnem)
			return
		}
		encode(a, op, operand)
	}
}

@(private)
data_list :: proc(a: ^Assembler, operand: string, size: int) {
	if len(operand) == 0 {
		err(a, "data directive needs at least one value")
		return
	}
	for item in split_commas(operand) {
		if len(item) >= 2 && item[0] == '"' {
			end := strings.index_byte(item[1:], '"')
			if end < 0 {
				err(a, "unterminated string")
				continue
			}
			for c in transmute([]u8)item[1:1 + end] {
				if size == 1 {emit(a, c)} else {emit16(a, int(c))}
			}
			continue
		}
		v, _, ok := eval_expr(a, item)
		if size == 1 {
			emit(a, u8(check_range(a, v, ok, -128, 255)))
		} else {
			emit16(a, check_range(a, v, ok, -32768, 65535))
		}
	}
}

// Reports a value outside lo..hi and returns it (or 0 after an error).
@(private)
check_range :: proc(a: ^Assembler, v: int, ok: bool, lo, hi: int) -> int {
	if !ok {return 0}
	if v < lo || v > hi {
		err(a, "value %d out of range (%d to %d)", v, lo, hi)
		return 0
	}
	return v
}

@(private)
include_file :: proc(a: ^Assembler, raw: string) {
	name := strings.trim_space(raw)
	if len(name) >= 2 && (name[0] == '"' || name[0] == '<') {
		end := strings.index_byte(name[1:], name[0] if name[0] == '"' else '>')
		if end >= 0 {name = name[1:1 + end]}
	} else {
		name, _ = split_operand(name)
	}
	if len(name) == 0 {
		err(a, "'include' needs a file name")
		return
	}
	if a.depth >= MAX_INCLUDE_DEPTH {
		err(a, "includes nested too deeply")
		return
	}

	candidates := make([dynamic]string, context.temp_allocator)
	if slash := strings.last_index_byte(a.file, '/'); slash >= 0 {
		append(&candidates, fmt.tprintf("%s/%s", a.file[:slash], name))
	}
	append(&candidates, name)
	for d in a.opts.include_dirs {
		append(&candidates, fmt.tprintf("%s/%s", d, name))
	}
	for path in candidates {
		text, ok := a.opts.read_file(path)
		if !ok {continue}
		defer delete(text)
		a.depth += 1
		process_text(a, strings.clone(path, context.temp_allocator), text)
		a.depth -= 1
		return
	}
	err(a, "cannot find include file '%s'", name)
}

// ---------------------------------------------------------------- instruction encoding

@(private)
Code :: struct {
	b: [8]u8,
	n: int,
}

@(private)
put :: proc(c: ^Code, v: int) {
	c.b[c.n] = u8(v)
	c.n += 1
}

@(private)
put_opcode :: proc(c: ^Code, op: i32) {
	if op > 0xFF {put(c, int(op >> 8))}
	put(c, int(op & 0xFF))
}

@(private)
flush :: proc(a: ^Assembler, c: ^Code) {
	for i in 0 ..< c.n {emit(a, c.b[i])}
}

@(private)
encode :: proc(a: ^Assembler, op: Op, operand: string) {
	c: Code
	switch op.kind {
	case .Inherent:
		put_opcode(&c, op.code)
	case .Imm8:
		if len(operand) == 0 {
			err(a, "'%s' needs an operand", op.name)
			return
		}
		s := operand[1:] if operand[0] == '#' else operand
		v, _, ok := eval_expr(a, s)
		put_opcode(&c, op.code)
		put(&c, check_range(a, v, ok, -128, 255))
	case .Reg2:
		parts := split_commas(operand)
		if len(parts) != 2 {
			err(a, "'%s' needs two registers", op.name)
			return
		}
		r1, ok1 := reg_code(parts[0])
		r2, ok2 := reg_code(parts[1])
		if !ok1 || !ok2 {
			err(a, "bad register in '%s %s'", op.name, operand)
			return
		}
		if (r1 < 8) != (r2 < 8) {err(a, "'%s' cannot mix 8 and 16 bit registers", op.name)}
		put_opcode(&c, op.code)
		put(&c, r1 << 4 | r2)
	case .Stack_S, .Stack_U:
		mask, ok := stack_mask(a, op, operand)
		if !ok {return}
		put_opcode(&c, op.code)
		put(&c, mask)
	case .Rel8:
		put_opcode(&c, op.code)
		v, _, ok := eval_expr(a, operand)
		off := v - (a.pc + c.n + 1)
		if ok && (off < -128 || off > 127) {
			err(a, "branch target out of range (%d bytes)", off)
			off = 0
		}
		put(&c, off)
	case .Rel16:
		put_opcode(&c, op.code)
		v, _, _ := eval_expr(a, operand)
		off := v - (a.pc + c.n + 2)
		put(&c, off >> 8)
		put(&c, off)
	case .Mem:
		encode_mem(a, op, operand, &c)
	}
	flush(a, &c)
}

@(private)
reg_code :: proc(s: string) -> (int, bool) {
	switch strings.to_upper(strings.trim_space(s), context.temp_allocator) {
	case "D": return 0, true
	case "X": return 1, true
	case "Y": return 2, true
	case "U": return 3, true
	case "S": return 4, true
	case "PC": return 5, true
	case "A": return 8, true
	case "B": return 9, true
	case "CC": return 10, true
	case "DP": return 11, true
	}
	return 0, false
}

@(private)
stack_mask :: proc(a: ^Assembler, op: Op, operand: string) -> (int, bool) {
	if len(operand) == 0 {
		err(a, "'%s' needs a register list", op.name)
		return 0, false
	}
	mask := 0
	for item in split_commas(operand) {
		name := strings.to_upper(strings.trim_space(item), context.temp_allocator)
		bit := 0
		switch name {
		case "CC": bit = 0x01
		case "A": bit = 0x02
		case "B": bit = 0x04
		case "D": bit = 0x06
		case "DP": bit = 0x08
		case "X": bit = 0x10
		case "Y": bit = 0x20
		case "PC": bit = 0x80
		case "U":
			if op.kind == .Stack_U {
				err(a, "'%s' cannot push its own stack pointer", op.name)
				return 0, false
			}
			bit = 0x40
		case "S":
			if op.kind == .Stack_S {
				err(a, "'%s' cannot push its own stack pointer", op.name)
				return 0, false
			}
			bit = 0x40
		case:
			err(a, "bad register '%s' in '%s'", item, op.name)
			return 0, false
		}
		mask |= bit
	}
	return mask, true
}

@(private)
encode_mem :: proc(a: ^Assembler, op: Op, operand: string, c: ^Code) {
	if len(operand) == 0 {
		err(a, "'%s' needs an operand", op.name)
		return
	}
	switch {
	case operand[0] == '#':
		if op.imm < 0 {
			err(a, "'%s' has no immediate mode", op.name)
			return
		}
		v, _, ok := eval_expr(a, operand[1:])
		put_opcode(c, op.imm)
		if op.imm_size == 1 {
			put(c, check_range(a, v, ok, -128, 255))
		} else {
			w := check_range(a, v, ok, -32768, 65535)
			put(c, w >> 8)
			put(c, w)
		}
	case operand[0] == '[':
		if operand[len(operand) - 1] != ']' {
			err(a, "missing ']'")
			return
		}
		if op.idx < 0 {
			err(a, "'%s' has no indexed mode", op.name)
			return
		}
		inner := operand[1:len(operand) - 1]
		put_opcode(c, op.idx)
		if find_top_comma(inner) >= 0 {
			encode_indexed(a, c, inner, true)
		} else {
			v, _, ok := eval_expr(a, inner)
			w := check_range(a, v, ok, 0, 65535)
			put(c, 0x9F)
			put(c, w >> 8)
			put(c, w)
		}
	case find_top_comma(operand) >= 0:
		if op.idx < 0 {
			err(a, "'%s' has no indexed mode", op.name)
			return
		}
		put_opcode(c, op.idx)
		encode_indexed(a, c, operand, false)
	case:
		if op.dir < 0 && op.ext < 0 {
			err(a, "'%s' needs an indexed operand", op.name)
			return
		}
		s := operand
		force: u8 = 0
		if s[0] == '<' || s[0] == '>' {
			force = s[0]
			s = s[1:]
		}
		v, fwd, ok := eval_expr(a, s)
		direct: bool
		switch force {
		case '<': direct = true
		case '>': direct = false
		case: direct = op.dir >= 0 && a.dp >= 0 && ok && !fwd && v >= 0 && v <= 0xFFFF && (v >> 8) == a.dp
		}
		if direct {
			if op.dir < 0 {
				err(a, "'%s' has no direct mode", op.name)
				return
			}
			if a.dp >= 0 && ok && !fwd && (v < 0 || v > 0xFFFF || (v >> 8) != a.dp) {
				err(a, "address $%X is not in the direct page $%02X", v, a.dp)
			}
			put_opcode(c, op.dir)
			put(c, v)
		} else {
			if op.ext < 0 {
				err(a, "'%s' has no extended mode", op.name)
				return
			}
			put_opcode(c, op.ext)
			w := check_range(a, v, ok, -32768, 65535)
			put(c, w >> 8)
			put(c, w)
		}
	}
}

// Indexed operand "offset,reg" (the opcode is already in c). With `indirect`
// the postbyte gets the indirect bit.
@(private)
encode_indexed :: proc(a: ^Assembler, c: ^Code, s: string, indirect: bool) {
	ci := find_top_comma(s)
	left := strings.trim_space(s[:ci])
	right := strings.to_upper(strings.trim_space(s[ci + 1:]), context.temp_allocator)
	ind: int = 0x10 if indirect else 0

	// Auto increment / decrement: ,R+ ,R++ ,-R ,--R
	r := right
	pre, post := 0, 0
	for len(r) > 0 && r[0] == '-' {
		pre += 1
		r = r[1:]
	}
	for len(r) > 0 && r[len(r) - 1] == '+' {
		post += 1
		r = r[:len(r) - 1]
	}

	if r == "PC" || r == "PCR" {
		if pre + post > 0 {
			err(a, "bad indexed operand '%s'", s)
			return
		}
		encode_pc_relative(a, c, left, r == "PCR", ind)
		return
	}
	rr := 0
	switch r {
	case "X": rr = 0
	case "Y": rr = 1
	case "U": rr = 2
	case "S": rr = 3
	case:
		err(a, "bad index register '%s'", right)
		return
	}
	reg := rr << 5

	if pre + post > 0 {
		if left != "" {
			err(a, "auto increment/decrement takes no offset")
			return
		}
		switch {
		case post == 1 && pre == 0:
			if indirect {err(a, "',R+' cannot be indirect")}
			put(c, 0x80 | reg)
		case post == 2 && pre == 0: put(c, 0x81 | reg | ind)
		case pre == 1 && post == 0:
			if indirect {err(a, "',-R' cannot be indirect")}
			put(c, 0x82 | reg)
		case pre == 2 && post == 0: put(c, 0x83 | reg | ind)
		case: err(a, "bad indexed operand '%s'", s)
		}
		return
	}

	switch strings.to_upper(left, context.temp_allocator) {
	case "":
		put(c, 0x84 | reg | ind)
		return
	case "A":
		put(c, 0x86 | reg | ind)
		return
	case "B":
		put(c, 0x85 | reg | ind)
		return
	case "D":
		put(c, 0x8B | reg | ind)
		return
	}

	// Constant offset: 5 bit (not indirect), 8 bit or 16 bit.
	force: u8 = 0
	expr := left
	if expr[0] == '<' || expr[0] == '>' {
		force = expr[0]
		expr = expr[1:]
	}
	v, fwd, ok := eval_expr(a, expr)
	size := 16
	switch {
	case force == '<': size = 8
	case force == '>': size = 16
	case fwd || !ok: size = 16
	case v == 0: size = 0
	case !indirect && v >= -16 && v <= 15: size = 5
	case v >= -128 && v <= 127: size = 8
	}
	switch size {
	case 0: put(c, 0x84 | reg | ind)
	case 5: put(c, reg | (v & 0x1F))
	case 8:
		put(c, 0x88 | reg | ind)
		put(c, check_range(a, v, ok, -128, 255))
	case:
		put(c, 0x89 | reg | ind)
		w := check_range(a, v, ok, -32768, 65535)
		put(c, w >> 8)
		put(c, w)
	}
}

// "expr,PCR" (expr is the target address) or "expr,PC" (expr is the offset).
@(private)
encode_pc_relative :: proc(a: ^Assembler, c: ^Code, left: string, relative: bool, ind: int) {
	force: u8 = 0
	expr := left
	if len(expr) > 0 && (expr[0] == '<' || expr[0] == '>') {
		force = expr[0]
		expr = expr[1:]
	}
	if expr == "" {expr = "0"}
	v, fwd, ok := eval_expr(a, expr)
	// Offsets are measured from the end of the instruction.
	end8 := a.pc + c.n + 2
	end16 := a.pc + c.n + 3
	off8 := v - end8 if relative else v
	off16 := v - end16 if relative else v
	use8: bool
	switch {
	case force == '<': use8 = true
	case force == '>': use8 = false
	case fwd || !ok: use8 = false
	case: use8 = off8 >= -128 && off8 <= 127
	}
	if use8 {
		put(c, 0x8C | ind)
		put(c, check_range(a, off8, ok, -128, 255))
	} else {
		put(c, 0x8D | ind)
		w := check_range(a, off16, ok, -32768, 65535)
		put(c, w >> 8)
		put(c, w)
	}
}
