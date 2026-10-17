package vcc

import "core:testing"

Test_Rig :: struct {
	cpu: CPU6809,
	ram: [65536]u8,
}

rig_read :: proc(ctx: rawptr, addr: u16) -> u8 {
	return (^Test_Rig)(ctx).ram[addr]
}

rig_write :: proc(ctx: rawptr, addr: u16, val: u8) {
	(^Test_Rig)(ctx).ram[addr] = val
}

// Rig with `prog` loaded at $0200 and PC pointing there.
rig_make :: proc(r: ^Test_Rig, prog: []u8) {
	r.cpu.bus = {r, rig_read, rig_write}
	for b, i in prog {r.ram[0x200 + i] = b}
	r.ram[0xFFFE] = 0x02 // reset vector -> $0200
	r.ram[0xFFFF] = 0x00
	cpu_reset(&r.cpu)
	r.cpu.s = 0x8000
	r.cpu.u = 0x9000
}

// Run n instructions, returning total cycles.
rig_run :: proc(r: ^Test_Rig, n: int) -> int {
	total := 0
	for _ in 0 ..< n {
		cpu_exec(&r.cpu, 1)
		total += r.cpu.cycles
	}
	return total
}

@(test)
reset_loads_vector :: proc(t: ^testing.T) {
	r: Test_Rig
	rig_make(&r, {0x12})
	testing.expect_value(t, r.cpu.pc, 0x0200)
	testing.expect(t, flag(&r.cpu, .I) && flag(&r.cpu, .F))
}

@(test)
load_store_flags :: proc(t: ^testing.T) {
	r: Test_Rig
	// LDA #$80 ; STA $0300 ; LDB #0
	rig_make(&r, {0x86, 0x80, 0xB7, 0x03, 0x00, 0xC6, 0x00})
	cyc := rig_run(&r, 3)
	testing.expect_value(t, r.cpu.a, 0x80)
	testing.expect_value(t, r.ram[0x300], 0x80)
	testing.expect(t, flag(&r.cpu, .Z)) // from LDB #0
	testing.expect(t, !flag(&r.cpu, .N))
	testing.expect_value(t, cyc, 2 + 5 + 2)
}

@(test)
add_overflow_halfcarry :: proc(t: ^testing.T) {
	r: Test_Rig
	// LDA #$7F ; ADDA #$01
	rig_make(&r, {0x86, 0x7F, 0x8B, 0x01})
	rig_run(&r, 2)
	testing.expect_value(t, r.cpu.a, 0x80)
	testing.expect(t, flag(&r.cpu, .V))
	testing.expect(t, flag(&r.cpu, .N))
	testing.expect(t, flag(&r.cpu, .H))
	testing.expect(t, !flag(&r.cpu, .C))
}

@(test)
add_carry_chain :: proc(t: ^testing.T) {
	r: Test_Rig
	// LDA #$FF ; ADDA #$01 ; ADCA #$00
	rig_make(&r, {0x86, 0xFF, 0x8B, 0x01, 0x89, 0x00})
	rig_run(&r, 2)
	testing.expect_value(t, r.cpu.a, 0x00)
	testing.expect(t, flag(&r.cpu, .C) && flag(&r.cpu, .Z))
	rig_run(&r, 1)
	testing.expect_value(t, r.cpu.a, 0x01)
	testing.expect(t, !flag(&r.cpu, .C))
}

@(test)
sub_cmp_borrow :: proc(t: ^testing.T) {
	r: Test_Rig
	// LDA #$10 ; SUBA #$20 ; CMPA #$F0
	rig_make(&r, {0x86, 0x10, 0x80, 0x20, 0x81, 0xF0})
	rig_run(&r, 2)
	testing.expect_value(t, r.cpu.a, 0xF0)
	testing.expect(t, flag(&r.cpu, .C) && flag(&r.cpu, .N))
	rig_run(&r, 1)
	testing.expect_value(t, r.cpu.a, 0xF0) // CMP keeps A
	testing.expect(t, flag(&r.cpu, .Z))
}

@(test)
sub_signed_overflow :: proc(t: ^testing.T) {
	r: Test_Rig
	// LDA #$80 ; SUBA #$01 -> $7F, V set
	rig_make(&r, {0x86, 0x80, 0x80, 0x01})
	rig_run(&r, 2)
	testing.expect_value(t, r.cpu.a, 0x7F)
	testing.expect(t, flag(&r.cpu, .V))
}

