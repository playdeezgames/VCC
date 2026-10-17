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

// Renderer hooks (filled in by milestone 6).
video_begin_frame :: proc(m: ^Machine) {}
video_end_frame :: proc(m: ^Machine) {}
video_draw_line :: proc(m: ^Machine, area: Video_Area, line: int) {}
