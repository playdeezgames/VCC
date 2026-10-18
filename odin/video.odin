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

// Composite monitor colors: the same 6 bit register value is read as IIPPPP
// (2 bits intensity, 4 bits phase). Table from VCC's MakeCMPpalette.
CMP_RED := [64]int {
	0, 14, 12, 21, 51, 86, 108, 118, 113, 92, 61, 21, 1, 5, 12, 13,
	50, 29, 49, 86, 119, 158, 179, 192, 186, 165, 133, 94, 23, 16, 23, 25,
	116, 74, 102, 142, 179, 219, 243, 252, 251, 230, 198, 155, 81, 61, 52, 57,
	253, 137, 161, 189, 215, 240, 253, 253, 251, 237, 214, 183, 134, 121, 116, 255,
}
CMP_GREEN := [64]int {
	0, 78, 69, 53, 33, 4, 1, 1, 12, 24, 31, 35, 37, 51, 67, 77,
	50, 149, 141, 123, 103, 77, 55, 39, 35, 43, 53, 63, 100, 119, 137, 148,
	116, 212, 204, 186, 164, 137, 114, 97, 88, 89, 96, 109, 156, 179, 199, 211,
	253, 230, 221, 207, 192, 174, 158, 148, 143, 144, 150, 162, 196, 212, 225, 255,
}
CMP_BLUE := [64]int {
	0, 20, 18, 14, 10, 10, 12, 19, 76, 135, 178, 196, 148, 97, 29, 20,
	50, 38, 36, 32, 28, 25, 24, 78, 143, 207, 248, 249, 228, 174, 99, 46,
	116, 58, 52, 48, 44, 41, 68, 132, 202, 250, 250, 250, 251, 243, 163, 99,
	254, 104, 83, 77, 82, 105, 142, 188, 237, 251, 251, 251, 252, 240, 183, 255,
}

composite_color :: proc(c: u8) -> u32 {
	i := int(c & 63)
	gamma := f32(1.4)
	if i > 39 {gamma = 1.1}
	if i > 55 {gamma = 1.0}
	ch :: proc(v: int, gamma: f32) -> u32 {return u32(min(255, f32(v) * gamma))}
	return 0xFF000000 | ch(CMP_RED[i], gamma) << 16 | ch(CMP_GREEN[i], gamma) << 8 | ch(CMP_BLUE[i], gamma)
}

// Decode a palette/border register value for the selected monitor.
video_color :: proc(m: ^Machine, c: u8) -> u32 {
	return rgb_color(c) if m.monitor_rgb else composite_color(c)
}

video_palette :: proc(m: ^Machine) -> (pal: [16]u32) {
	for i in 0 ..< 16 {pal[i] = video_color(m, m.gime_regs[0xB0 + i])}
	return
}

// Power-up palette (VCC SetDefaultPalette): written so BASIC colors show up
// before the ROM programs the registers.
video_default_palette :: proc(m: ^Machine) {
	pal := [16]u8{18, 36, 11, 7, 63, 31, 9, 38, 0, 18, 0, 63, 0, 18, 0, 38}
	for i in 0 ..< 16 {m.gime_regs[0xB0 + i] = pal[i]}
}


// ---------------------------------------------------------------- NTSC artifact colors
//
// A composite monitor turns the fine black/white pixel pattern of the CoCo 2
// 256x192 two-color mode (PMODE 4, color set 1, i.e. white border) into
// colors, because pixel pairs beat against the color burst. VCC models it with
// a table indexed by the neighbouring pixel pairs: [previous pair][this pair]
// [next pair][even/odd], giving one of 16 colors (ArtifactsNTSC in
// tcc1014graphics.cpp). The second color set swaps the blue/red phase (the
// real machine powers up in either phase; F3 flips it).

