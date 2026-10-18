package vcc

import "core:os"
import "core:testing"

video_machine :: proc() -> ^Machine {
	m := test_machine()
	m.monitor_rgb = true // most tests use the simple RGB decode
	m.fb = make([]u32, FB_W * FB_H)
	// Park the CPU in a harmless loop (BRA *) so it cannot scribble on video RAM.
	poke(m, 0x4000, {0x20, 0xFE})
	m.cpu.pc = 0x4000
	return m
}

video_machine_free :: proc(m: ^Machine) {
	delete(m.fb)
	test_machine_free(m)
}

px :: proc(m: ^Machine, x, y: int) -> u32 {return m.fb[y * FB_W + x]}

GREEN :: u32(0xFF00FF00)
BLACK :: u32(0xFF000000)
WHITE :: u32(0xFFFFFFFF)

// First visible scanline of a 192 line mode sits at framebuffer row 50.
ROW0 :: 50

set_palette :: proc(m: ^Machine, index: int, color: u8) {
	mem_write8(m, 0xFFB0 + u16(index), color)
}

set_video_start :: proc(m: ^Machine, addr: int) {
	vor := addr / 8
	mem_write8(m, 0xFF9D, u8(vor >> 8))
	mem_write8(m, 0xFF9E, u8(vor))
}

@(test)
rgb_palette_conversion :: proc(t: ^testing.T) {
	testing.expect_value(t, rgb_color(0), BLACK)
	testing.expect_value(t, rgb_color(63), WHITE)
	testing.expect_value(t, rgb_color(18), GREEN)
	testing.expect_value(t, rgb_color(0b100100), u32(0xFFFF0000)) // red
	testing.expect_value(t, rgb_color(0b001001), u32(0xFF0000FF)) // blue
	testing.expect_value(t, rgb_color(0b010010) & 0xFF00, u32(0xFF00)) // full green
	testing.expect_value(t, rgb_color(0b000100), u32(0xFF550000)) // red level 1
}

@(test)
borders_and_background_filled :: proc(t: ^testing.T) {
	m := video_machine()
	defer video_machine_free(m)
	mem_write8(m, 0xFF9A, 0b101010) // CoCo 3 border color
	machine_run_frame(m)
	testing.expect_value(t, px(m, 5, 5), rgb_color(0b101010)) // top border
	testing.expect_value(t, px(m, 320, 470), rgb_color(0b101010)) // bottom border
	// every framebuffer row up to the bottom border must have been drawn
	for y in 0 ..< 478 {
		testing.expect(t, px(m, 0, y) != 0, "row never drawn")
		if px(m, 0, y) == 0 {break}
	}
}

@(test)
coco3_16_color_graphics :: proc(t: ^testing.T) {
	m := video_machine()
	defer video_machine_free(m)
	// 320x192, 16 colors: GRAPHICS, 192 lines, 160 bytes/row, 4 bpp
	mem_write8(m, 0xFF90, 0)
	mem_write8(m, 0xFF98, 0x80)
	mem_write8(m, 0xFF99, 0x1E)
	set_video_start(m, 0x70000)
	set_palette(m, 1, 63) // white
	set_palette(m, 2, 0b100100) // red
	m.ram[0x70000] = 0x12 // pixels 0,1 = colors 1,2
	m.ram[0x70001] = 0x21
	machine_run_frame(m)
	// each source pixel is 2 wide (stretch 1), no side borders at 640 px
	testing.expect_value(t, px(m, 0, ROW0), WHITE)
	testing.expect_value(t, px(m, 1, ROW0), WHITE)
	testing.expect_value(t, px(m, 2, ROW0), u32(0xFFFF0000))
	testing.expect_value(t, px(m, 3, ROW0), u32(0xFFFF0000))
	testing.expect_value(t, px(m, 4, ROW0), u32(0xFFFF0000))
	testing.expect_value(t, px(m, 6, ROW0), WHITE)
	// scanlines are doubled vertically
	testing.expect_value(t, px(m, 0, ROW0 + 1), WHITE)
	testing.expect_value(t, px(m, 0, ROW0 + 2), rgb_color(m.gime_regs[0xBF] & 63)) // next line reads RAM powered up as $FF -> pal[15]
}

@(test)
coco3_2_color_640 :: proc(t: ^testing.T) {
	m := video_machine()
	defer video_machine_free(m)
	// 640x192, 2 colors: 80 bytes/row, 1 bpp
	mem_write8(m, 0xFF98, 0x80)
	mem_write8(m, 0xFF99, 0x14)
	set_video_start(m, 0x70000)
	set_palette(m, 0, 0)
	set_palette(m, 1, 63)
	m.ram[0x70000] = 0b10100000
	machine_run_frame(m)
	testing.expect_value(t, px(m, 0, ROW0), WHITE)
	testing.expect_value(t, px(m, 1, ROW0), BLACK)
	testing.expect_value(t, px(m, 2, ROW0), WHITE)
	testing.expect_value(t, px(m, 3, ROW0), BLACK)
}

