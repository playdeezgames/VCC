package vcc

import SDL "vendor:sdl2"

// CoCo keyboard matrix. Rows are bit masks (1..64) read on PIA0 side A,
// columns (0-7) are strobed by PIA0 side B (active low):
//
//          col: 0     1      2      3     4     5     6     7
//   row  1:     @     A      B      C     D     E     F     G
//   row  2:     H     I      J      K     L     M     N     O
//   row  4:     P     Q      R      S     T     U     V     W
//   row  8:     X     Y      Z      UP   DWN   LFT   RGT  SPACE
//   row 16:     0     1!     2"     3#    4$    5%    6&    7'
//   row 32:    8(     9)     :*     ;+    ,<    -=    .>    /?
//   row 64:    ENT   CLR  BRK/ESC  ALT    CTL   F1    F2  SHIFT
//
// The layout is VCC's "Natural" one: PC keys produce the character printed on
// them (Shift+2 is @, = is =, * is Shift+8 ...) by pressing whatever CoCo
// keys make that character, rather than mapping keys by position.

Matrix_Key :: struct {
	row: u8, // row bit mask; 0 = unused
	col: u8,
}

Key_Entry :: struct {
	sc: SDL.Scancode,
	a:  Matrix_Key,
	b:  Matrix_Key, // second key pressed together with `a` (shift, ctrl, ...)
}

SHIFT :: Matrix_Key{64, 7}
CTRL :: Matrix_Key{64, 4}

// Entries used when no Shift is held (modifiers and non-character keys included).
layout_plain := [?]Key_Entry {
	{.A, {1, 1}, {}}, {.B, {1, 2}, {}}, {.C, {1, 3}, {}}, {.D, {1, 4}, {}}, {.E, {1, 5}, {}},
	{.F, {1, 6}, {}}, {.G, {1, 7}, {}}, {.H, {2, 0}, {}}, {.I, {2, 1}, {}}, {.J, {2, 2}, {}},
	{.K, {2, 3}, {}}, {.L, {2, 4}, {}}, {.M, {2, 5}, {}}, {.N, {2, 6}, {}}, {.O, {2, 7}, {}},
	{.P, {4, 0}, {}}, {.Q, {4, 1}, {}}, {.R, {4, 2}, {}}, {.S, {4, 3}, {}}, {.T, {4, 4}, {}},
	{.U, {4, 5}, {}}, {.V, {4, 6}, {}}, {.W, {4, 7}, {}}, {.X, {8, 0}, {}}, {.Y, {8, 1}, {}},
	{.Z, {8, 2}, {}},
	{.NUM0, {16, 0}, {}}, {.NUM1, {16, 1}, {}}, {.NUM2, {16, 2}, {}}, {.NUM3, {16, 3}, {}},
	{.NUM4, {16, 4}, {}}, {.NUM5, {16, 5}, {}}, {.NUM6, {16, 6}, {}}, {.NUM7, {16, 7}, {}},
	{.NUM8, {32, 0}, {}}, {.NUM9, {32, 1}, {}},
	{.SEMICOLON, {32, 3}, {}}, // ;
	{.APOSTROPHE, {16, 7}, SHIFT}, // '
	{.COMMA, {32, 4}, {}}, {.PERIOD, {32, 6}, {}}, {.SLASH, {32, 7}, {}},
	{.MINUS, {32, 5}, {}}, // -
	{.EQUALS, {32, 5}, SHIFT}, // =
	{.SPACE, {8, 7}, {}},
	{.RETURN, {64, 0}, {}}, {.KP_ENTER, {64, 0}, {}},
	// arrows (and the numpad copies)
	{.UP, {8, 3}, {}}, {.DOWN, {8, 4}, {}}, {.LEFT, {8, 5}, {}}, {.RIGHT, {8, 6}, {}},
	{.KP_8, {8, 3}, {}}, {.KP_2, {8, 4}, {}}, {.KP_4, {8, 5}, {}}, {.KP_6, {8, 6}, {}},
	{.BACKSPACE, {8, 5}, {}}, // left arrow
	// CLEAR, BREAK, function keys
	{.HOME, {64, 1}, {}}, {.KP_7, {64, 1}, {}},
	{.ESCAPE, {64, 2}, {}}, {.F12, {64, 2}, {}},
	{.F1, {64, 5}, {}}, {.F2, {64, 6}, {}},
	// OS-9 editing keys: end of line, delete, insert, page up/down
	{.END, SHIFT, {8, 6}}, {.KP_1, SHIFT, {8, 6}},
	{.DELETE, CTRL, {8, 5}}, {.KP_PERIOD, CTRL, {8, 5}},
	{.INSERT, CTRL, {8, 6}}, {.KP_0, CTRL, {8, 6}},
	{.PAGEUP, SHIFT, {8, 3}}, {.KP_9, SHIFT, {8, 3}},
	{.PAGEDOWN, SHIFT, {8, 4}}, {.KP_3, SHIFT, {8, 4}},
	// brackets and backslash (CoCo CTRL combinations)
	{.LEFTBRACKET, CTRL, {32, 0}}, {.RIGHTBRACKET, CTRL, {32, 1}},
	{.BACKSLASH, {32, 7}, CTRL},
	{.CAPSLOCK, SHIFT, {16, 0}}, // CoCo SHIFT-0 toggles caps in DECB
	{.LALT, {64, 3}, {}},
	{.LCTRL, CTRL, {}}, {.RCTRL, CTRL, {}},
}

