package vcc

import "core:fmt"
import SDL "vendor:sdl2"

// Audio: the 6 bit DAC (PIA1 side A) plus the single bit sound line (PIA1 B
// bit 1) are sampled at AUDIO_RATE by a timing event (see driver.odin) into
// Machine.audio_samples, and queued to SDL once per frame.

AUDIO_RATE :: 44100

// Turn on sampling (disabled by default so headless runs and tests stay cheap).
machine_enable_audio :: proc(m: ^Machine, rate := AUDIO_RATE) {
	t := &m.timing
	t.snd_interval = NANOSECOND / f64(rate)
	t.nanos_to_snd = t.snd_interval
	t.snd_enable = true
	t.audio_event = audio_sample_event
}

audio_sample_event :: proc(m: ^Machine) {
	append(&m.audio_samples, dac_sample(m))
}

// Current output level as a stereo pair. The raw level (DAC + sound bit) << 7
// goes through a one-pole high-pass filter (about 10 Hz), like the coupling
// capacitor between a real CoCo and its speaker: a constant level reads as
// silence, so there is no pop when the program starts or when BASIC leaves
// the DAC at a non-zero value, and level changes become short thumps instead
// of lasting offsets. The filter starts at the current level, so it never
// produces a startup transient.
HP_COEFF :: 0.99858 // 1 - 2*pi*10/44100

dac_sample :: proc(m: ^Machine) -> [2]i16 {
	x := f32((int(m.asample) + int(m.ssample)) << 7)
	if !m.audio_hp_primed {
		m.audio_hp_primed = true
		m.audio_hp_x = x
		m.audio_hp_y = 0
	}
	y := x - m.audio_hp_x + HP_COEFF * m.audio_hp_y
	m.audio_hp_x = x
	m.audio_hp_y = y
	s := i16(clamp(y, -32768, 32767))
	return {s, s}
}

Audio_Out :: struct {
	dev:         SDL.AudioDeviceID,
	frame_bytes: u32, // size of one video frame of audio
	// diagnostics (--audio-stats)
	frames:      int,
	underruns:   int, // frames submitted to an empty queue (audible gap)
	dropped:     int, // frames discarded because the queue was far ahead
	min_queued:  u32,
	max_queued:  u32,
}

// Open the default output device in queue mode. ok is false if there is none.
audio_open :: proc() -> (a: Audio_Out, ok: bool) {
	want := SDL.AudioSpec {
		freq     = AUDIO_RATE,
		format   = SDL.AUDIO_S16LSB,
		channels = 2,
		samples  = 1024,
	}
	have: SDL.AudioSpec
	a.dev = SDL.OpenAudioDevice(nil, false, &want, &have, {})
	if a.dev == 0 {
		fmt.eprintln("audio disabled:", SDL.GetError())
		return {}, false
	}
	a.frame_bytes = u32(AUDIO_RATE / 60 * 4)
	SDL.PauseAudioDevice(a.dev, false)
	return a, true
}

// Ramp the output to silence over `ms` milliseconds so stopping the stream
// (pause) does not end on a click. Resuming re-primes the high-pass filter.
audio_fade_out :: proc(a: ^Audio_Out, m: ^Machine, ms := 10) {
	if a.dev == 0 {return}
	last := f32(0)
	if len(m.audio_samples) > 0 {
		last = f32(m.audio_samples[len(m.audio_samples) - 1].x)
	} else {
		last = m.audio_hp_y
	}
	n := AUDIO_RATE * ms / 1000
	ramp := make([][2]i16, n, context.temp_allocator)
	for i in 0 ..< n {
		v := i16(last * (1 - f32(i + 1) / f32(n)))
		ramp[i] = {v, v}
	}
	SDL.QueueAudio(a.dev, raw_data(ramp), u32(n * size_of([2]i16)))
	m.audio_hp_primed = false
}

audio_close :: proc(a: ^Audio_Out) {
	if a.dev != 0 {SDL.CloseAudioDevice(a.dev)}
	a.dev = 0
}

// Queue this frame's samples. Drops them if the device is already far ahead.
audio_submit :: proc(a: ^Audio_Out, m: ^Machine) {
	defer clear(&m.audio_samples)
	if a.dev == 0 || len(m.audio_samples) == 0 {return}
	queued := SDL.GetQueuedAudioSize(a.dev)
	a.frames += 1
	if a.frames == 1 || queued < a.min_queued {a.min_queued = queued}
	if queued > a.max_queued {a.max_queued = queued}
	if queued == 0 && a.frames > 1 {a.underruns += 1}
	if queued > a.frame_bytes * 6 {
		a.dropped += 1
		return
	}
	SDL.QueueAudio(a.dev, raw_data(m.audio_samples), u32(len(m.audio_samples) * size_of([2]i16)))
}

// True while the device still has plenty queued, so the main loop can wait and
// let the audio clock pace emulation.
audio_ahead :: proc(a: ^Audio_Out) -> bool {
	return a.dev != 0 && SDL.GetQueuedAudioSize(a.dev) > a.frame_bytes * 2
}

audio_print_stats :: proc(a: ^Audio_Out) {
	fmt.printfln(
		"audio: %d frames, %d underruns, %d dropped, queue min %d / max %d bytes (frame = %d)",
		a.frames, a.underruns, a.dropped, a.min_queued, a.max_queued, a.frame_bytes,
	)
}
