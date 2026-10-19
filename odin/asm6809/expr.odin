package asm6809

import "core:fmt"
import "core:strings"

// Expression evaluator. C-like precedence, low to high:
//   ||   &&   |   ^   &   == !=   < > <= >=   << >>   + -   * / %
// Unary: - + ~ ! and < (low byte) / > (high byte).
// Terms: decimal, $hex, 0xhex, %binary, 'c', symbols, * (location counter), ( ).

@(private)
LEVELS := [?][]string {
	{"||"},
	{"&&"},
	{"|"},
	{"^"},
	{"&"},
	{"==", "!="},
	{"<=", ">=", "<", ">"},
	{"<<", ">>"},
	{"+", "-"},
	{"*", "/", "%"},
}

@(private)
Eval :: struct {
	a:       ^Assembler,
	s:       string,
	i:       int,
	forward: bool, // refers to a symbol not yet defined at this point of the source
	failed:  bool,
}

// Evaluate `s`. `forward` reports a reference to something defined later in the
// source, whose value may not be final yet; ok is false after an error (which
// has been reported).
eval_expr :: proc(a: ^Assembler, s: string) -> (value: int, forward: bool, ok: bool) {
	e := Eval {
		a = a,
		s = s,
	}
	value = parse_level(&e, 0)
	skip_ws(&e)
	if !e.failed && e.i < len(e.s) {
		fail(&e, "unexpected '%s' in expression", e.s[e.i:])
	}
	if e.failed {return 0, e.forward, false}
	return value, e.forward, true
}

@(private)
fail :: proc(e: ^Eval, format: string, args: ..any) {
	if e.failed {return}
	e.failed = true
	e.i = len(e.s)
	err(e.a, format, ..args)
}

@(private)
skip_ws :: proc(e: ^Eval) {
	for e.i < len(e.s) && (e.s[e.i] == ' ' || e.s[e.i] == '\t') {e.i += 1}
}

@(private)
peek :: proc(e: ^Eval, off := 0) -> u8 {
	if e.i + off < len(e.s) {return e.s[e.i + off]}
	return 0
}

@(private)
parse_level :: proc(e: ^Eval, lvl: int) -> int {
	if lvl == len(LEVELS) {return parse_unary(e)}
	v := parse_level(e, lvl + 1)
	for !e.failed {
		skip_ws(e)
		op, found := match_binop(e, LEVELS[lvl])
		if !found {break}
		r := parse_level(e, lvl + 1)
		v = apply_binop(e, op, v, r)
	}
	return v
}

@(private)
match_binop :: proc(e: ^Eval, ops: []string) -> (string, bool) {
	rest := e.s[e.i:]
	for op in ops {
		if !strings.has_prefix(rest, op) {continue}
		next: u8 = 0
		if len(rest) > len(op) {next = rest[len(op)]}
		// Do not split a longer operator: | vs ||, & vs &&, < vs << <=, > vs >> >=.
		switch op {
		case "|":
			if next == '|' {continue}
		case "&":
			if next == '&' {continue}
		case "<":
			if next == '<' || next == '=' {continue}
		case ">":
			if next == '>' || next == '=' {continue}
		}
		e.i += len(op)
		return op, true
	}
	return "", false
}

@(private)
apply_binop :: proc(e: ^Eval, op: string, l, r: int) -> int {
	b2i :: proc(b: bool) -> int {return 1 if b else 0}
	switch op {
	case "||": return b2i(l != 0 || r != 0)
	case "&&": return b2i(l != 0 && r != 0)
	case "|": return l | r
	case "^": return l ~ r
	case "&": return l & r
	case "==": return b2i(l == r)
	case "!=": return b2i(l != r)
	case "<=": return b2i(l <= r)
	case ">=": return b2i(l >= r)
	case "<": return b2i(l < r)
	case ">": return b2i(l > r)
	case "<<": return l << uint(clamp(r, 0, 63))
	case ">>": return l >> uint(clamp(r, 0, 63))
	case "+": return l + r
	case "-": return l - r
	case "*": return l * r
	case "/", "%":
		if r == 0 {
			fail(e, "division by zero")
			return 0
		}
		if op == "/" {return l / r}
		return l % r
	}
	return 0
}

