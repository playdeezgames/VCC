package vcc

import "core:testing"

// PIA1 set up like BASIC: side A bits 7-2 are outputs (DAC), B bit 1 is the sound bit.
audio_setup_pia :: proc(m: ^Machine) {
	mem_write8(m, 0xFF21, 0)
	mem_write8(m, 0xFF20, 0xFE)
	mem_write8(m, 0xFF21, 0x04)
	mem_write8(m, 0xFF23, 0)
	mem_write8(m, 0xFF22, 0xFE)
	mem_write8(m, 0xFF23, 0x0C) // data regs + sound enable (CB2 high)
}

park_cpu :: proc(m: ^Machine) {
	poke(m, 0x4000, {0x20, 0xFE})
	m.cpu.pc = 0x4000
}

@(test)
no_samples_when_audio_off :: proc(t: ^testing.T) {
	m := test_machine()
	defer test_machine_free(m)
	park_cpu(m)
	machine_run_frame(m)
	testing.expect_value(t, len(m.audio_samples), 0)
}

@(test)
samples_per_frame :: proc(t: ^testing.T) {
	m := test_machine()
	defer test_machine_free(m)
	park_cpu(m)
	machine_enable_audio(m)
	machine_run_frame(m)
	n := len(m.audio_samples)
	testing.expect(t, n >= 734 && n <= 737, "about 735 samples per 1/60 s frame")
	machine_run_frame(m)
	testing.expect(t, len(m.audio_samples) >= 1468 && len(m.audio_samples) <= 1472)
}

@(test)
dac_change_becomes_a_step :: proc(t: ^testing.T) {
	m := test_machine()
	defer test_machine_free(m)
	park_cpu(m)
	audio_setup_pia(m)
	machine_enable_audio(m)
	machine_run_frame(m) // DAC idle at 0: the filter starts here
	clear(&m.audio_samples)
	mem_write8(m, 0xFF20, 0xFC) // full scale (asample = 126)
	machine_run_frame(m)
	// the step passes through at its full height, then decays like a coupling capacitor
	first := int(m.audio_samples[0].x)
	testing.expect(t, first > 15000 && first <= 126 << 7, "step reaches the output")
	testing.expect(t, int(m.audio_samples[700].x) < first, "offset decays")
	clear(&m.audio_samples)
	mem_write8(m, 0xFF20, 0x00)
	machine_run_frame(m)
	testing.expect(t, m.audio_samples[0].x < -10000, "falling step is negative")
}

@(test)
constant_level_is_silence_with_no_startup_pop :: proc(t: ^testing.T) {
	m := test_machine()
	defer test_machine_free(m)
	park_cpu(m)
	audio_setup_pia(m)
	mem_write8(m, 0xFF20, 0xFC) // DAC already non-zero when audio starts
	machine_enable_audio(m)
	machine_run_frame(m)
	for s in m.audio_samples {
		if s.x != 0 {
			testing.expectf(t, false, "expected silence from the first sample, got %d", s.x)
			break
		}
	}
	// a constant level decays to nothing; here it never changed at all
	testing.expect_value(t, m.audio_samples[len(m.audio_samples) - 1], [2]i16{0, 0})
}

@(test)
offset_after_a_step_dies_away :: proc(t: ^testing.T) {
	m := test_machine()
	defer test_machine_free(m)
	park_cpu(m)
	audio_setup_pia(m)
	machine_enable_audio(m)
	machine_run_frame(m)
	clear(&m.audio_samples)
	mem_write8(m, 0xFF20, 0x80)
	for _ in 0 ..< 60 {machine_run_frame(m)} // one second
	clear(&m.audio_samples)
	machine_run_frame(m)
	// a held level must not stay audible as DC
	testing.expect(t, abs(int(m.audio_samples[100].x)) < 100, "settled")
	testing.expect(t, m.audio_hp_y == m.audio_hp_y, "finite") // NaN guard
}

@(test)
single_bit_sound_adds_to_output :: proc(t: ^testing.T) {
	m := test_machine()
	defer test_machine_free(m)
	park_cpu(m)
	audio_setup_pia(m)
	machine_enable_audio(m)
	machine_run_frame(m)
	clear(&m.audio_samples)
	mem_write8(m, 0xFF22, 0x02) // sound bit on
	machine_run_frame(m)
	first := int(m.audio_samples[0].x)
	testing.expect(t, first > 15000 && first <= 128 << 7, "single bit step")
}

@(test)
square_wave_from_cpu_program :: proc(t: ^testing.T) {
	m := test_machine()
	defer test_machine_free(m)
	audio_setup_pia(m)
	machine_enable_audio(m)
	// loop: LDA #$FC ; STA $FF20 ; CLRA ; STA $FF20 ; BRA loop
	poke(m, 0x4000, {0x86, 0xFC, 0xB7, 0xFF, 0x20, 0x4F, 0xB7, 0xFF, 0x20, 0x20, 0xF5})
	m.cpu.pc = 0x4000
	machine_run_frame(m)
	lo, hi := i16(32767), i16(-32768)
	for s in m.audio_samples {
		lo = min(lo, s.x)
		hi = max(hi, s.x)
	}
	testing.expect(t, hi - lo > 15000, "both DAC extremes were sampled")
}