@(test)
neg_com_shifts :: proc(t: ^testing.T) {
	r: Test_Rig
	// LDA #$80 ; NEGA ; LDA #$55 ; COMA ; LDB #$81 ; ASLB ; LDA #$01 ; RORA
	rig_make(&r, {0x86, 0x80, 0x40, 0x86, 0x55, 0x43, 0xC6, 0x81, 0x58, 0x86, 0x01, 0x46})
	rig_run(&r, 2)
	testing.expect_value(t, r.cpu.a, 0x80)
	testing.expect(t, flag(&r.cpu, .V) && flag(&r.cpu, .C))
	rig_run(&r, 2)
	testing.expect_value(t, r.cpu.a, 0xAA)
	testing.expect(t, flag(&r.cpu, .C) && !flag(&r.cpu, .V))
	rig_run(&r, 2)
	testing.expect_value(t, r.cpu.b, 0x02)
	testing.expect(t, flag(&r.cpu, .C))
	testing.expect(t, flag(&r.cpu, .V) == true) // bit7 ^ bit6 of $81 = 1
	rig_run(&r, 2)
	testing.expect_value(t, r.cpu.a, 0x80) // carry (set by ASLB) rotated into bit 7
	testing.expect(t, flag(&r.cpu, .C))
}

@(test)
inc_dec_overflow :: proc(t: ^testing.T) {
	r: Test_Rig
	// LDA #$7F ; INCA ; LDB #$80 ; DECB
	rig_make(&r, {0x86, 0x7F, 0x4C, 0xC6, 0x80, 0x5A})
	rig_run(&r, 2)
	testing.expect(t, flag(&r.cpu, .V) && flag(&r.cpu, .N))
	rig_run(&r, 2)
	testing.expect_value(t, r.cpu.b, 0x7F)
	testing.expect(t, flag(&r.cpu, .V))
}

@(test)
mul_sex_abx :: proc(t: ^testing.T) {
	r: Test_Rig
	// LDA #$0C ; LDB #$64 ; MUL ; LDB #$80 ; SEX ; LDX #$1000 ; ABX
	rig_make(&r, {0x86, 0x0C, 0xC6, 0x64, 0x3D, 0xC6, 0x80, 0x1D, 0x8E, 0x10, 0x00, 0x3A})
	cyc := rig_run(&r, 3)
	testing.expect_value(t, get_d(&r.cpu), 1200)
	testing.expect_value(t, cyc, 2 + 2 + 11)
	rig_run(&r, 2)
	testing.expect_value(t, get_d(&r.cpu), 0xFF80)
	testing.expect(t, flag(&r.cpu, .N))
	rig_run(&r, 2)
	testing.expect_value(t, r.cpu.x, 0x1080) // B is $80, unsigned add
}

@(test)
daa_bcd :: proc(t: ^testing.T) {
	r: Test_Rig
	// LDA #$19 ; ADDA #$28 ; DAA  -> 19+28 = 47
	rig_make(&r, {0x86, 0x19, 0x8B, 0x28, 0x19})
	rig_run(&r, 3)
	testing.expect_value(t, r.cpu.a, 0x47)
	testing.expect(t, !flag(&r.cpu, .C))
}

@(test)
daa_carry :: proc(t: ^testing.T) {
	r: Test_Rig
	// LDA #$99 ; ADDA #$01 ; DAA -> 00 carry
	rig_make(&r, {0x86, 0x99, 0x8B, 0x01, 0x19})
	rig_run(&r, 3)
	testing.expect_value(t, r.cpu.a, 0x00)
	testing.expect(t, flag(&r.cpu, .C))
}

