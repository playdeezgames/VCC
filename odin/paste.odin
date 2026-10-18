package vcc

import SDL "vendor:sdl2"

// Typing text into the emulated keyboard (clipboard paste). Characters are
// turned into CoCo key presses on the positional layout and played back one
// at a time, a few frames down and a few up, since BASIC drops keys that
// arrive while it is busy (notably right after ENTER).

// Timing in frames; variables so scripted runs can type faster (--paste-fast).
paste_down_frames := 3
paste_up_frames := 3
paste_enter_frames := 25 // extra wait after a newline

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

// Map one character to the PC keys (US layout) that type it; the keyboard
// layout then turns those into the CoCo key presses. Letters are typed the
// CoCo way: unshifted = upper case, shifted = lower case.
char_to_key :: proc(c: u8) -> (key: Paste_Key, ok: bool) {
	ok = true
	switch c {
	case 'A' ..= 'Z':
		key.sc = SDL.Scancode(int(SDL.Scancode.A) + int(c - 'A'))
	case 'a' ..= 'z':
		key.sc = SDL.Scancode(int(SDL.Scancode.A) + int(c - 'a'))
		key.shift = true
	case '1' ..= '9':
		key.sc = SDL.Scancode(int(SDL.Scancode.NUM1) + int(c - '1'))
	case '0':
		key.sc = .NUM0
	case '!':
		key.sc, key.shift = .NUM1, true
	case '@':
		key.sc, key.shift = .NUM2, true
	case '#':
		key.sc, key.shift = .NUM3, true
	case '$':
		key.sc, key.shift = .NUM4, true
	case '%':
		key.sc, key.shift = .NUM5, true
	case '^':
		key.sc, key.shift = .NUM6, true
	case '&':
		key.sc, key.shift = .NUM7, true
	case '*':
		key.sc, key.shift = .NUM8, true
	case '(':
		key.sc, key.shift = .NUM9, true
	case ')':
		key.sc, key.shift = .NUM0, true
	case ' ':
		key.sc = .SPACE
	case '\n':
		key.sc = .RETURN
	case '-':
		key.sc = .MINUS
	case '_':
		key.sc, key.shift = .MINUS, true
	case '=':
		key.sc = .EQUALS
	case '+':
		key.sc, key.shift = .EQUALS, true
	case '[':
		key.sc = .LEFTBRACKET
	case '{':
		key.sc, key.shift = .LEFTBRACKET, true
	case ']':
		key.sc = .RIGHTBRACKET
	case '}':
		key.sc, key.shift = .RIGHTBRACKET, true
	case '\\':
		key.sc = .BACKSLASH
	case '|':
		key.sc, key.shift = .BACKSLASH, true
	case ';':
		key.sc = .SEMICOLON
	case ':':
		key.sc, key.shift = .SEMICOLON, true
	case '\'':
		key.sc = .APOSTROPHE
	case '"':
		key.sc, key.shift = .APOSTROPHE, true
	case ',':
		key.sc = .COMMA
	case '<':
		key.sc, key.shift = .COMMA, true
	case '.':
		key.sc = .PERIOD
	case '>':
		key.sc, key.shift = .PERIOD, true
	case '/':
		key.sc = .SLASH
	case '?':
		key.sc, key.shift = .SLASH, true
	case '`':
		key.sc = .GRAVE
	case '~':
		key.sc, key.shift = .GRAVE, true
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
		p.timer = paste_up_frames
		if p.held.sc == .RETURN {p.timer += paste_enter_frames}
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
	p.timer = paste_down_frames
}

// ---------------------------------------------------------------- ROM level typing
//
// Instead of pressing keys on the emulated matrix, feed characters straight to
// BASIC's keyboard poll routine (POLCAT, $A1CB in the CoCo 3 ROM): when the
// ROM calls it and text is waiting, the routine is skipped and returns the next
// character in A. Nothing is ever dropped (BASIC asks for a character only
// when it is ready for one), so long listings go in reliably. Only works while
// BASIC (or another program using POLCAT) is reading the keyboard.

POLCAT_VECTOR :: 0xA000 // BASIC's table holds the address of the POLCAT routine

rom_paste_text :: proc(m: ^Machine, text: string) {
	clear(&m.rom_paste)
	m.rom_paste_pos = 0
	for c in transmute([]u8)text {
		ch := c
		if c == '\r' {continue}
		if c == '\n' {ch = 13}
		append(&m.rom_paste, ch)
	}
	// the POLCAT address comes from the ROM's jump table (word at $A000)
	m.cpu.hook_pc = u16(m.rom[POLCAT_VECTOR - 0x8000]) << 8 | u16(m.rom[POLCAT_VECTOR - 0x8000 + 1])
	m.cpu.hook = rom_paste_hook
	m.cpu.hook_ctx = m
}

rom_paste_active :: proc(m: ^Machine) -> bool {
	return m.rom_paste_pos < len(m.rom_paste)
}

rom_paste_hook :: proc(ctx: rawptr, c: ^CPU6809) -> bool {
	m := cast(^Machine)ctx
	if m.rom_paste_pos >= len(m.rom_paste) {return false}
	ch := m.rom_paste[m.rom_paste_pos]
	m.rom_paste_pos += 1
	c.a = ch
	c.cc -= {.Z, .N, .V}
	c.pc = pull_s16(c) // RTS: the caller did JSR to POLCAT
	c.cycles += 12
	return true
}
