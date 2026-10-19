package vcc

// Assemble small programs with the asm6809 package and run them on the CPU
// core: proves the encodings do what the mnemonics say.

import "core:testing"
import "asm6809"

// Assemble `src`, load every written byte into the rig and run from $0200
// until the PC reaches the symbol "halt".
run_program :: proc(t: ^testing.T, r: ^Test_Rig, src: string) -> bool {
	res := asm6809.assemble_text("prog.asm", src)
	defer asm6809.destroy(&res)
	if len(res.errors) > 0 {
		testing.expectf(t, false, "%s", asm6809.format_errors(&res, context.temp_allocator))
		return false
	}
	rig_make(r, {})
	for addr in 0 ..< 65536 {
		if res.written[addr] {r.ram[addr] = res.mem[addr]}
	}
	halt, found := asm6809.symbol_value(&res, "halt")
	testing.expect(t, found, "program has no 'halt' label")
	for _ in 0 ..< 100_000 {
		if int(r.cpu.pc) == halt {return true}
		cpu_exec(&r.cpu, 1)
	}
	testing.expectf(t, false, "program did not reach halt (pc=$%04X)", r.cpu.pc)
	return false
}

@(test)
asm_program_arithmetic_and_calls :: proc(t: ^testing.T) {
	src := `
	org $0200
	lds #$0400
	ldx #table
	ldb #5
	clra
loop	adda ,x+
	decb
	bne loop
	sta result
	bsr double
	sta result+1
	lda #7
	ldb #6
	mul
	std result+2
	pshs a,b
	clra
	clrb
	puls a,b
	std result+4
	lda msg,pcr
	sta result+6
	ldx #result
	lda #$11
	sta 7,x
	leay 8,x
	lda #$22
	sta ,y+
	jsr sub2
halt	bra halt
double	asla
	rts
sub2	lda #$33
	sta result+9
	rts
table	fcb 1,2,3,4,5
msg	fcb $5A
	org $0300
result	rmb 16
`
	r: Test_Rig
	if !run_program(t, &r, src) {return}
	want := [?]u8{15, 30, 0, 42, 0, 42, 0x5A, 0x11, 0x22, 0x33}
	for w, i in want {
		testing.expectf(t, r.ram[0x300 + i] == w, "result[%d] = $%02X, want $%02X", i, r.ram[0x300 + i], w)
	}
}

@(test)
asm_program_indexed_modes :: proc(t: ^testing.T) {
	src := `
	org $0200
	lds #$0400
	ldx #tbl
	ldb #2
	lda b,x
	sta r
	lda [ptr]
	sta r+1
	ldy #tbl+1
	lda ,y++
	sta r+2
	lda -1,y
	sta r+3
	lda ,-y
	sta r+4
	ldx #0
	lda tbl,x
	sta r+5
	ldu #r
	lda #$77
	sta 6,u
	ldd #$1234
	std [dptr]
halt	bra halt
tbl	fcb $10,$20,$30
ptr	fdb tbl
dptr	fdb r+8
	org $0300
r	rmb 16
`
	r: Test_Rig
	if !run_program(t, &r, src) {return}
	want := [?]u8{0x30, 0x10, 0x20, 0x30, 0x30, 0x10, 0x77, 0, 0x12, 0x34}
	for w, i in want {
		testing.expectf(t, r.ram[0x300 + i] == w, "r[%d] = $%02X, want $%02X", i, r.ram[0x300 + i], w)
	}
}

@(test)
asm_program_branches_and_flags :: proc(t: ^testing.T) {
	// Each test stores 1 at flags+n when the branch is taken as expected.
	src := `
	org $0200
	lds #$0400
	lda #$FF
	cmpa #1
	blt  s1		; -1 < 1 signed
	bra  next1
s1	lda #1
	sta flags
next1	lda #$FF
	cmpa #1
	bhi  s2		; $FF > 1 unsigned
	bra  next2
s2	lda #1
	sta flags+1
next2	lda #5
	cmpa #5
	lbeq s3		; long branch
	bra  next3
s3	lda #1
	sta flags+2
next3	andcc #$FE
	orcc #$01
	bcs  s4
	bra  next4
s4	lda #1
	sta flags+3
next4	ldd #$00FF
	addd #1
	cmpd #$0100
	bne  fail
	lda #1
	sta flags+4
fail
halt	bra halt
	org $0300
flags	rmb 8
`
	r: Test_Rig
	if !run_program(t, &r, src) {return}
	for i in 0 ..< 5 {
		testing.expectf(t, r.ram[0x300 + i] == 1, "branch test %d did not pass", i)
	}
}