@(test)
sixteen_bit_ops :: proc(t: ^testing.T) {
	r: Test_Rig
	// LDD #$1234 ; ADDD #$00FF ; SUBD #$0100 ; STD $0300 ; LDX $0300 ; CMPX #$1233
	rig_make(&r, {0xCC, 0x12, 0x34, 0xC3, 0x00, 0xFF, 0x83, 0x01, 0x00, 0xFD, 0x03, 0x00, 0xBE, 0x03, 0x00, 0x8C, 0x12, 0x33})
	rig_run(&r, 2)
	testing.expect_value(t, get_d(&r.cpu), 0x1333)
	rig_run(&r, 1)
	testing.expect_value(t, get_d(&r.cpu), 0x1233)
	rig_run(&r, 1)
	testing.expect_value(t, r.ram[0x300], 0x12)
	testing.expect_value(t, r.ram[0x301], 0x33)
	rig_run(&r, 2)
	testing.expect_value(t, r.cpu.x, 0x1233)
	testing.expect(t, flag(&r.cpu, .Z) && !flag(&r.cpu, .C)) // CMPX #$1233 with X=$1233
}

@(test)
tfr_exg :: proc(t: ^testing.T) {
	r: Test_Rig
	// LDX #$1234 ; TFR X,Y ; LDA #$11 ; LDB #$22 ; EXG A,B ; EXG X,D
	rig_make(&r, {0x8E, 0x12, 0x34, 0x1F, 0x12, 0x86, 0x11, 0xC6, 0x22, 0x1E, 0x89, 0x1E, 0x10})
	rig_run(&r, 2)
	testing.expect_value(t, r.cpu.y, 0x1234)
	rig_run(&r, 3)
	testing.expect_value(t, r.cpu.a, 0x22)
	testing.expect_value(t, r.cpu.b, 0x11)
	rig_run(&r, 1)
	testing.expect_value(t, r.cpu.x, 0x2211)
	testing.expect_value(t, get_d(&r.cpu), 0x1234)
}

@(test)
branches :: proc(t: ^testing.T) {
	r: Test_Rig
	// LDA #0 ; BEQ +2 ; LDA #1 ; NOP ; BNE +2 ; LDB #5 ; NOP
	rig_make(&r, {0x86, 0x00, 0x27, 0x02, 0x86, 0x01, 0x12, 0x26, 0x02, 0xC6, 0x05})
	rig_run(&r, 2) // LDA, BEQ taken -> skips LDA #1
	testing.expect_value(t, r.cpu.pc, 0x0206)
	rig_run(&r, 2) // NOP, BNE not taken (Z set from LDA #0)
	testing.expect_value(t, r.cpu.pc, 0x0209)
	rig_run(&r, 1)
	testing.expect_value(t, r.cpu.b, 5)
	testing.expect_value(t, r.cpu.a, 0)
}

@(test)
backward_loop :: proc(t: ^testing.T) {
	r: Test_Rig
	// LDB #3 ; loop: DECB ; BNE loop
	rig_make(&r, {0xC6, 0x03, 0x5A, 0x26, 0xFD})
	rig_run(&r, 1 + 3 * 2)
	testing.expect_value(t, r.cpu.b, 0)
	testing.expect_value(t, r.cpu.pc, 0x0205)
}

@(test)
long_branches :: proc(t: ^testing.T) {
	r: Test_Rig
	// LBRA +$0100 ; at $0303: LBEQ not taken, LBNE taken
	rig_make(&r, {0x16, 0x01, 0x00})
	r.ram[0x303] = 0x10; r.ram[0x304] = 0x27; r.ram[0x305] = 0x00; r.ram[0x306] = 0x10 // LBEQ +$0010
	r.ram[0x307] = 0x10; r.ram[0x308] = 0x26; r.ram[0x309] = 0x00; r.ram[0x30A] = 0x20 // LBNE +$0020
	cyc := rig_run(&r, 1)
	testing.expect_value(t, r.cpu.pc, 0x0303)
	testing.expect_value(t, cyc, 5)
	cyc = rig_run(&r, 1) // Z clear after reset: LBEQ not taken
	testing.expect_value(t, r.cpu.pc, 0x0307)
	testing.expect_value(t, cyc, 5)
	cyc = rig_run(&r, 1) // LBNE taken
	testing.expect_value(t, r.cpu.pc, 0x030B + 0x20)
	testing.expect_value(t, cyc, 6)
}

