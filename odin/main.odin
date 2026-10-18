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
	mute := false
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
		case "--mute":
			mute = true
		}
	}
	if rom_path == "" {
		fmt.eprintln("usage: vcc --rom <coco3.rom> [--cart <disk11.rom>] [--mute] [--dump-frame N [--text-dump]]")
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

	audio: Audio_Out
	audio_ok := false
	if !mute {
		audio, audio_ok = audio_open()
		if audio_ok {machine_enable_audio(m)}
	}
	defer if audio_ok {audio_close(&audio)}

	frame_time := time.Second / 60
	next := time.tick_now()
	app := App{running = true, window = window}
	for app.running {
		e: SDL.Event
		for SDL.PollEvent(&e) {
			#partial switch e.type {
			case .QUIT:
				app.running = false
			case .KEYDOWN:
				if e.key.repeat == 0 {handle_key(m, &app, e.key.keysym.scancode, true)}
			case .KEYUP:
				handle_key(m, &app, e.key.keysym.scancode, false)
			case .MOUSEMOTION:
				w, h: i32
				SDL.GetWindowSize(window, &w, &h)
				if w > 0 && h > 0 {
					machine_set_axis(m, .Right_X, int(e.motion.x) * STICK_MAX / int(w))
					machine_set_axis(m, .Right_Y, int(e.motion.y) * STICK_MAX / int(h))
				}
			case .MOUSEBUTTONDOWN, .MOUSEBUTTONUP:
				down := e.type == .MOUSEBUTTONDOWN
				switch e.button.button {
				case SDL.BUTTON_LEFT:
					machine_set_button(m, BUTTON_RIGHT_1, down)
				case SDL.BUTTON_RIGHT:
					machine_set_button(m, BUTTON_RIGHT_2, down)
				}
			}
		}
		if app.key_joy {keyboard_joystick(m, &app)}

		if !app.paused {
			paste_step(m)
			machine_run_frame(m)
			if audio_ok {audio_submit(&audio, m)}
		}

		SDL.UpdateTexture(tex, nil, raw_data(framebuffer), SCREEN_W * 4)
		SDL.RenderClear(renderer)
		SDL.RenderCopy(renderer, tex, nil, nil)
		SDL.RenderPresent(renderer)

		// Hold 60 fps: the audio device paces us when present, else the clock.
		if audio_ok && !app.paused {
			for audio_ahead(&audio) && app.running {SDL.Delay(1)}
			next = time.tick_now()
			continue
		}
		next = time.tick_add(next, frame_time)
		if rest := time.tick_diff(time.tick_now(), next); rest > 0 {
			time.sleep(rest)
		} else if rest < -frame_time * 4 {
			next = time.tick_now() // fell far behind: resync
		}
	}
}

App :: struct {
	running:    bool,
	paused:     bool,
	fullscreen: bool,
	key_joy:    bool, // arrow keys / Ctrl / Alt drive the right joystick
	window:     ^SDL.Window,
}

// Host hotkeys:  F6 pause   F7 paste clipboard   F8 keyboard joystick
//                F9 soft reset   F10 quit   F11 fullscreen
handle_key :: proc(m: ^Machine, app: ^App, sc: SDL.Scancode, down: bool) {
	if down {
		#partial switch sc {
		case .F6:
			app.paused = !app.paused
			return
		case .F7:
			if text := SDL.GetClipboardText(); text != nil {
				paste_text(m, string(text))
				SDL.free(rawptr(text))
			}
			return
		case .F8:
			app.key_joy = !app.key_joy
			if !app.key_joy {keyboard_joystick_release(m)}
			return
		case .F9:
			machine_reset(m)
			return
		case .F10:
			app.running = false
			return
		case .F11:
			app.fullscreen = !app.fullscreen
			SDL.SetWindowFullscreen(app.window, SDL.WINDOW_FULLSCREEN_DESKTOP if app.fullscreen else {})
			return
		case .ESCAPE:
			paste_cancel(m) // Break also aborts a paste in progress
		}
	}
	if app.key_joy && is_joystick_key(sc) {
		keyboard_joystick_key(m, sc, down)
		return
	}
	machine_key_event(m, sc, down)
}

// Keyboard joystick: arrows move the right stick, Ctrl/Alt are its buttons.
joy_keys_down: [SDL.NUM_SCANCODES]bool

is_joystick_key :: proc(sc: SDL.Scancode) -> bool {
	#partial switch sc {
	case .UP, .DOWN, .LEFT, .RIGHT, .LCTRL, .LALT:
		return true
	}
	return false
}

keyboard_joystick_key :: proc(m: ^Machine, sc: SDL.Scancode, down: bool) {
	joy_keys_down[int(sc)] = down
	machine_set_button(m, BUTTON_RIGHT_1, joy_keys_down[int(SDL.Scancode.LCTRL)])
	machine_set_button(m, BUTTON_RIGHT_2, joy_keys_down[int(SDL.Scancode.LALT)])
}

keyboard_joystick :: proc(m: ^Machine, app: ^App) {
	x, y := STICK_MAX / 2, STICK_MAX / 2
	if joy_keys_down[int(SDL.Scancode.LEFT)] {x = 1}
	if joy_keys_down[int(SDL.Scancode.RIGHT)] {x = STICK_MAX}
	if joy_keys_down[int(SDL.Scancode.UP)] {y = 1}
	if joy_keys_down[int(SDL.Scancode.DOWN)] {y = STICK_MAX}
	machine_set_axis(m, .Right_X, x)
	machine_set_axis(m, .Right_Y, y)
}

keyboard_joystick_release :: proc(m: ^Machine) {
	joy_keys_down = {}
	machine_set_button(m, BUTTON_RIGHT_1 | BUTTON_RIGHT_2, false)
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
