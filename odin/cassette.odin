package vcc

import "core:os"

// Cassette recorder. The tape is a mono WAV file. While the motor runs
// (PIA1 CA2, $FF21 bit 3) the tape position advances in emulated time:
//
//   playing    PIA1 $FF20 bit 0 follows the audio (above/below the middle)
//   recording  every change of the DAC while it feeds the cassette output
//              (mux on the sound source, CB2 low) is remembered with its tape
//              time and written out as an 8 bit WAV when the motor stops or
//              the machine shuts down.
//
// Time is the machine's emulated time (Timing.elapsed_ns plus the cycles of
// the running slice), so a program that measures the edges sees the same
// durations the real tape would give. CAS files are not supported (backlog).

TAPE_MID :: 128
TAPE_HYSTERESIS :: 6
TAPE_REC_RATE :: 44100

Tape_Event :: struct {
	ns:    f64,
	level: u8,
}

Tape :: struct {
	samples:    []u8, // playback: 8 bit unsigned mono, nil = no tape
	rate:       int,
	pos_ns:     f64, // tape position, advances only while the motor runs
	last_ns:    f64, // emulated time of the last sync
	level:      u8, // comparator output (0/1) with hysteresis
	rec_path:   string, // "" = not recording
	events:     [dynamic]Tape_Event,
	dirty:      bool, // events not yet written
}

// Emulated time now, in nanoseconds: finished slices plus the cycles run so far
// in the current one.
emu_now_ns :: proc(m: ^Machine) -> f64 {
	t := &m.timing
	return t.elapsed_ns + f64(m.cpu.cycles) * NANOS_PER_LINE / CYCLES_PER_LINE / f64(max(t.overclock, 1))
}

// Bring the tape position up to date.
tape_sync :: proc(m: ^Machine) {
	tp := &m.tape
	now := emu_now_ns(m)
	if m.cass_motor && now > tp.last_ns {tp.pos_ns += now - tp.last_ns}
	tp.last_ns = now
}

// Mount a WAV file for playback (rewound). 8 or 16 bit PCM, first channel used.
tape_play :: proc(m: ^Machine, path: string) -> bool {
	data, err := os.read_entire_file(path, context.allocator)
	if err != nil {return false}
	defer delete(data)
	samples, rate, ok := wav_decode(data)
	if !ok {return false}
	tape_eject(m)
	tp := &m.tape
	tp.samples = samples
	tp.rate = rate
	tp.pos_ns = 0
	tp.last_ns = emu_now_ns(m)
	tp.level = 0
	return true
}

// Record to `path` (created when the motor first stops, rewritten on each stop).
tape_record_to :: proc(m: ^Machine, path: string) {
	tp := &m.tape
	tp.rec_path = path
	clear(&tp.events)
	tp.pos_ns = 0
	tp.last_ns = emu_now_ns(m)
	tp.dirty = false
}

tape_eject :: proc(m: ^Machine) {
	tape_flush(m)
	tp := &m.tape
	delete(tp.samples)
	tp.samples = nil
	tp.rec_path = ""
	clear(&tp.events)
}

tape_close :: proc(m: ^Machine) {
	tape_eject(m)
	delete(m.tape.events)
	m.tape.events = nil
}

// The motor relay (PIA1 CA2) changed.
tape_motor :: proc(m: ^Machine, on: bool) {
	if on == m.cass_motor {return}
	tape_sync(m) // account for the time spent in the old state
	m.cass_motor = on
	if !on {tape_flush(m)}
}

// The DAC value reaching the cassette output changed.
tape_note_output :: proc(m: ^Machine) {
	tp := &m.tape
	if tp.rec_path == "" || !m.cass_motor {return}
	tape_sync(m)
	if len(tp.events) > 0 && tp.events[len(tp.events) - 1].level == m.csample {return}
	append(&tp.events, Tape_Event{tp.pos_ns, m.csample})
	tp.dirty = true
}