@(test)
jsr_bsr_rts :: proc(t: ^testing.T) {
	r: Test_Rig
	// BSR +2 ; NOP ; (target) LDA #9 ; RTS ; ...
	rig_make(&r, {0x8D, 0x01, 0x12, 0x86, 0x09, 0x39})
	// layout: 200 BSR+1 -> target = 0202+1 = 0203 (LDA #9), 205 RTS; return to 0202 (NOP)
	cyc := rig_run(&r, 1)
	testing.expect_value(t, r.cpu.pc, 0x0203)
	testing.expect_value(t, r.cpu.s, 0x7FFE)
	testing.expect_value(t, cyc, 7)
	rig_run(&r, 2) // LDA, RTS
	testing.expect_value(t, r.cpu.a, 9)
	testing.expect_value(t, r.cpu.pc, 0x0202)
	testing.expect_value(t, r.cpu.s, 0x8000)
}

@(test)
jsr_extended_jmp :: proc(t: ^testing.T) {
	r: Test_Rig
	// JSR $0300 ; at $0300: JMP $0400
	rig_make(&r, {0xBD, 0x03, 0x00})
	r.ram[0x300] = 0x7E; r.ram[0x301] = 0x04; r.ram[0x302] = 0x00
	cyc := rig_run(&r, 1)
	testing.expect_value(t, cyc, 8)
	testing.expect_value(t, r.cpu.pc, 0x0300)
	testing.expect_value(t, r.ram[0x7FFF], 0x03) // lsb of return address $0203
	testing.expect_value(t, r.ram[0x7FFE], 0x02)
	cyc = rig_run(&r, 1)
	testing.expect_value(t, cyc, 4)
	testing.expect_value(t, r.cpu.pc, 0x0400)
}

@(test)
push_pull :: proc(t: ^testing.T) {
	r: Test_Rig
	// LDA #$11 ; LDB #$22 ; LDX #$3344 ; PSHS A,B,X ; CLRA ; CLRB ; LDX #0 ; PULS A,B,X
	rig_make(&r, {0x86, 0x11, 0xC6, 0x22, 0x8E, 0x33, 0x44, 0x34, 0x16, 0x4F, 0x5F, 0x8E, 0x00, 0x00, 0x35, 0x16})
	rig_run(&r, 3)
	cyc := rig_run(&r, 1)
	testing.expect_value(t, cyc, 5 + 2 + 1 + 1)
	testing.expect_value(t, r.cpu.s, 0x7FFC)
	rig_run(&r, 3)
	testing.expect_value(t, get_d(&r.cpu), 0)
	rig_run(&r, 1)
	testing.expect_value(t, r.cpu.a, 0x11)
	testing.expect_value(t, r.cpu.b, 0x22)
	testing.expect_value(t, r.cpu.x, 0x3344)
	testing.expect_value(t, r.cpu.s, 0x8000)
}

@(test)
pshu_pulu_uses_u :: proc(t: ^testing.T) {
	r: Test_Rig
	// LDA #$AB ; PSHU A ; CLRA ; PULU A
	rig_make(&r, {0x86, 0xAB, 0x36, 0x02, 0x4F, 0x37, 0x02})
	rig_run(&r, 2)
	testing.expect_value(t, r.cpu.u, 0x8FFF)
	testing.expect_value(t, r.ram[0x8FFF], 0xAB)
	rig_run(&r, 2)
	testing.expect_value(t, r.cpu.a, 0xAB)
	testing.expect_value(t, r.cpu.u, 0x9000)
}

@(test)
indexed_modes :: proc(t: ^testing.T) {
	r: Test_Rig
	// LDX #$0300 ; LDA ,X+ ; LDA ,X++ ; LDA ,-X ; LDA 2,X ; LDA $10,X ; LDB #1 ; LDA B,X
	rig_make(&r, {0x8E, 0x03, 0x00, 0xA6, 0x80, 0xA6, 0x81, 0xA6, 0x82, 0xA6, 0x02, 0xA6, 0x88, 0x10, 0xC6, 0x01, 0xA6, 0x85})
	for i in 0 ..< 32 {r.ram[0x300 + i] = u8(0xA0 + i)}
	rig_run(&r, 1)
	cyc := rig_run(&r, 1)
	testing.expect_value(t, r.cpu.a, 0xA0)
	testing.expect_value(t, r.cpu.x, 0x0301)
	testing.expect_value(t, cyc, 4 + 2)
	cyc = rig_run(&r, 1) // ,X++ reads $0301, X=$0303
	testing.expect_value(t, r.cpu.a, 0xA1)
	testing.expect_value(t, r.cpu.x, 0x0303)
	testing.expect_value(t, cyc, 4 + 3)
	rig_run(&r, 1) // ,-X -> X=$0302, reads $0302
	testing.expect_value(t, r.cpu.a, 0xA2)
	testing.expect_value(t, r.cpu.x, 0x0302)
	cyc = rig_run(&r, 1) // 2,X = $0304
	testing.expect_value(t, r.cpu.a, 0xA4)
	testing.expect_value(t, cyc, 4 + 1)
	cyc = rig_run(&r, 1) // $10,X = $0312
	testing.expect_value(t, r.cpu.a, 0xB2)
	testing.expect_value(t, cyc, 4 + 1)
	rig_run(&r, 1)
	rig_run(&r, 1) // B,X = $0303
	testing.expect_value(t, r.cpu.a, 0xA3)
}

