package vcc

// Frame/scanline driver and GIME timer (ports RenderFrame/HLINE/CPUCycle and
// the timer functions of coco3.cpp). Time is tracked in nanoseconds; the CPU
// is run in slices between timer-interrupt and audio-sample events, carrying
// fractional/overshoot cycles in cycle_drift.

TARGET_FRAME_RATE :: 60.0
FRAMES_PER_SECOND_REAL :: 59.923 // a real CoCo runs at about this rate
LINES_PER_SCREEN :: 262
NANOSECOND :: 1_000_000_000.0
COLORBURST :: 3579545.0
HSYNC_WIDTH_NS :: 5000.0

CYCLES_PER_SECOND :: (COLORBURST / 4) * (TARGET_FRAME_RATE / FRAMES_PER_SECOND_REAL)
LINES_PER_SECOND :: TARGET_FRAME_RATE * LINES_PER_SCREEN
NANOS_PER_LINE :: NANOSECOND / LINES_PER_SECOND
CYCLES_PER_LINE :: CYCLES_PER_SECOND / LINES_PER_SECOND

Timing :: struct {
	cycle_drift:         f64,
	nanos_this_line:     f64,

	// GIME timer. clock rate 0 = one scanline per tick, 1 = one colorburst tick.
	timer_clock_rate:    u8,
	timer_unxlated:      u32, // raw 12 bit counter value
	master_tick_counter: f64, // nanoseconds per timer period
	nanos_to_interrupt:  f64,
	int_enable:          bool,

	// Audio sample event (period 0 / disabled until audio is set up)
	snd_enable:          bool,
	snd_interval:        f64,
	nanos_to_snd:        f64,
	audio_event:         proc(m: ^Machine),

	overclock:           int, // CPU speed multiplier (1, or 2/4 in high speed)
	turbo:               int, // $FF96: 1 or 2
}

timing_reset :: proc(m: ^Machine) {
	t := &m.timing
	t.cycle_drift = 0
	t.nanos_this_line = 0
	t.timer_clock_rate = 0
	t.timer_unxlated = 0
	t.master_tick_counter = 0
	t.nanos_to_interrupt = 0
	t.int_enable = false
	t.nanos_to_snd = t.snd_interval
	t.turbo = 1
	setup_clock(m)
}

// CPU speed: 0.894MHz, doubled by the SAM "R1" poke, doubled again by turbo.
setup_clock :: proc(m: ^Machine) {
	t := &m.timing
	t.overclock = 1
	if m.cpu_fast_ram {
		t.overclock = 2 * t.turbo
	}
}

set_turbo :: proc(m: ^Machine, data: u8) {
	m.timing.turbo = int(data & 1) + 1
	setup_clock(m)
}

// ---------------------------------------------------------------- GIME timer

// Setup the period from the 12 bit counter value and the current clock rate.
timer_set_master :: proc(m: ^Machine, value: u32) {
	t := &m.timing
	t.timer_unxlated = value & 0xFFF
	t.int_enable = t.timer_unxlated > 0
	rate := [2]f64{NANOSECOND / (TARGET_FRAME_RATE * LINES_PER_SCREEN), NANOSECOND / COLORBURST}
	timer_offset := f64(1) // GIME 1987: the master count holds at least one tick
	t.master_tick_counter = rate[t.timer_clock_rate] * (f64(t.timer_unxlated) + timer_offset)
}

// Restart the timer with a new value (write to $FF94). Zero is handled by the caller.
timer_restart :: proc(m: ^Machine, value: u32) {
	timer_set_master(m, value)
	if m.timing.int_enable {
		m.timing.nanos_to_interrupt = m.timing.master_tick_counter
	}
}

timer_set_clock_rate :: proc(m: ^Machine, rate: u8) {
	r := u8(1) if rate != 0 else 0
	if m.timing.timer_clock_rate == r {return}
	m.timing.timer_clock_rate = r
	timer_restart(m, m.timing.timer_unxlated)
}

