package vcc

import "core:fmt"
import "core:os"
import "core:strings"
import SDL "vendor:sdl2"

SCREEN_W :: 640
SCREEN_H :: 480
FRAME_NS :: 16_666_667 // ~60Hz

main :: proc() {
	rom_path := ""
	dump_frame := -1
	args := os.args[1:]
	for i := 0; i < len(args); i += 1 {
		switch args[i] {
		case "--rom":
			i += 1
			if i < len(args) {rom_path = args[i]}
		case "--dump-frame":
			i += 1
			if i < len(args) {dump_frame = parse_int(args[i])}
		}
	}
	if rom_path == "" {
		fmt.eprintln("usage: vcc --rom <coco3.rom> [--dump-frame N]")
		os.exit(2)
	}
	rom, rerr := os.read_entire_file(rom_path, context.allocator)
	if rerr != nil || len(rom) == 0 || len(rom) > 0x8000 {
		fmt.eprintfln("cannot load ROM %q (need 1..32768 bytes)", rom_path)
		os.exit(1)
	}
	defer delete(rom)

	if SDL.Init({.VIDEO, .AUDIO, .EVENTS}) != 0 {
		fmt.eprintln("SDL_Init:", SDL.GetError())
		os.exit(1)
	}
	defer SDL.Quit()

	window := SDL.CreateWindow("VCC (Odin)", SDL.WINDOWPOS_CENTERED, SDL.WINDOWPOS_CENTERED, SCREEN_W, SCREEN_H, {.RESIZABLE})
	renderer := SDL.CreateRenderer(window, -1, {.ACCELERATED, .PRESENTVSYNC})
	SDL.RenderSetLogicalSize(renderer, SCREEN_W, SCREEN_H)
	tex := SDL.CreateTexture(renderer, .ARGB8888, .STREAMING, SCREEN_W, SCREEN_H)
	defer SDL.DestroyWindow(window)

	framebuffer := make([]u32, SCREEN_W * SCREEN_H)
	defer delete(framebuffer)

	frame := 0
	running := true
	for running {
		e: SDL.Event
		for SDL.PollEvent(&e) {
			#partial switch e.type {
			case .QUIT:
				running = false
			case .KEYDOWN:
				if e.key.keysym.sym == .ESCAPE {running = false}
			}
		}

		// Placeholder: machine run_frame goes here (milestone 2+).
		shade := u32(frame % 64) * 2
		for i in 0 ..< len(framebuffer) {framebuffer[i] = 0xFF000000 | shade << 8}

		SDL.UpdateTexture(tex, nil, raw_data(framebuffer), SCREEN_W * 4)
		SDL.RenderClear(renderer)
		SDL.RenderCopy(renderer, tex, nil, nil)
		SDL.RenderPresent(renderer)

		frame += 1
		if dump_frame >= 0 && frame > dump_frame {
			write_ppm("frame.ppm", framebuffer)
			running = false
		}
	}
}

parse_int :: proc(s: string) -> int {
	n := 0
	for c in transmute([]u8)s {
		if c < '0' || c > '9' {break}
		n = n * 10 + int(c - '0')
	}
	return n
}

write_ppm :: proc(path: string, fb: []u32) {
	b: strings.Builder
	defer strings.builder_destroy(&b)
	fmt.sbprintf(&b, "P6\n%d %d\n255\n", SCREEN_W, SCREEN_H)
	for px in fb {
		strings.write_byte(&b, u8(px >> 16))
		strings.write_byte(&b, u8(px >> 8))
		strings.write_byte(&b, u8(px))
	}
	_ = os.write_entire_file(path, transmute([]u8)strings.to_string(b))
}