@(test)
indexed_negative_and_indirect :: proc(t: ^testing.T) {
	r: Test_Rig
	// LDY #$0310 ; LDA -1,Y ; LDX #$0320 ; LDB [,X] ; LDA [$0320] -> via extended indirect
	rig_make(&r, {0x10, 0x8E, 0x03, 0x10, 0xA6, 0x3F, 0x8E, 0x03, 0x20, 0xE6, 0x94, 0xA6, 0x9F, 0x03, 0x20})
	r.ram[0x30F] = 0x77
	r.ram[0x320] = 0x03; r.ram[0x321] = 0x40 // pointer -> $0340
	r.ram[0x340] = 0x5A
	rig_run(&r, 2) // LDY, LDA -1,Y   (postbyte $3F = 5-bit -1, reg Y)... see assertion
	testing.expect_value(t, r.cpu.a, 0x77)
	rig_run(&r, 2) // LDX; LDB [,X]
	testing.expect_value(t, r.cpu.b, 0x5A)
	cyc := rig_run(&r, 1) // LDA [$0320]
	testing.expect_value(t, r.cpu.a, 0x5A)
	testing.expect_value(t, cyc, 4 + 5)
}

@(test)
indexed_pc_relative_and_lea :: proc(t: ^testing.T) {
	r: Test_Rig
	// LEAX 5,PCR  (postbyte $8C, offset 5) ; LEAY D,X
	rig_make(&r, {0x30, 0x8C, 0x05, 0x31, 0x8B})
	rig_run(&r, 1)
	testing.expect_value(t, r.cpu.x, 0x0203 + 5)
	testing.expect(t, !flag(&r.cpu, .Z))
	r.cpu.a = 0x01; r.cpu.b = 0x02
	rig_run(&r, 1)
	testing.expect_value(t, r.cpu.y, 0x0208 + 0x0102)
}

@(test)
leax_zero_sets_z_leas_does_not :: proc(t: ^testing.T) {
	r: Test_Rig
	// LDX #1 ; LEAX -1,X ; LDY #1 ; LEAS 0,X  (Z set from LEAX; LEAS must not touch Z)
	rig_make(&r, {0x8E, 0x00, 0x01, 0x30, 0x1F, 0x32, 0x84})
	rig_run(&r, 2)
	testing.expect_value(t, r.cpu.x, 0)
	testing.expect(t, flag(&r.cpu, .Z))
	set_flag(&r.cpu, .Z, false)
	rig_run(&r, 1)
	testing.expect(t, !flag(&r.cpu, .Z))
}

@(test)
direct_page :: proc(t: ^testing.T) {
	r: Test_Rig
	// LDA #$03 ; TFR A,DP ; LDB #$99 ; STB $10 -> $0310 ; LDA $10
	rig_make(&r, {0x86, 0x03, 0x1F, 0x8B, 0xC6, 0x99, 0xD7, 0x10, 0x96, 0x10})
	rig_run(&r, 4)
	testing.expect_value(t, r.ram[0x310], 0x99)
	testing.expect_value(t, r.cpu.dp, 3)
	rig_run(&r, 1)
	testing.expect_value(t, r.cpu.a, 0x99)
}

