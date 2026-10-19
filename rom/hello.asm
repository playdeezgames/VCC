* hello.asm - the smallest useful ROM: proves the toolchain end to end.
*
* Build:  odin build odin/tools/asm6809 -out:asm6809
*         ./asm6809 rom/hello.asm -o rom/hello.rom
* Run:    ./vcc --rom rom/hello.rom
*
* Puts a message and a row of semigraphics blocks on the VDG text screen at
* $0400 and then waits forever.

SCREEN	equ $0400
SAM_F1	equ $FFC9		; SAM display offset bit 1 = 1: screen at 2*512 = $0400
INIT0	equ $FF90		; GIME: bit 7 = CoCo compatible, no MMU, ROM map 0
VOFFH	equ $FF9D		; GIME video start / 8 in physical RAM. With the MMU off
VOFFL	equ $FF9E		; the CPU sees the top 64K block, $70000-$7FFFF (128K+)

	org $8000

reset	orcc #$50		; no IRQ/FIRQ
	lds #$03FF
	lda #$80
	sta INIT0
	sta SAM_F1		; any write sets the bit
	lda #$E0		; video start = $70000/8 = $E000, plus the SAM offset
	sta VOFFH
	clr VOFFL

* clear the screen to green spaces
	ldx #SCREEN
	lda #$60
clear	sta ,x+
	cmpx #SCREEN+$200
	bne clear

* message, converted from ASCII to VDG codes (AND $3F, OR $40)
	ldx #SCREEN+32*2+4
	ldy #message
copy	lda ,y+
	beq blocks
	anda #$3F
	ora #$40
	sta ,x+
	bra copy

* a row of semigraphics blocks: codes $80-$FF
blocks	ldx #SCREEN+32*5
	lda #$80
fill	sta ,x+
	inca
	cmpa #$A0
	bne fill

halt	bra halt

message	fcn "HELLO FROM OUR OWN ROM"

* unused interrupts return at once; reset starts the program
nothing	rti

	org $FFF0
	fdb nothing		; reserved
	fdb nothing		; SWI3
	fdb nothing		; SWI2
	fdb nothing		; FIRQ
	fdb nothing		; IRQ
	fdb nothing		; SWI
	fdb nothing		; NMI
	fdb reset		; RESET
