package vcc

// Video. Milestone 5 only needs the frame geometry (how many scanlines each
// part of the frame takes); the renderers come in milestone 6.

Video_Area :: enum {
	Top_Border,
	Active,
	Bottom_Border,
}

Video_Geometry :: struct {
	top_offscreen:    int,
	top_border:       int,
	active_lines:     int,
	bottom_border:    int,
	bottom_offscreen: int,
}

LINES_PER_FRAME_TABLE := [4]int{192, 199, 225, 225}
VCENTER_TABLE := [4]int{25, 19, 8, 8}
TOP_OFFSCREEN_TABLE := [4]int{11, 14, 11, 11}
BOTTOM_OFFSCREEN_TABLE := [4]int{5, 1, 5, 5}

// CoCo 2 compatibility mode (INIT0 bit 7) always uses 192 lines.
video_vres_index :: proc(m: ^Machine) -> int {
	if m.gime_regs[0x90] & 0x80 != 0 {return 0}
	return int((m.gime_regs[0x99] & 0x60) >> 5)
}

// Scanline layout of the 262 line frame; the parts always add up to 255 lines
// after the 4+3 sync lines.
video_geometry :: proc(m: ^Machine) -> Video_Geometry {
	i := video_vres_index(m)
	lines := LINES_PER_FRAME_TABLE[i]
	top := VCENTER_TABLE[i]
	return {
		top_offscreen = TOP_OFFSCREEN_TABLE[i],
		top_border = top,
		active_lines = lines,
		bottom_border = 239 - (top + lines),
		bottom_offscreen = BOTTOM_OFFSCREEN_TABLE[i],
	}
}

// ---------------------------------------------------------------- renderer
//
// Draws into Machine.fb (640x480, ARGB). Each emulated scanline becomes two
// framebuffer rows. Ports UpdateScreen32/DrawTopBoarder32 of
// tcc1014graphics.cpp in a mode-parameter driven form (the C++ has one copy of
// the code per mode and bit depth).

FB_W :: 640
FB_H :: 480

VID_MASK := [4]int{0x1FFFF, 0x7FFFF, 0x1FFFFF, 0x7FFFFF}
BLINK_FRAMES :: 16

// Extra scanline offsets from the vertical scroll register ($FF9C), indexed
// by [LPR bits of $FF98][scroll & 15].
VERT_SCROLL_TABLE := [8][16]int {
	{0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0},
	{0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0},
	{0, 1, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0},
	{0, 1, 2, 3, 4, 5, 6, 7, 0, 0, 0, 0, 0, 0, 0, 0},
	{0, 1, 2, 3, 4, 5, 6, 7, 8, 0, 8, 0, 8, 0, 8, 0},
	{0, 1, 2, 3, 4, 5, 6, 7, 8, 9, 0, 0, 8, 9, 0, 0},
	{0, 1, 2, 3, 4, 5, 6, 7, 8, 9, 10, 0, 8, 9, 10, 0},
	{0, 1, 2, 3, 4, 5, 6, 7, 8, 9, 10, 11, 12, 13, 14, 15},
}

CC2_BPP := [8]int{1, 0, 1, 0, 1, 0, 1, 0}
CC2_LINES_PER_ROW := [8]int{12, 3, 3, 2, 2, 1, 1, 1}
CC2_BYTES_PER_ROW := [8]int{16, 16, 32, 16, 32, 16, 32, 32}
CC2_PALETTE_SET := [4]int{8, 0, 10, 4}
CC3_LINES_PER_ROW := [8]int{1, 1, 2, 8, 9, 10, 11, 16}
CC3_BYTES_PER_ROW := [8]int{16, 20, 32, 40, 64, 80, 128, 160}
CC3_BYTES_PER_TEXT_ROW := [8]int{32, 40, 32, 40, 64, 80, 64, 80}
PIXELS_PER_BYTE := [4]int{8, 4, 2, 2}