@(test)
rmw_memory_and_clr :: proc(t: ^testing.T) {
	r: Test_Rig
	// INC $0300 (ext) ; DEC $0300 ; CLR $0300 ; COM $0301
	rig_make(&r, {0x7C, 0x03, 0x00, 0x7A, 0x03, 0x00, 0x7F, 0x03, 0x00, 0x73, 0x03, 0x01})
	r.ram[0x300] = 0x7F
	cyc := rig_run(&r, 1)
	testing.expect_value(t, r.ram[0x300], 0x80)
	testing.expect_value(t, cyc, 7)
	testing.expect(t, flag(&r.cpu, .V))
	rig_run(&r, 1)
	testing.expect_value(t, r.ram[0x300], 0x7F)
	rig_run(&r, 1)
	testing.expect_value(t, r.ram[0x300], 0)
	testing.expect(t, flag(&r.cpu, .Z))
	rig_run(&r, 1)
	testing.expect_value(t, r.ram[0x301], 0xFF)
	testing.expect(t, flag(&r.cpu, .C))
}

@(test)
orcc_andcc :: proc(t: ^testing.T) {
	r: Test_Rig
	// ORCC #$01 ; ANDCC #$EF (clear I)
	rig_make(&r, {0x1A, 0x01, 0x1C, 0xEF})
	rig_run(&r, 1)
	testing.expect(t, flag(&r.cpu, .C))
	rig_run(&r, 1)
	testing.expect(t, !flag(&r.cpu, .I) && flag(&r.cpu, .F))
}

@(test)
swi_rti :: proc(t: ^testing.T) {
	r: Test_Rig
	// SWI ; handler at $0400: RTI
	rig_make(&r, {0x3F, 0x12})
	r.ram[0xFFFA] = 0x04; r.ram[0xFFFB] = 0x00
	r.ram[0x400] = 0x3B
	r.cpu.a = 0x55
	r.cpu.x = 0x1234
	cyc := rig_run(&r, 1)
	testing.expect_value(t, cyc, 19)
	testing.expect_value(t, r.cpu.pc, 0x0400)
	testing.expect_value(t, r.cpu.s, 0x8000 - 12)
	testing.expect(t, flag(&r.cpu, .I) && flag(&r.cpu, .F) && flag(&r.cpu, .E))
	r.cpu.a = 0
	r.cpu.x = 0
	cyc = rig_run(&r, 1)
	testing.expect_value(t, cyc, 15)
	testing.expect_value(t, r.cpu.pc, 0x0201)
	testing.expect_value(t, r.cpu.a, 0x55)
	testing.expect_value(t, r.cpu.x, 0x1234)
	testing.expect_value(t, r.cpu.s, 0x8000)
}

@(test)
irq_serviced_when_unmasked :: proc(t: ^testing.T) {
	r: Test_Rig
	// ANDCC #$EF ; NOP ...   IRQ handler at $0400: LDA #$42 ; RTI
	rig_make(&r, {0x1C, 0xEF, 0x12, 0x12, 0x12})
	r.ram[0xFFF8] = 0x04; r.ram[0xFFF9] = 0x00
	r.ram[0x400] = 0x86; r.ram[0x401] = 0x42; r.ram[0x402] = 0x3B
	cpu_assert_interrupt(&r.cpu, .GIME, .IRQ)
	rig_run(&r, 1) // ANDCC unmasks; the latch only holds the old value
	testing.expect_value(t, r.cpu.pc, 0x0202)
	cyc := rig_run(&r, 1) // IRQ taken (24 cycles), then handler's LDA runs
	testing.expect_value(t, r.cpu.pc, 0x0402)
	testing.expect_value(t, r.cpu.a, 0x42)
	testing.expect_value(t, cyc, 24 + 2)
	testing.expect_value(t, r.cpu.s, 0x8000 - 12)
	testing.expect(t, flag(&r.cpu, .E) && flag(&r.cpu, .I))
}

@(test)
irq_masked_not_serviced :: proc(t: ^testing.T) {
	r: Test_Rig
	rig_make(&r, {0x12, 0x12, 0x12})
	r.ram[0xFFF8] = 0x04; r.ram[0xFFF9] = 0x00
	cpu_assert_interrupt(&r.cpu, .GIME, .IRQ)
	rig_run(&r, 3)
	testing.expect_value(t, r.cpu.pc, 0x0203)
}

