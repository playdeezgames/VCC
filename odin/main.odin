package vcc

import "core:fmt"
import "core:os"
import "core:strings"
import "core:time"
import SDL "vendor:sdl2"
import "disk"

SCREEN_W :: 640
SCREEN_H :: 480

main :: proc() {
	rom_path := ""
	cart_path := ""
	dump_frame := -1
	text_dump := false
	mute := false
	audio_stats := false
	startup_text := ""
	startup_file := ""
	dump_mem := ""
	no_video := false
	paste_keys := false // type via the keyboard matrix instead of the ROM hook
	disk_paths: [4]string
	new_disk := ""
	tape_in := ""
	tape_out := ""
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
		case "--audio-stats":
			audio_stats = true
		case "--paste-file":
			// type the contents of a text file at startup (e.g. a BASIC listing)
			i += 1
			if i < len(args) {startup_file = args[i]}
		case "--paste-keys":
			paste_keys = true
		case "--no-video":
			no_video = true // headless: skip rendering (much faster)
		case "--dump-mem":
			// headless: write the 64K CPU address space to a file at the end
			i += 1
			if i < len(args) {dump_mem = args[i]}
		case "--paste-timing":
			// --paste-timing down,up,enter  (frames); default 3,3,25
			i += 1
			if i < len(args) {
				parts := strings.split(args[i], ",", context.temp_allocator)
				if len(parts) == 3 {
					paste_down_frames = parse_int(parts[0])
					paste_up_frames = parse_int(parts[1])
					paste_enter_frames = parse_int(parts[2])
				}
			}
		case "--paste-fast":
			// 2 frames per key instead of 6; fine for the real ROM, used for long listings
			paste_down_frames, paste_up_frames, paste_enter_frames = 2, 2, 8
		case "--paste":
			// type text at startup; \n in the argument is an Enter key
			i += 1
			if i < len(args) {startup_text, _ = strings.replace_all(args[i], "\\n", "\n")}
		case "--disk0", "--disk1", "--disk2", "--disk3":
			n := int(args[i][6] - '0')
			i += 1
			if i < len(args) {disk_paths[n] = args[i]}
		case "--tape":
			i += 1
			if i < len(args) {tape_in = args[i]}
		case "--tape-out":
			i += 1
			if i < len(args) {tape_out = args[i]}
		case "--new-disk":
			i += 1
			if i < len(args) {new_disk = args[i]}
		}
	}
	if rom_path == "" {
		fmt.eprintln("usage: vcc --rom <coco3.rom> [--cart <disk11.rom>] [--disk0..--disk3 <image.dsk>] [--new-disk <file.dsk>] [--tape <in.wav>] [--tape-out <out.wav>] [--mute] [--dump-frame N [--text-dump]]")
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
		m.fdc.enabled = true // a disk ROM implies the FD-502 controller
	}
	machine_reset(m)
	if new_disk != "" {
		if err := disk.create_blank(new_disk); err != .None && err != .Exists {
			fmt.eprintfln("cannot create %q: %s", new_disk, disk.error_text(err))
			os.exit(1)
		}
		disk_paths[0] = new_disk
	}
	if tape_in != "" && !tape_play(m, tape_in) {
		fmt.eprintfln("cannot load tape %q (need a PCM WAV file)", tape_in)
		os.exit(1)
	}
	if tape_out != "" {tape_record_to(m, tape_out)}
	for path, drive in disk_paths {
		if path == "" {continue}
		if err := fdc_mount(m, drive, path); err != .None {
			fmt.eprintfln("cannot mount %q in drive %d: %s", path, drive, disk.error_text(err))
			os.exit(1)
		}
	}

	framebuffer := make([]u32, SCREEN_W * SCREEN_H)
	defer delete(framebuffer)
	if !no_video {m.fb = framebuffer}

	if startup_file != "" {
		data, ferr := os.read_entire_file(startup_file, context.allocator)
		if ferr != nil {
			fmt.eprintfln("cannot read %q", startup_file)
			os.exit(1)
		}
		startup_text = string(data)
	}

	// Headless: run N frames, dump, exit (no window).
	if dump_frame >= 0 {
		pasted_at := -1
		for f in 0 ..< dump_frame {
			if f == 150 && startup_text != "" {
				if paste_keys {paste_text(m, startup_text)} else {rom_paste_text(m, startup_text)}
				pasted_at = f
			}
			paste_step(m)
			machine_run_frame(m)
			// stop once the typing is done and BASIC has had time to finish the last line
			if pasted_at >= 0 && !paste_active(m) && !rom_paste_active(m) {
				if pasted_at == 150 {pasted_at = f} // first idle frame
				if f - pasted_at > 600 {break}
			}
		}
		fmt.printfln("pc=%04X cc=%02X a=%02X b=%02X x=%04X s=%04X", m.cpu.pc, get_cc(&m.cpu), m.cpu.a, m.cpu.b, m.cpu.x, m.cpu.s)
		if text_dump {dump_text_screen(m)}
		if dump_mem != "" {
			mem := make([]u8, 65536, context.temp_allocator)
			for a in 0 ..< 65536 {mem[a] = mem_read8(m, u16(a))}
			_ = os.write_entire_file(dump_mem, mem)
		}
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
	defer if audio_ok {
		if audio_stats {audio_print_stats(&audio)}
		audio_close(&audio)
	}

	startup_wait := 150 // frames for BASIC to reach its prompt before typing
	frame_time := time.Second / 60
	next := time.tick_now()
	app := App{running = true, window = window}
	if audio_ok {app.audio = &audio}
	last_title: string
	defer delete(last_title)
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
			case .DROPFILE:
				// Drop a disk image on the window: drive 0, or drive 1 with Shift held.
				drive := 1 if SDL.GetModState() & SDL.KMOD_SHIFT != {} else 0
				path := string(e.drop.file)
				if strings.has_suffix(strings.to_lower(path, context.temp_allocator), ".wav") {
					// a tape: play from the start when the motor runs
					if !tape_play(m, path) {fmt.eprintfln("cannot load tape %q", path)}
				} else if err := fdc_mount(m, drive, path); err != .None {
					fmt.eprintfln("cannot mount %q: %s", path, disk.error_text(err))
				}
				SDL.free(rawptr(e.drop.file))
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

		if startup_text != "" {
			startup_wait -= 1
			if startup_wait == 0 {paste_text(m, startup_text)}
		}
		if !app.paused {
			paste_step(m)
			machine_run_frame(m)
			if audio_ok {audio_submit(&audio, m)}
		}

		update_title(window, m, &last_title)

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

// Window title: base name plus the floppy status while the drive motor runs.
update_title :: proc(window: ^SDL.Window, m: ^Machine, last: ^string) {
	base := "VCC (Odin)"
	title := base
	if st := fdc_status_text(m); st != "" {
		title = fmt.tprintf("%s - %s", base, st)
	}
	if title == last^ {return}
	delete(last^)
	last^ = strings.clone(title)
	SDL.SetWindowTitle(window, strings.clone_to_cstring(title, context.temp_allocator))
}

App :: struct {
	running:    bool,
	paused:     bool,
	fullscreen: bool,
	key_joy:    bool, // arrow keys / Ctrl / Alt drive the right joystick
	window:     ^SDL.Window,
	audio:      ^Audio_Out, // nil when audio is off
}

// Host hotkeys:  F3 flip artifact colors   F4 eject disk (Shift: drive 1)   F5 RGB/composite monitor   F6 pause   F7 paste clipboard   F8 keyboard joystick
//                F9 soft reset   F10 quit   F11 fullscreen
handle_key :: proc(m: ^Machine, app: ^App, sc: SDL.Scancode, down: bool) {
	if down {
		#partial switch sc {
		case .F3:
			m.artifact_flip = !m.artifact_flip // swap PMODE 4 blue/orange phase
			return
		case .F4:
			// eject drive 0 (Shift: drive 1)
			fdc_eject(m, 1 if SDL.GetModState() & SDL.KMOD_SHIFT != {} else 0)
			return
		case .F5:
			m.monitor_rgb = !m.monitor_rgb // composite <-> RGB monitor colors
			return
		case .F6:
			app.paused = !app.paused
			if app.paused && app.audio != nil {audio_fade_out(app.audio, m)}
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