@(test)
coco3_4_color_and_second_row :: proc(t: ^testing.T) {
	m := video_machine()
	defer video_machine_free(m)
	// 640x192, 4 colors: 160 bytes/row, 2 bpp
	mem_write8(m, 0xFF98, 0x80)
	mem_write8(m, 0xFF99, 0x1D)
	set_video_start(m, 0x70000)
	set_palette(m, 3, 63)
	m.ram[0x70000] = 0b11000000
	m.ram[0x70000 + 160] = 0b00110000 // second scanline
	machine_run_frame(m)
	testing.expect_value(t, px(m, 0, ROW0), WHITE)
	testing.expect_value(t, px(m, 1, ROW0), rgb_color(m.gime_regs[0xB0] & 63))
	testing.expect_value(t, px(m, 1, ROW0 + 2), WHITE) // row 1 pixel 1
}

@(test)
coco3_80_column_text_with_attributes :: proc(t: ^testing.T) {
	m := video_machine()
	defer video_machine_free(m)
	// 80 column text with attribute bytes: 160 bytes/row
	mem_write8(m, 0xFF98, 0x00)
	mem_write8(m, 0xFF99, 0x15)
	set_video_start(m, 0x70000)
	set_palette(m, 0, 0) // background (attr & 7 = 0)
	set_palette(m, 9, 63) // foreground (8 + ((attr & 56) >> 3) = 9)
	m.ram[0x70000] = 0xDB // full block glyph? use a known solid: check any fg pixel
	m.ram[0x70001] = 0x08 // fg = palette 9
	machine_run_frame(m)
	fg, bg := 0, 0
	for y in ROW0 ..< ROW0 + 24 {
		for x in 0 ..< 8 {
			c := px(m, x, y)
			if c == WHITE {fg += 1}
			if c == BLACK {bg += 1}
		}
	}
	testing.expect(t, fg > 0 && bg > 0, "glyph should have foreground and background pixels")
	testing.expect_value(t, fg + bg, 8 * 24)
}

@(test)
coco2_text_green_screen :: proc(t: ^testing.T) {
	m := video_machine()
	defer video_machine_free(m)
	mem_write8(m, 0xFF90, 0x80) // CoCo 2 compatibility
	set_video_start(m, 0)
	for i in 0 ..< 512 {m.ram[i] = 0x20} // normal-video space: glyph is all "set" -> palette 12
	m.ram[1] = 0x60 // inverse-video space: all "clear" -> palette 13
	machine_run_frame(m)
	// 32 columns x 16 pixels = 512 wide, 64 pixel side borders, text black border
	testing.expect_value(t, px(m, 10, ROW0 + 5), BLACK) // left border
	testing.expect_value(t, px(m, 600, ROW0 + 5), BLACK) // right border
	testing.expect_value(t, px(m, 64, ROW0 + 5), rgb_color(m.gime_regs[0xBC] & 63)) // palette 12
	testing.expect_value(t, px(m, 64 + 16, ROW0 + 5), rgb_color(m.gime_regs[0xBD] & 63)) // palette 13: char 1
	testing.expect_value(t, px(m, 100, ROW0 + 5 + 100), rgb_color(m.gime_regs[0xBC] & 63))
}

@(test)
coco2_semigraphics_block :: proc(t: ^testing.T) {
	m := video_machine()
	defer video_machine_free(m)
	mem_write8(m, 0xFF90, 0x80)
	set_video_start(m, 0)
	// Semigraphics 4: bit7 set, bits 6-4 color (0..7), bits 3-0 quadrants
	m.ram[0] = 0x80 | (4 << 4) | 0x0F // all four quadrants, color 4 (palette 4 = buff = 63)
	machine_run_frame(m)
	pal4 := rgb_color(m.gime_regs[0xB4] & 63)
	testing.expect_value(t, px(m, 64, ROW0), pal4) // first char starts after the 64 pixel border
	testing.expect_value(t, px(m, 64 + 15, ROW0 + 2*11), pal4)
}

@(test)
coco2_rg6_graphics :: proc(t: ^testing.T) {
	m := video_machine()
	defer video_machine_free(m)
	mem_write8(m, 0xFF90, 0x80)
	// PIA1 B: A/G=1, GM2..0 = 111 (RG6, 256x192), CSS=0
	mem_write8(m, 0xFF23, 0)
	mem_write8(m, 0xFF22, 0xF8)
	mem_write8(m, 0xFF23, 0x04)
	mem_write8(m, 0xFF22, 0xF0)
	// SAM V2..V0 = 110 (RG6)
	mem_write8(m, 0xFFC0, 0)
	mem_write8(m, 0xFFC3, 0)
	mem_write8(m, 0xFFC5, 0)
	set_video_start(m, 0)
	m.ram[0] = 0b10000000
	machine_run_frame(m)
	// palette 8 = black, 9 = green (default palette); set pixel 0 -> green, 2x wide, 64 px border
	testing.expect_value(t, px(m, 64, ROW0), GREEN)
	testing.expect_value(t, px(m, 65, ROW0), GREEN)
	testing.expect_value(t, px(m, 66, ROW0), BLACK)
	testing.expect_value(t, px(m, 10, ROW0), GREEN) // CSS=0 graphics border is bright green
}