ARTIFACT_COLORS := [2][16]u32 {
	{
		0xFF000000, 0xFF004000, 0xFF300030, 0xFFC0E0C0,
		0xFFEEC8EE, 0xFF0020A0, 0xFFC03C1E, 0xFF618CFF,
		0xFFFF8F48, 0xFFFF7800, 0xFF0080FF, 0xFF64F0FF,
		0xFFFFF0C8, 0xFF00003C, 0xFF3C0000, 0xFFFFFFFF,
	},
	{
		0xFF000000, 0xFF004000, 0xFF300030, 0xFFC0E0C0,
		0xFFEEC8EE, 0xFFC03C1E, 0xFF0020A0, 0xFFFF8F48,
		0xFF618CFF, 0xFF0080FF, 0xFFFF7800, 0xFFFFF0C8,
		0xFF64F0FF, 0xFF3C0000, 0xFF00003C, 0xFFFFFFFF,
	},
}

// Bit pattern [prev pair][pair][next pair][odd] to an index into ARTIFACT_COLORS.
ARTIFACT_INDEX := [128]u8 {
	0, 0, 0, 0, 0, 6, 0, 2, 5, 7, 5, 7, 1, 3, 1, 11,
	8, 6, 8, 14, 8, 9, 8, 9, 4, 4, 4, 15, 12, 12, 12, 15,
	5, 13, 5, 13, 13, 0, 13, 2, 10, 10, 10, 10, 10, 15, 10, 11,
	3, 1, 3, 1, 15, 9, 15, 9, 11, 11, 11, 11, 15, 15, 15, 15,
	14, 0, 14, 0, 14, 6, 14, 2, 0, 7, 0, 7, 1, 3, 1, 11,
	9, 6, 9, 14, 9, 9, 9, 9, 15, 4, 15, 15, 12, 12, 12, 15,
	2, 13, 2, 13, 2, 0, 2, 2, 10, 10, 10, 10, 10, 15, 10, 11,
	12, 1, 12, 1, 12, 9, 12, 9, 15, 11, 15, 11, 15, 15, 15, 15,
}

// Does this frame use composite artifact colors? Only the CoCo 2 compatible
// 256x192 two-color mode with color set 1 (white border), on a composite
// monitor, and not when the GIME monochrome bit ($FF98 bit 4) forces RGB.
video_artifacts_active :: proc(m: ^Machine, v: ^Video_Mode) -> bool {
	return(
		v.compat &&
		v.graphics &&
		v.bpp == 0 &&
		v.pixels_per_line == 256 &&
		v.border_color == 63 &&
		!m.monitor_rgb &&
		v.vmode & 0x10 == 0 \
	)
}

// One scanline of artifact-colored PMODE 4 into lbuf, starting at x. Each pair
// of pixels is looked up with its neighbours; the picture is delayed by one
// pair, and the white border bleeds in at both ends (as in VCC).
render_pmode4_ntsc :: proc(m: ^Machine, v: ^Video_Mode, lbuf: ^[FB_W]u32, start: int, mask: int) {
	invert := int((v.vmode >> 5) & 1)
	if m.artifact_flip {invert ~= 1}
	pattern := u8(3 << 2 | 3) // white border on the left
	x := v.horz_center

	pair :: proc(lbuf: ^[FB_W]u32, x: ^int, pattern: u8, invert: int) {
		idx := int(pattern) << 1
		even := ARTIFACT_COLORS[invert][ARTIFACT_INDEX[idx]]
		odd := ARTIFACT_COLORS[invert][ARTIFACT_INDEX[idx + 1]]
		for c in ([2]u32{even, even}) {if x^ < FB_W {lbuf[x^] = c}; x^ += 1}
		for c in ([2]u32{odd, odd}) {if x^ < FB_W {lbuf[x^] = c}; x^ += 1}
	}

	for i in 0 ..< v.bytes_per_row {
		b := m.ram[(start + (v.hoffset + i) & 0xFF) & mask]
		for _ in 0 ..< 4 {
			pattern = (pattern << 2 + (b >> 6) & 3) & 0x3F
			b <<= 2
			pair(lbuf, &x, pattern, invert)
		}
	}
	for _ in 0 ..< 2 { 	// right edge bleeds with the white border
		pattern = (pattern << 2 + 3) & 0x3F
		pair(lbuf, &x, pattern, invert)
	}
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
	border := video_color(m, v.border_color)

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
	} else if video_artifacts_active(m, v) {
		render_pmode4_ntsc(m, v, &lbuf, start, mask)
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
