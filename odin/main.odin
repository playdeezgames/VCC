package vcc

import "core:fmt"
import "core:os"
import "core:strings"
import "core:time"
import SDL "vendor:sdl2"

SCREEN_W :: 640
SCREEN_H :: 480

main :: proc() {
	rom_path := ""
	cart_path := ""
	dump_frame := -1
	text_dump := false
	args := os.args[1:]
	for i := 0; i < len(args); i += 1 {
		switch args[i] {
		case "--rom":
			i += 1
			if i < len(args) {rom_path = args[i]}
		case "--cart":
			i += 1
			if i < len(args) {cart_path = args[i]}
		case "--dump-frame":
			i += 1
			if i < len(args) {dump_frame = parse_int(args[i])}
		case "--text-dump":
			text_dump = true
		}
	}
	if rom_path == "" {
		fmt.eprintln("usage: vcc --rom <coco3.rom> [--cart <disk11.rom>] [--dump-frame N [--text-dump]]")
		os.exit(2)
	}
	rom, rerr := os.read_entire_file(rom_path, context.allocator)
	if rerr != nil || len(rom) == 0 || len(rom) > 0x8000 {
		fmt.eprintfln("cannot load ROM %q (need 1..32768 bytes)", rom_path)
		os.exit(1)
	}
	defer delete(rom)

	m := new(Machine)
	machine_init(m)
	defer machine_destroy(m)
	machine_load_rom(m, rom)
	if cart_path != "" {
		cart, cerr := os.read_entire_file(cart_path, context.allocator)
		if cerr != nil {
			fmt.eprintfln("cannot load cartridge ROM %q", cart_path)
			os.exit(1)
		}
		machine_load_cart(m, cart)
	}
	machine_reset(m)

	framebuffer := make([]u32, SCREEN_W * SCREEN_H)
	defer delete(framebuffer)
	m.fb = framebuffer

	// Headless: run N frames, dump, exit (no window).
	if dump_frame >= 0 {
		for _ in 0 ..< dump_frame {machine_run_frame(m)}
		fmt.printfln("pc=%04X cc=%02X a=%02X b=%02X x=%04X s=%04X", m.cpu.pc, get_cc(&m.cpu), m.cpu.a, m.cpu.b, m.cpu.x, m.cpu.s)
		if text_dump {dump_text_screen(m)}
		write_ppm("frame.ppm", framebuffer)
		return
	}

	if SDL.Init({.VIDEO, .AUDIO, .EVENTS}) != 0 {
		fmt.eprintln("SDL_Init:", SDL.GetError())
		os.exit(1)
	}
	defer SDL.Quit()

	window := SDL.CreateWindow("VCC (Odin)", SDL.WINDOWPOS_CENTERED, SDL.WINDOWPOS_CENTERED, SCREEN_W, SCREEN_H, {.RESIZABLE})
	renderer := SDL.CreateRenderer(window, -1, {.ACCELERATED})
	SDL.RenderSetLogicalSize(renderer, SCREEN_W, SCREEN_H)
	tex := SDL.CreateTexture(renderer, .ARGB8888, .STREAMING, SCREEN_W, SCREEN_H)
	defer SDL.DestroyWindow(window)

	frame_time := time.Second / 60
	next := time.tick_now()
	running := true
	for running {
		e: SDL.Event
		for SDL.PollEvent(&e) {
			#partial switch e.type {
			case .QUIT:
				running = false
			case .KEYDOWN:
				if e.key.repeat == 0 {handle_key(m, &running, e.key.keysym.scancode, true)}
			case .KEYUP:
				handle_key(m, &running, e.key.keysym.scancode, false)
			}
		}

		machine_run_frame(m)

		SDL.UpdateTexture(tex, nil, raw_data(framebuffer), SCREEN_W * 4)
		SDL.RenderClear(renderer)
		SDL.RenderCopy(renderer, tex, nil, nil)
		SDL.RenderPresent(renderer)

		// Hold 60 fps
		next = time.tick_add(next, frame_time)
		if rest := time.tick_diff(time.tick_now(), next); rest > 0 {
			time.sleep(rest)
		} else if rest < -frame_time * 4 {
			next = time.tick_now() // fell far behind: resync
		}
	}
}

handle_key :: proc(m: ^Machine, running: ^bool, sc: SDL.Scancode, down: bool) {
	// Host hotkeys
	if down && sc == .F10 {running^ = false; return}
	if down && sc == .F9 {machine_reset(m); return} // soft reset
	machine_key_event(m, sc, down)
}

// Debug aid until the renderer exists: print the 32x16 VDG text screen.
dump_text_screen :: proc(m: ^Machine) {
	voff := (u32(m.gime_regs[0x9D]) << 8 | u32(m.gime_regs[0x9E])) & 0xE0FF
	start := (int(voff) * 8 + int(m.sam_dis_offset) * 512) & (len(m.ram) - 1)
	fmt.printfln("screen @ %05X (sam offset %02X, voff %04X)", start, m.sam_dis_offset, voff)
	for row in 0 ..< 16 {
		b: strings.Builder
		defer strings.builder_destroy(&b)
		for col in 0 ..< 32 {
			v := m.ram[(start + row * 32 + col) & (len(m.ram) - 1)]
			ch := v & 0x3F
			ascii := ch + 0x40 if ch < 0x20 else ch // VDG: 0-31 = @A-Z.., 32-63 = space..?
			if ascii < 0x20 || ascii > 0x7E {ascii = '.'}
			strings.write_byte(&b, ascii)
		}
		fmt.println(strings.to_string(b))
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