// ---------------------------------------------------------------- CPU slicing

// Run the CPU for the cycles that fit in `ns` nanoseconds.
run_cpu_ns :: proc(m: ^Machine, ns: f64) {
	t := &m.timing
	cycles := t.cycle_drift + ns * CYCLES_PER_LINE * f64(t.overclock) / NANOS_PER_LINE
	if cycles >= 1 {
		n := int(cycles)
		over := cpu_exec(&m.cpu, n) // cycles run beyond the budget (0 in SYNC)
		t.cycle_drift = -f64(over) + (cycles - f64(n))
	} else {
		t.cycle_drift = cycles
	}
}

// Advance emulated time by `nanos`, firing timer and audio events in order.
cpu_cycle :: proc(m: ^Machine, nanos: f64) {
	t := &m.timing
	t.nanos_this_line += nanos
	for t.nanos_this_line >= 1 {
		timer_due := t.int_enable && t.nanos_to_interrupt <= t.nanos_this_line
		snd_due := t.snd_enable && t.nanos_to_snd <= t.nanos_this_line
		step := t.nanos_this_line
		fire_timer, fire_snd := false, false
		switch {
		case timer_due && snd_due:
			if t.nanos_to_snd < t.nanos_to_interrupt {
				step, fire_snd = t.nanos_to_snd, true
			} else if t.nanos_to_snd > t.nanos_to_interrupt {
				step, fire_timer = t.nanos_to_interrupt, true
			} else {
				step, fire_timer, fire_snd = t.nanos_to_interrupt, true, true
			}
		case timer_due:
			step, fire_timer = t.nanos_to_interrupt, true
		case snd_due:
			step, fire_snd = t.nanos_to_snd, true
		}
		if step < 0 {step = 0}

		run_cpu_ns(m, step)
		t.nanos_this_line -= step
		t.nanos_to_interrupt -= step
		t.nanos_to_snd -= step

		if fire_timer {
			gime_assert_timer(m)
			t.nanos_to_interrupt = t.master_tick_counter
		}
		if fire_snd {
			if t.audio_event != nil {t.audio_event(m)}
			t.nanos_to_snd = t.snd_interval
		}
	}
}

// ---------------------------------------------------------------- scanlines

hsync :: proc(m: ^Machine, level: int) {
	if level == 0 {
		gime_assert_hsync(m)
		irq_hs(m, .Falling)
		fdc_ping(m)
	} else {
		irq_hs(m, .Rising)
	}
}

vsync :: proc(m: ^Machine, level: int) {
	if level == 0 {
		irq_fs(m, .Falling)
		gime_assert_vsync(m)
	} else {
		irq_fs(m, .Rising)
	}
}

// One scanline: run the CPU, with HSYNC low for the last few microseconds.
hline :: proc(m: ^Machine) {
	cpu_cycle(m, NANOS_PER_LINE - HSYNC_WIDTH_NS)
	hsync(m, 0)
	cpu_cycle(m, HSYNC_WIDTH_NS)
	hsync(m, 1)
}

// Run one 262-line frame. The video hooks draw into the framebuffer.
machine_run_frame :: proc(m: ^Machine) {
	v := video_geometry(m)

	vsync(m, 0)
	for _ in 0 ..< 4 {hline(m)} // VSYNC low
	vsync(m, 1)
	for _ in 0 ..< 3 {hline(m)}
	for _ in 0 ..< v.top_offscreen {hline(m)}

	video_begin_frame(m)
	for line in 0 ..< v.top_border {
		hline(m)
		video_draw_line(m, .Top_Border, line)
	}
	for line in 0 ..< v.active_lines {
		hline(m)
		video_draw_line(m, .Active, line)
	}
	for line in 0 ..< v.bottom_border {
		hline(m)
		video_draw_line(m, .Bottom_Border, line)
	}
	video_end_frame(m)

	for _ in 0 ..< v.bottom_offscreen {hline(m)}
}