@(private)
parse_unary :: proc(e: ^Eval) -> int {
	skip_ws(e)
	if e.failed {return 0}
	if e.i >= len(e.s) {
		fail(e, "expression expected")
		return 0
	}
	switch e.s[e.i] {
	case '-':
		e.i += 1
		return -parse_unary(e)
	case '+':
		e.i += 1
		return parse_unary(e)
	case '~':
		e.i += 1
		return ~parse_unary(e)
	case '!':
		e.i += 1
		return 1 if parse_unary(e) == 0 else 0
	case '<':
		e.i += 1
		return parse_unary(e) & 0xFF
	case '>':
		e.i += 1
		return (parse_unary(e) >> 8) & 0xFF
	}
	return parse_term(e)
}

@(private)
is_digit :: proc(c: u8) -> bool {return c >= '0' && c <= '9'}
@(private)
is_alpha :: proc(c: u8) -> bool {return (c >= 'a' && c <= 'z') || (c >= 'A' && c <= 'Z')}
@(private)
hex_val :: proc(c: u8) -> int {
	switch {
	case c >= '0' && c <= '9': return int(c - '0')
	case c >= 'a' && c <= 'f': return int(c - 'a') + 10
	case c >= 'A' && c <= 'F': return int(c - 'A') + 10
	}
	return -1
}

// Identifier characters: letters, digits, '_' and '.' (a leading '.' makes a
// local label, scoped to the preceding global label).
is_ident_start :: proc(c: u8) -> bool {return is_alpha(c) || c == '_' || c == '.'}
is_ident_char :: proc(c: u8) -> bool {return is_ident_start(c) || is_digit(c)}

@(private)
parse_term :: proc(e: ^Eval) -> int {
	c := e.s[e.i]
	switch {
	case c == '(':
		e.i += 1
		v := parse_level(e, 0)
		skip_ws(e)
		if peek(e) != ')' {
			fail(e, "missing ')'")
			return 0
		}
		e.i += 1
		return v
	case c == '*':
		e.i += 1
		return e.a.pc
	case c == '$':
		e.i += 1
		return parse_radix(e, 16)
	case c == '%':
		e.i += 1
		return parse_radix(e, 2)
	case c == '\'':
		if e.i + 1 >= len(e.s) {
			fail(e, "character expected after '")
			return 0
		}
		v := int(e.s[e.i + 1])
		e.i += 2
		if peek(e) == '\'' {e.i += 1}
		return v
	case is_digit(c):
		if c == '0' && (peek(e, 1) == 'x' || peek(e, 1) == 'X') {
			e.i += 2
			return parse_radix(e, 16)
		}
		return parse_radix(e, 10)
	case is_ident_start(c):
		start := e.i
		for e.i < len(e.s) && is_ident_char(e.s[e.i]) {e.i += 1}
		return lookup_symbol(e, e.s[start:e.i])
	}
	fail(e, "unexpected '%c' in expression", rune(c))
	return 0
}

@(private)
parse_radix :: proc(e: ^Eval, radix: int) -> int {
	start := e.i
	v := 0
	for e.i < len(e.s) {
		d := hex_val(e.s[e.i])
		if d < 0 || d >= radix {break}
		v = v * radix + d
		e.i += 1
	}
	if e.i == start {
		fail(e, "number expected")
		return 0
	}
	// A letter glued to a number ("12abc", "%102") is a typo, not a symbol.
	if e.i < len(e.s) && is_ident_char(e.s[e.i]) {
		fail(e, "bad digit '%c' in number", rune(e.s[e.i]))
		return 0
	}
	return v
}

@(private)
lookup_symbol :: proc(e: ^Eval, name: string) -> int {
	a := e.a
	key := symbol_key(a, name)
	sym, found := a.syms[key]
	if !found || !sym.defined {
		e.forward = true
		if a.pass >= 2 {fail(e, "undefined symbol '%s'", name)}
		return 0
	}
	if !sym.is_set && sym.def_index > a.index {e.forward = true}
	return sym.value
}

// Local labels (".name") belong to the last global label.
symbol_key :: proc(a: ^Assembler, name: string) -> string {
	if len(name) > 0 && name[0] == '.' {
		return fmt.tprintf("%s%s", a.last_global, name)
	}
	return name
}