Video_Mode :: struct {
	compat:         bool, // CoCo 2 (VDG) compatibility
	graphics:       bool,
	bpp:            int, // 0 = 1 bit, 1 = 2 bit, 2/3 = 4 bit pixels
	lines_per_row:  int,
	bytes_per_row:  int, // graphics bytes, or text characters
	ext_text:       int, // 2 when text has attribute bytes
	pixels_per_line: int,
	stretch:        int, // each source pixel is drawn stretch+1 wide
	horz_center:    int, // left border width in framebuffer pixels
	vpitch:         int, // bytes between rows in video memory
	palette_index:  int, // CoCo 2 graphics: first palette entry used
	text_fg:        int, // CoCo 2 text palette entries
	text_bg:        int,
	lower_case:     bool,
	underline_row:  int,
	vscroll:        int,
	hoffset:        int,
	border_color:   u8, // raw 6 bit color (not a palette index)
	vmode:          u8, // $FF98 (CoCo 3)
}

// Decode the mode from the GIME/SAM/PIA registers (SetupDisplay).
video_decode :: proc(m: ^Machine) -> Video_Mode {
	v: Video_Mode
	v.compat = m.gime_regs[0x90] & 0x80 != 0
	v.ext_text = 1
	vmode := m.gime_regs[0x98]
	vres := m.gime_regs[0x99]
	v.vmode = vmode
	pia_mode := int(pia_vdg_mode(m))
	sam_mode := int(m.sam_vdg_mode & 7)
	horz_off_reg := m.gime_regs[0x9F]

	if !v.compat { 	// CoCo 3 mode
		v.graphics = vmode & 0x80 != 0
		v.bpp = int(vres & 3)
		v.lines_per_row = CC3_LINES_PER_ROW[vmode & 7]
		v.bytes_per_row = CC3_BYTES_PER_ROW[(vres & 28) >> 2]
		if !v.graphics {
			if vres & 1 != 0 {v.ext_text = 2}
			v.bpp = 0
			v.bytes_per_row = CC3_BYTES_PER_TEXT_ROW[(vres & 28) >> 2]
		}
		v.border_color = m.gime_regs[0x9A] & 63
		v.vscroll = VERT_SCROLL_TABLE[vmode & 7][m.gime_regs[0x9C] & 0xF]
	} else { 	// CoCo 2 mode
		v.graphics = pia_mode & 16 != 0
		v.lines_per_row = CC2_LINES_PER_ROW[sam_mode]
		if v.graphics {
			css := pia_mode & 1
			v.border_color = 18 if css == 0 else 63 // bright green / white
			idx := (pia_mode & 15) >> 1
			v.bpp = CC2_BPP[idx]
			v.bytes_per_row = CC2_BYTES_PER_ROW[idx]
			v.palette_index = CC2_PALETTE_SET[css << 1 | (v.bpp & 1)]
		} else {
			v.border_color = 0
			v.bpp = 0
			v.bytes_per_row = 32
			invert := (pia_mode & 4) >> 2
			v.lower_case = (pia_mode & 2) != 0
			set := (pia_mode & 1) << 1 | invert
			fg_bg := [4][2]int{{12, 13}, {13, 12}, {14, 15}, {15, 14}}
			v.text_fg = fg_bg[set][0]
			v.text_bg = fg_bg[set][1]
		}
	}

	switch vmode & 7 {
	case 3:
		v.underline_row = 7
	case 4, 5:
		v.underline_row = 8
	case 6:
		v.underline_row = 9
	case:
		v.underline_row = -1
	}

	v.pixels_per_line = v.bytes_per_row * PIXELS_PER_BYTE[v.bpp]
	if v.pixels_per_line % 40 != 0 {
		v.stretch = 512 / v.pixels_per_line - 1
		v.horz_center = 64
	} else {
		v.stretch = 640 / v.pixels_per_line - 1
		v.horz_center = 0
	}
	if v.stretch < 0 {v.stretch = 0} // over-wide modes are clipped
	v.vpitch = v.bytes_per_row
	if horz_off_reg & 128 != 0 {v.vpitch = 256}
	v.hoffset = int(horz_off_reg << 1) // u8 wrap
	return v
}