@(test)
real_rom_screen_pixels :: proc(t: ^testing.T) {
	data, err := os_read_rom()
	if err {return}
	defer delete(data)
	m := video_machine()
	defer video_machine_free(m)
	machine_load_rom(m, data)
	machine_reset(m)
	for _ in 0 ..< 200 {machine_run_frame(m)}
	// BASIC screen: black text on green, black border, blue cursor
	testing.expect_value(t, px(m, 5, 5), BLACK)
	testing.expect_value(t, px(m, 500, 300), GREEN)
	testing.expect_value(t, px(m, 600, 300), BLACK) // right border in text mode
	greens, blacks := 0, 0
	for y in 50 ..< 74 {
		for x in 64 ..< 576 {
			if px(m, x, y) == GREEN {greens += 1}
			if px(m, x, y) == BLACK {blacks += 1}
		}
	}
	testing.expect(t, greens > 0 && blacks > 0, "banner row has text pixels")
}

os_read_rom :: proc() -> (data: []u8, missing: bool) {
	d, err := os.read_entire_file("coco3.rom", context.allocator)
	return d, err != nil
}

Hue :: enum {
	Other,
	Green,
	Yellow,
	Blue,
	Red,
}

// Coarse hue classification of an ARGB pixel.
hue_of :: proc(c: u32) -> Hue {
	r, g, b := int(c >> 16 & 0xFF), int(c >> 8 & 0xFF), int(c & 0xFF)
	switch {
	case g > 120 && r > 120 && b < 100:
		return .Yellow
	case g > r + 60 && g > b + 60:
		return .Green
	case b > r + 60 && b > g + 60:
		return .Blue
	case r > g + 60 && r > b + 60:
		return .Red
	}
	return .Other
}

@(test)
composite_palette_power_up_colors :: proc(t: ^testing.T) {
	// BASIC's power-up palette values read on a composite monitor
	testing.expect_value(t, hue_of(composite_color(0x12)), Hue.Green)
	testing.expect_value(t, hue_of(composite_color(0x24)), Hue.Yellow)
	testing.expect_value(t, hue_of(composite_color(0x0B)), Hue.Blue)
	testing.expect_value(t, hue_of(composite_color(0x07)), Hue.Red)
	testing.expect_value(t, composite_color(0x00), BLACK)
	testing.expect_value(t, composite_color(0x3F), WHITE)
}

@(test)
pmode3_colors_green_yellow_blue_red :: proc(t: ^testing.T) {
	m := video_machine()
	defer video_machine_free(m)
	m.monitor_rgb = false // composite, the default
	mem_write8(m, 0xFF90, 0x80)
	// PIA1 B: A/G=1, GM = 110 (CG6, 128x192 4 colors = PMODE 3), CSS = 0
	mem_write8(m, 0xFF23, 0)
	mem_write8(m, 0xFF22, 0xF8)
	mem_write8(m, 0xFF23, 0x04)
	mem_write8(m, 0xFF22, 0xE0)
	mem_write8(m, 0xFFC0, 0)
	mem_write8(m, 0xFFC3, 0)
	mem_write8(m, 0xFFC5, 0)
	set_video_start(m, 0)
	m.ram[0] = 0b00_01_10_11 // pixels 0, 1, 2, 3 = BASIC colors 1, 2, 3, 4
	machine_run_frame(m)
	testing.expect_value(t, hue_of(px(m, 64, ROW0)), Hue.Green) // color 1
	testing.expect_value(t, hue_of(px(m, 68, ROW0)), Hue.Yellow) // color 2
	testing.expect_value(t, hue_of(px(m, 72, ROW0)), Hue.Blue) // color 3
	testing.expect_value(t, hue_of(px(m, 76, ROW0)), Hue.Red) // color 4
}

@(test)
rom_programs_composite_palette :: proc(t: ^testing.T) {
	data, missing := os_read_rom()
	if missing {return}
	defer delete(data)
	m := video_machine()
	defer video_machine_free(m)
	machine_load_rom(m, data)
	machine_reset(m)
	for i in 0 ..< 16 {m.gime_regs[0xB0 + i] = 0} // forget the emulator's power-up palette
	for _ in 0 ..< 200 {machine_run_frame(m)}
	// the ROM itself writes the composite-style set (yellow = $24, red = $07)
	testing.expect_value(t, m.gime_regs[0xB1], 0x24)
	testing.expect_value(t, m.gime_regs[0xB3], 0x07)
}

@(test)
f5_style_toggle_changes_decoding :: proc(t: ^testing.T) {
	m := video_machine()
	defer video_machine_free(m)
	mem_write8(m, 0xFFB1, 0x24)
	m.monitor_rgb = true
	testing.expect_value(t, hue_of(video_palette(m)[1]), Hue.Red) // $24 as RGB bits is red
	m.monitor_rgb = false
	testing.expect_value(t, hue_of(video_palette(m)[1]), Hue.Yellow) // as composite it is yellow
}