// Entries used when a Shift key is held together with the key. Using one
// of these replaces the CoCo SHIFT that the PC Shift would otherwise send, so
// they carry their own SHIFT when the CoCo character needs it.
layout_shifted := [?]Key_Entry {
	{.NUM1, {16, 1}, SHIFT}, // !
	{.NUM2, {1, 0}, {}}, // @
	{.NUM3, {16, 3}, SHIFT}, // #
	{.NUM4, {16, 4}, SHIFT}, // $
	{.NUM5, {16, 5}, SHIFT}, // %
	{.NUM6, {16, 7}, CTRL}, // ^ (CoCo CTRL-7)
	{.NUM7, {16, 6}, SHIFT}, // &
	{.NUM8, {32, 2}, SHIFT}, // *
	{.NUM9, {32, 0}, SHIFT}, // (
	{.NUM0, {32, 1}, SHIFT}, // )
	{.SEMICOLON, {32, 2}, {}}, // :
	{.APOSTROPHE, {16, 2}, SHIFT}, // "
	{.SLASH, {32, 7}, SHIFT}, // ?
	{.EQUALS, {32, 3}, SHIFT}, // +
	{.MINUS, {32, 5}, CTRL}, // _ (CoCo CTRL--)
	{.LEFTBRACKET, CTRL, {32, 4}}, // { (CoCo CTRL-,)
	{.RIGHTBRACKET, CTRL, {32, 6}}, // } (CoCo CTRL-.)
	{.BACKSLASH, {16, 1}, CTRL}, // | (CoCo CTRL-1)
	{.GRAVE, {16, 3}, CTRL}, // ~ (CoCo CTRL-3)
}

Keyboard :: struct {
	down:     [SDL.NUM_SCANCODES]bool,
	rollover: [8]u8, // per column: rows currently pressed
}

press :: proc(kb: ^Keyboard, k: Matrix_Key) {
	if k.row != 0 {kb.rollover[k.col] |= k.row}
}

shifted_entry :: proc(sc: SDL.Scancode) -> (e: Key_Entry, ok: bool) {
	for x in layout_shifted {
		if x.sc == sc {return x, true}
	}
	return {}, false
}

keyboard_update_rollover :: proc(kb: ^Keyboard) {
	kb.rollover = {}
	shift_down := kb.down[int(SDL.Scancode.LSHIFT)] || kb.down[int(SDL.Scancode.RSHIFT)]
	shift_used := false

	for e in layout_plain {
		if !kb.down[int(e.sc)] {continue}
		if shift_down {
			if se, ok := shifted_entry(e.sc); ok {
				press(kb, se.a)
				press(kb, se.b)
				shift_used = true
				continue
			}
		}
		press(kb, e.a)
		press(kb, e.b)
	}
	// Keys that only exist shifted (e.g. ~ on the grave key) are not in the plain table.
	if shift_down && kb.down[int(SDL.Scancode.GRAVE)] {
		se, _ := shifted_entry(.GRAVE)
		press(kb, se.a)
		press(kb, se.b)
		shift_used = true
	}
	// A plain Shift press goes straight to the CoCo SHIFT key.
	if shift_down && !shift_used {press(kb, SHIFT)}
}

keyboard_key :: proc(kb: ^Keyboard, sc: SDL.Scancode, down: bool) {
	if int(sc) >= len(kb.down) {return}
	kb.down[int(sc)] = down
	keyboard_update_rollover(kb)
}

keyboard_release_all :: proc(kb: ^Keyboard) {
	kb.down = {}
	kb.rollover = {}
}

// Row bits (active low, bit 7 left clear for the joystick comparator) for the
// columns strobed low in col_sel.
keyboard_get_scan :: proc(kb: ^Keyboard, col_sel: u8) -> u8 {
	active := ~col_sel
	rows: u8
	for x in 0 ..< 8 {
		if active & (1 << u8(x)) != 0 {
			rows |= kb.rollover[x]
		}
	}
	return 127 - rows
}