// Start of video memory for the frame.
video_start_address :: proc(m: ^Machine, v: Video_Mode) -> int {
	vor := int(m.gime_regs[0x9D]) << 8 | int(m.gime_regs[0x9E])
	start: int
	if v.compat {
		start = 512 * int(m.sam_dis_offset) + (vor & 0xE0FF) * 8
	} else {
		start = vor * 8
	}
	start &= VID_MASK[m.ram_config]
	if m.ram_config == 2 {start += int(m.gime_regs[0x9B] & 3) * (512 * 1024)}
	if m.ram_config == 3 {start += int(m.gime_regs[0x9B] & 0x0F) * (512 * 1024)}
	return start
}

// 6 bit RGB color (rgbRGB) to ARGB.
RGB_LEVELS := [4]u32{0, 85, 170, 255}

rgb_color :: proc(c: u8) -> u32 {
	r := RGB_LEVELS[(c & 32) >> 4 | (c & 4) >> 2]
	g := RGB_LEVELS[(c & 16) >> 3 | (c & 2) >> 1]
	b := RGB_LEVELS[(c & 8) >> 2 | (c & 1)]
	return 0xFF000000 | r << 16 | g << 8 | b
}

video_palette :: proc(m: ^Machine) -> (pal: [16]u32) {
	for i in 0 ..< 16 {pal[i] = rgb_color(m.gime_regs[0xB0 + i] & 63)}
	return
}

// Power-up palette (VCC SetDefaultPalette): written so BASIC colors show up
// before the ROM programs the registers.
video_default_palette :: proc(m: ^Machine) {
	pal := [16]u8{18, 36, 11, 7, 63, 31, 9, 38, 0, 18, 0, 63, 0, 18, 0, 38}
	for i in 0 ..< 16 {m.gime_regs[0xB0 + i] = pal[i]}
}

video_begin_frame :: proc(m: ^Machine) {
	m.blink_phase += 1
	if m.blink_phase > BLINK_FRAMES {
		m.blink_state = !m.blink_state
		m.blink_phase = 0
	}
	m.video_mode = video_decode(m)
	m.video_start = video_start_address(m, m.video_mode)
}

video_end_frame :: proc(m: ^Machine) {}

fill_fb_rows :: proc(m: ^Machine, row: int, color: u32) {
	for r in row ..< row + 2 {
		if r < 0 || r >= FB_H {continue}
		base := r * FB_W
		for x in 0 ..< FB_W {m.fb[base + x] = color}
	}
}

video_draw_line :: proc(m: ^Machine, area: Video_Area, line: int) {
	if m.fb == nil {return}
	i := video_vres_index(m)
	lines := LINES_PER_FRAME_TABLE[i]
	vcenter := VCENTER_TABLE[i]
	v := &m.video_mode
	border := rgb_color(v.border_color)

	switch area {
	case .Top_Border:
		fill_fb_rows(m, line * 2, border)
	case .Bottom_Border:
		fill_fb_rows(m, 2 * (lines + vcenter + line), border)
	case .Active:
		draw_active_line(m, v, line, vcenter, border)
	}
}