@(test)
firq_partial_stack :: proc(t: ^testing.T) {
	r: Test_Rig
	rig_make(&r, {0x1C, 0xBF, 0x12, 0x12}) // ANDCC #$BF clears F
	r.ram[0xFFF6] = 0x05; r.ram[0xFFF7] = 0x00
	r.ram[0x500] = 0x3B
	cpu_assert_interrupt(&r.cpu, .PIA1_CD, .FIRQ)
	r.ram[0x500] = 0x12 // handler: NOP
	rig_run(&r, 2)
	// FIRQ taken, then the handler's NOP ran; only PC+CC stacked (3 bytes), E clear
	testing.expect_value(t, r.cpu.pc, 0x0501)
	testing.expect_value(t, r.cpu.s, 0x8000 - 3)
	testing.expect(t, !flag(&r.cpu, .E))
}

@(test)
nmi_not_maskable :: proc(t: ^testing.T) {
	r: Test_Rig
	rig_make(&r, {0x12, 0x12})
	r.ram[0xFFFC] = 0x06; r.ram[0xFFFD] = 0x00
	r.ram[0x600] = 0x12 // handler: NOP
	cpu_assert_interrupt(&r.cpu, .NMI, .NMI)
	rig_run(&r, 1) // NMI taken despite I/F masked, then the handler's NOP runs
	testing.expect_value(t, r.cpu.pc, 0x0601)
	testing.expect_value(t, r.cpu.s, 0x8000 - 12)
}

@(test)
sync_waits_for_interrupt :: proc(t: ^testing.T) {
	r: Test_Rig
	// SYNC ; LDA #7  (interrupt masked: SYNC just resumes)
	rig_make(&r, {0x13, 0x86, 0x07})
	cpu_exec(&r.cpu, 10)
	testing.expect(t, r.cpu.sync_waiting)
	testing.expect_value(t, r.cpu.pc, 0x0201)
	cpu_assert_interrupt(&r.cpu, .PIA0_HSYNC, .IRQ)
	testing.expect(t, !r.cpu.sync_waiting)
	cpu_exec(&r.cpu, 2)
	testing.expect_value(t, r.cpu.a, 7)
}

@(test)
cycle_counts_page2 :: proc(t: ^testing.T) {
	r: Test_Rig
	// LDY #$1234 (4) ; LDS #$4000 (4) ; CMPD #$0000 (5) ; STY $0300 direct? use ext (7) ; SWI2 later not here
	rig_make(&r, {0x10, 0x8E, 0x12, 0x34, 0x10, 0xCE, 0x40, 0x00, 0x10, 0x83, 0x00, 0x00, 0x10, 0xBF, 0x03, 0x00})
	testing.expect_value(t, rig_run(&r, 1), 4)
	testing.expect_value(t, r.cpu.y, 0x1234)
	testing.expect_value(t, rig_run(&r, 1), 4)
	testing.expect_value(t, r.cpu.s, 0x4000)
	testing.expect_value(t, rig_run(&r, 1), 5)
	testing.expect_value(t, rig_run(&r, 1), 7)
	testing.expect_value(t, r.ram[0x300], 0x12)
	testing.expect_value(t, r.ram[0x301], 0x34)
}

@(test)
cmpu_cmps_page3 :: proc(t: ^testing.T) {
	r: Test_Rig
	// CMPU #$9000 ; CMPS #$7FFF
	rig_make(&r, {0x11, 0x83, 0x90, 0x00, 0x11, 0x8C, 0x7F, 0xFF})
	testing.expect_value(t, rig_run(&r, 1), 5)
	testing.expect(t, flag(&r.cpu, .Z))
	rig_run(&r, 1)
	testing.expect(t, !flag(&r.cpu, .Z) && !flag(&r.cpu, .C)) // S=$8000 > $7FFF
}

@(test)
store_clears_v_sets_nz :: proc(t: ^testing.T) {
	r: Test_Rig
	// LDA #$80 ; ORCC #$02 (set V) ; STA $0300
	rig_make(&r, {0x86, 0x80, 0x1A, 0x02, 0xB7, 0x03, 0x00})
	rig_run(&r, 3)
	testing.expect(t, !flag(&r.cpu, .V) && flag(&r.cpu, .N))
}
