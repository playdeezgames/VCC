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

// Current output level as a stereo pair. VCC outputs the unsigned level
// (DAC + sound bit) << 7; it is centred here so the output has no DC offset.
dac_sample :: proc(m: ^Machine) -> [2]i16 {
	level := (int(m.asample) + int(m.ssample)) << 7
	s := i16(level - 16384)
	return {s, s}
}

Audio_Out :: struct {
	dev:         SDL.AudioDeviceID,
	frame_bytes: u32, // size of one video frame of audio
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

audio_close :: proc(a: ^Audio_Out) {
	if a.dev != 0 {SDL.CloseAudioDevice(a.dev)}
	a.dev = 0
}

// Queue this frame's samples. Drops them if the device is already far ahead.
audio_submit :: proc(a: ^Audio_Out, m: ^Machine) {
	defer clear(&m.audio_samples)
	if a.dev == 0 || len(m.audio_samples) == 0 {return}
	if SDL.GetQueuedAudioSize(a.dev) > a.frame_bytes * 6 {return}
	SDL.QueueAudio(a.dev, raw_data(m.audio_samples), u32(len(m.audio_samples) * size_of([2]i16)))
}

// True while the device still has plenty queued, so the main loop can wait and
// let the audio clock pace emulation.
audio_ahead :: proc(a: ^Audio_Out) -> bool {
	return a.dev != 0 && SDL.GetQueuedAudioSize(a.dev) > a.frame_bytes * 2
}