// Comparator output for PIA1 $FF20 bit 0.
tape_level :: proc(m: ^Machine) -> u8 {
	tp := &m.tape
	if tp.samples == nil {return 0}
	tape_sync(m)
	idx := int(tp.pos_ns * f64(tp.rate) / 1e9)
	if idx < 0 || idx >= len(tp.samples) {
		tp.level = 0
		return 0
	}
	s := int(tp.samples[idx])
	if s > TAPE_MID + TAPE_HYSTERESIS {
		tp.level = 1
	} else if s < TAPE_MID - TAPE_HYSTERESIS {
		tp.level = 0
	}
	return tp.level
}

tape_flush :: proc(m: ^Machine) {
	tp := &m.tape
	if tp.rec_path == "" || !tp.dirty || len(tp.events) == 0 {return}
	end_ns := tp.events[len(tp.events) - 1].ns + 100e6
	n := int(end_ns * TAPE_REC_RATE / 1e9)
	out := make([]u8, n)
	defer delete(out)
	ev := 0
	cur := u8(TAPE_MID)
	for i in 0 ..< n {
		t := f64(i) * 1e9 / TAPE_REC_RATE
		for ev < len(tp.events) && tp.events[ev].ns <= t {
			cur = tp.events[ev].level
			ev += 1
		}
		out[i] = cur
	}
	file := wav_encode(out, TAPE_REC_RATE)
	defer delete(file)
	if os.write_entire_file(tp.rec_path, file) == nil {tp.dirty = false}
}

// ---------------------------------------------------------------- WAV

wav_u16 :: proc(d: []u8, i: int) -> int {return int(d[i]) | int(d[i + 1]) << 8}
wav_u32 :: proc(d: []u8, i: int) -> int {return wav_u16(d, i) | wav_u16(d, i + 2) << 16}

// 8 bit unsigned samples of the first channel and the sample rate.
wav_decode :: proc(d: []u8) -> (samples: []u8, rate: int, ok: bool) {
	if len(d) < 12 || string(d[0:4]) != "RIFF" || string(d[8:12]) != "WAVE" {return}
	channels, bits, format := 0, 0, 0
	pos := 12
	for pos + 8 <= len(d) {
		size := wav_u32(d, pos + 4)
		body := pos + 8
		switch string(d[pos:pos + 4]) {
		case "fmt ":
			if size < 16 || body + 16 > len(d) {return}
			format = wav_u16(d, body)
			channels = wav_u16(d, body + 2)
			rate = wav_u32(d, body + 4)
			bits = wav_u16(d, body + 14)
		case "data":
			if format != 1 || channels < 1 || rate <= 0 || (bits != 8 && bits != 16) {return}
			size = min(size, len(d) - body)
			frame := channels * bits / 8
			n := size / frame
			samples = make([]u8, n)
			for i in 0 ..< n {
				p := body + i * frame
				if bits == 8 {
					samples[i] = d[p]
				} else {
					v := int(i16(wav_u16(d, p))) // signed 16 bit
					samples[i] = u8((v >> 8) + 128)
				}
			}
			return samples, rate, true
		}
		pos = body + size + size & 1
	}
	return
}

wav_encode :: proc(samples: []u8, rate: int) -> []u8 {
	n := len(samples)
	out := make([]u8, 44 + n)
	put32 :: proc(o: []u8, i, v: int) {
		for k in 0 ..< 4 {o[i + k] = u8(v >> uint(8 * k))}
	}
	put16 :: proc(o: []u8, i, v: int) {
		o[i] = u8(v)
		o[i + 1] = u8(v >> 8)
	}
	copy(out[0:], "RIFF")
	put32(out, 4, 36 + n)
	copy(out[8:], "WAVEfmt ")
	put32(out, 16, 16)
	put16(out, 20, 1) // PCM
	put16(out, 22, 1) // mono
	put32(out, 24, rate)
	put32(out, 28, rate) // bytes per second
	put16(out, 32, 1) // block align
	put16(out, 34, 8) // bits
	copy(out[36:], "data")
	put32(out, 40, n)
	copy(out[44:], samples)
	return out
}
