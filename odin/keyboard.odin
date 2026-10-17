package vcc

import SDL "vendor:sdl2"

// CoCo keyboard matrix. Rows are bit masks (1..64) read on PIA0 side A,
// columns (0-7) are strobed by PIA0 side B (active low). Layout is VCC's
// positional "CoCo (DECB)" table from keyboardLayout.cpp:
//
//          col: 0     1      2      3     4     5     6     7
//   row  1:     @     A      B      C     D     E     F     G
//   row  2:     H     I      J      K     L     M     N     O
//   row  4:     P     Q      R      S     T     U     V     W
//   row  8:     X     Y      Z      UP   DWN   LFT   RGT  SPACE
//   row 16:     0     1!     2"     3#    4$    5%    6&    7'
//   row 32:    8(     9)     :*     ;+    ,<    -=    .>    /?
//   row 64:    ENT   CLR  BRK/ESC  ALT    CTL   F1    F2  SHIFT

Key_Entry :: struct {
	sc:  SDL.Scancode,
	row: u8, // row bit mask
	col: u8,
}

KEY_SHIFT_ROW :: 64
KEY_SHIFT_COL :: 7

coco_layout := [?]Key_Entry {
	{.A, 1, 1}, {.B, 1, 2}, {.C, 1, 3}, {.D, 1, 4}, {.E, 1, 5}, {.F, 1, 6}, {.G, 1, 7},
	{.H, 2, 0}, {.I, 2, 1}, {.J, 2, 2}, {.K, 2, 3}, {.L, 2, 4}, {.M, 2, 5}, {.N, 2, 6}, {.O, 2, 7},
	{.P, 4, 0}, {.Q, 4, 1}, {.R, 4, 2}, {.S, 4, 3}, {.T, 4, 4}, {.U, 4, 5}, {.V, 4, 6}, {.W, 4, 7},
	{.X, 8, 0}, {.Y, 8, 1}, {.Z, 8, 2},
	{.NUM0, 16, 0}, {.NUM1, 16, 1}, {.NUM2, 16, 2}, {.NUM3, 16, 3},
	{.NUM4, 16, 4}, {.NUM5, 16, 5}, {.NUM6, 16, 6}, {.NUM7, 16, 7},
	{.NUM8, 32, 0}, {.NUM9, 32, 1},
	{.SPACE, 8, 7},
	{.COMMA, 32, 4}, {.PERIOD, 32, 6}, {.SLASH, 32, 7},
	{.MINUS, 32, 2}, // : *
	{.SEMICOLON, 32, 3}, // ; +
	{.EQUALS, 32, 5}, // - =
	{.UP, 8, 3}, {.DOWN, 8, 4}, {.LEFT, 8, 5}, {.RIGHT, 8, 6},
	{.KP_8, 8, 3}, {.KP_2, 8, 4}, {.KP_4, 8, 5}, {.KP_6, 8, 6},
	{.RETURN, 64, 0}, {.KP_ENTER, 64, 0},
	{.HOME, 64, 1}, {.KP_7, 64, 1}, // CLEAR
	{.ESCAPE, 64, 2}, {.END, 64, 2}, {.KP_1, 64, 2}, // BREAK
	{.F1, 64, 5}, {.F2, 64, 6},
	{.BACKSPACE, 8, 5}, // CoCo left arrow
	{.LALT, 64, 3}, {.LCTRL, 64, 4},
	{.LSHIFT, 64, 7}, {.RSHIFT, 64, 7},
}

Keyboard :: struct {
	down:     [SDL.NUM_SCANCODES]bool,
	rollover: [8]u8, // per column: rows currently pressed
}

keyboard_update_rollover :: proc(kb: ^Keyboard) {
	kb.rollover = {}
	for e in coco_layout {
		if kb.down[int(e.sc)] {
			kb.rollover[e.col] |= e.row
		}
	}
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
