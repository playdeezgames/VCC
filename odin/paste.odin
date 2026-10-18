package vcc

import SDL "vendor:sdl2"

// Typing text into the emulated keyboard (clipboard paste). Characters are
// turned into CoCo key presses on the positional layout and played back one
// at a time, a few frames down and a few up, since BASIC drops keys that
// arrive while it is busy (notably right after ENTER).

PASTE_DOWN_FRAMES :: 3
PASTE_UP_FRAMES :: 3
PASTE_ENTER_FRAMES :: 25 // extra wait after a newline

Paste_Key :: struct {
	sc:    SDL.Scancode,
	shift: bool,
}

Paste :: struct {
	queue:   [dynamic]Paste_Key,
	head:    int,
	down:    bool, // a key is currently held
	timer:   int,
	held:    Paste_Key,
}

// Map one character to the keys that produce it on a CoCo.
char_to_key :: proc(c: u8) -> (key: Paste_Key, ok: bool) {
	ok = true
	switch c {
	case 'A' ..= 'Z':
		key.sc = SDL.Scancode(int(SDL.Scancode.A) + int(c - 'A')) // unshifted = upper case
	case 'a' ..= 'z':
		key.sc = SDL.Scancode(int(SDL.Scancode.A) + int(c - 'a'))
		key.shift = true // shifted = lower case
	case '1' ..= '9':
		key.sc = SDL.Scancode(int(SDL.Scancode.NUM1) + int(c - '1'))
	case '0':
		key.sc = .NUM0
	case '!' ..= '\'':
		// ! " # $ % & ' are shift+1..7 on the CoCo
		key.sc = SDL.Scancode(int(SDL.Scancode.NUM1) + int(c - '!'))
		key.shift = true
	case '(':
		key.sc, key.shift = .NUM8, true
	case ')':
		key.sc, key.shift = .NUM9, true
	case ' ':
		key.sc = .SPACE
	case '\n':
		key.sc = .RETURN
	case ':':
		key.sc = .MINUS
	case '*':
		key.sc, key.shift = .MINUS, true
	case ';':
		key.sc = .SEMICOLON
	case '+':
		key.sc, key.shift = .SEMICOLON, true
	case ',':
		key.sc = .COMMA
	case '<':
		key.sc, key.shift = .COMMA, true
	case '-':
		key.sc = .EQUALS
	case '=':
		key.sc, key.shift = .EQUALS, true
	case '.':
		key.sc = .PERIOD
	case '>':
		key.sc, key.shift = .PERIOD, true
	case '/':
		key.sc = .SLASH
	case '?':
		key.sc, key.shift = .SLASH, true
	case '@':
		key.sc = .GRAVE
	case:
		ok = false
	}
	return
}

paste_text :: proc(m: ^Machine, text: string) {
	p := &m.paste
	paste_cancel(m)
	prev: u8
	for c in transmute([]u8)text {
		// CRLF and lone CR become one newline
		ch := c
		if c == '\r' {ch = '\n'}
		if c == '\n' && prev == '\r' {prev = c; continue}
		prev = c
		if key, ok := char_to_key(ch); ok {append(&p.queue, key)}
	}
}

paste_cancel :: proc(m: ^Machine) {
	p := &m.paste
	if p.down {
		machine_key_event(m, p.held.sc, false)
		if p.held.shift {machine_key_event(m, .LSHIFT, false)}
	}
	clear(&p.queue)
	p.head = 0
	p.down = false
	p.timer = 0
}

paste_active :: proc(m: ^Machine) -> bool {
	return m.paste.head < len(m.paste.queue) || m.paste.down
}

// Advance the paste by one frame; call once before each machine_run_frame.
paste_step :: proc(m: ^Machine) {
	p := &m.paste
	if p.timer > 0 {
		p.timer -= 1
		if p.timer > 0 {return}
	}
	if p.down {
		machine_key_event(m, p.held.sc, false)
		if p.held.shift {machine_key_event(m, .LSHIFT, false)}
		p.down = false
		p.timer = PASTE_UP_FRAMES
		if p.held.sc == .RETURN {p.timer += PASTE_ENTER_FRAMES}
		return
	}
	if p.head >= len(p.queue) {
		clear(&p.queue)
		p.head = 0
		return
	}
	k := p.queue[p.head]
	p.head += 1
	if k.shift {machine_key_event(m, .LSHIFT, true)}
	machine_key_event(m, k.sc, true)
	p.held = k
	p.down = true
	p.timer = PASTE_DOWN_FRAMES
}