draw_active_line :: proc(m: ^Machine, v: ^Video_Mode, y: int, vcenter: int, border: u32) {
	lbuf: [FB_W]u32
	for x in 0 ..< FB_W {lbuf[x] = border}

	pal := video_palette(m)
	mask := len(m.ram) - 1
	vm := VID_MASK[m.ram_config]
	x := v.horz_center
	reps := v.stretch + 1

	put :: proc(lbuf: ^[FB_W]u32, x: ^int, color: u32, reps: int) {
		for _ in 0 ..< reps {
			if x^ < FB_W {lbuf[x^] = color}
			x^ += 1
		}
	}

	row_line := (y + v.vscroll) % v.lines_per_row
	row := (y + v.vscroll) / v.lines_per_row
	if v.vmode & 7 == 7 && !v.compat {row = 0}
	start := m.video_start + row * v.vpitch * v.ext_text

	addr :: proc(start, hoff, i, mask: int) -> int {
		return (start + (hoff + i) & 0xFF) & mask
	}

	if !v.graphics && !v.compat {
		// GIME hardware text, 8 pixel wide glyphs, optional attributes
		for i := 0; i < v.bytes_per_row * v.ext_text; i += v.ext_text {
			ch := m.ram[addr(start, v.hoffset, i, mask)]
			glyph: u8 = 0
			if row_line <= 11 {glyph = CC3_FONT[int(ch) * 12 + row_line]}
			attr: u8 = 0
			if v.ext_text == 2 {
				attr = m.ram[addr(start, v.hoffset, i + 1, mask)]
				if attr & 64 != 0 && row_line == v.underline_row {glyph = 255}
				if !m.blink_state && attr & 128 != 0 {glyph = 0}
			}
			fg := pal[8 + int((attr & 56) >> 3)]
			bg := pal[attr & 7]
			for b: u8 = 0; b < 8; b += 1 {
				put(&lbuf, &x, fg if (glyph >> (7 - b)) & 1 != 0 else bg, reps)
			}
		}
	} else if !v.graphics {
		// CoCo 2 VDG text: 32 columns, alphanumerics and semigraphics 4
		for i in 0 ..< v.bytes_per_row {
			ch := m.ram[addr(start, v.hoffset, i, mask)]
			fg, bg: u32
			glyph: u8
			ly := y % 12
			switch ch >> 6 {
			case 0:
				c := int(ch & 63)
				bg = pal[v.text_bg]
				fg = pal[v.text_fg]
				if v.lower_case && c < 32 {
					glyph = CC2_FONT[(c + 80) * 12 + ly]
				} else {
					glyph = ~CC2_FONT[c * 12 + ly]
				}
			case 1:
				c := int(ch & 63)
				bg = pal[v.text_bg]
				fg = pal[v.text_fg]
				glyph = CC2_FONT[c * 12 + ly]
			case:
				fg = pal[(ch & 112) >> 4]
				bg = pal[8]
				glyph = CC2_FONT[(64 + int(ch & 0xF)) * 12 + ly]
			}
			// bit set -> palette entry 1 (fg variable), clear -> entry 0 (bg variable)
			for b: u8 = 0; b < 8; b += 1 {
				put(&lbuf, &x, fg if (glyph >> (7 - b)) & 1 != 0 else bg, reps)
			}
		}
	} else {
		// Graphics: 1, 2 or 4 bits per pixel, bytes in memory order, MSB first
		for i in 0 ..< v.bytes_per_row {
			b := m.ram[addr(start, v.hoffset, i, mask)]
			switch v.bpp {
			case 0:
				for k: u8 = 0; k < 8; k += 1 {
					put(&lbuf, &x, pal[v.palette_index + int((b >> (7 - k)) & 1)], reps)
				}
			case 1:
				for k: u8 = 0; k < 4; k += 1 {
					put(&lbuf, &x, pal[v.palette_index + int((b >> (6 - 2 * k)) & 3)], reps)
				}
			case:
				put(&lbuf, &x, pal[v.palette_index + int(b >> 4)], reps)
				put(&lbuf, &x, pal[v.palette_index + int(b & 15)], reps)
			}
		}
	}
	_ = vm

	for r in 0 ..< 2 {
		fb_row := (y + vcenter) * 2 + r
		if fb_row < 0 || fb_row >= FB_H {continue}
		copy(m.fb[fb_row * FB_W:(fb_row + 1) * FB_W], lbuf[:])
	}
}
