* boot.asm - an original boot ROM for the CoCo 3 (and the Odin VCC emulator).
*
* Build:  odin build odin/tools/asm6809 -out:asm6809
*         ./asm6809 rom/boot.asm -o rom/ourrom.rom -l rom/ourrom.lst
* Run:    ./vcc --rom rom/ourrom.rom
*
* The image is 32K: this code lives in the lower 16K ($8000-$BFFF, leaving
* $C000-$FEFF to cartridges) and the interrupt vectors sit at $FFF0.

	include "hw.asm"

	org $8000

* ---- public entry points: a fixed jump table, see rom/README.md ----
api_reset	jmp reset		; $8000
api_cls		jmp cls			; $8003
api_putc	jmp putc		; $8006
api_puts	jmp puts		; $8009
api_newline	jmp newline		; $800C
api_puthex8	jmp puthex8		; $800F
api_puthex16	jmp puthex16		; $8012
api_getc	jmp getc		; $8015
api_poll	jmp poll		; $8018
api_disk_read	jmp disk_read		; $801B
api_disk_write	jmp disk_write		; $801E
api_beep		jmp beep		; $8021
api_tone		jmp tone		; $8024

	setdp 0

reset	orcc #$50		; IRQ and FIRQ off
	lds #STACK_TOP
	clra
	tfr a,dp

* clear the direct page and the hook table area
	ldx #0
.zero	clr ,x+
	cmpx #$0200
	bne .zero

* GIME, SAM, PIAs and the palette
	ldx #gime_init
	bsr write_table
	ldx #pia_init
	bsr write_table
	ldx #sam_init
.sam	ldy ,x++
	beq .samdone
	sta ,y			; any value sets/clears the SAM bit
	bra .sam
.samdone

	ldx #palette_init	; 16 palette registers
	ldy #PALETTE
.pal	lda ,x+
	sta ,y+
	cmpy #PALETTE+16
	bne .pal

	ldx #MMU_T0		; identity map of the top 64K: banks $38-$3F, both tasks
	lda #$38
	ldb #16
.mmu	sta ,x+
	inca
	anda #$07
	ora #$38
	decb
	bne .mmu

* interrupt hooks: every slot starts as "JMP rti_stub"
	ldx #HOOK_SWI3
.hook	lda #$7E		; JMP extended
	sta ,x+
	ldd #rti_stub
	std ,x++
	cmpx #HOOK_END
	bne .hook

	ldx #irq_handler	; real handlers for IRQ (tick, keyboard) and SWI (monitor)
	stx HOOK_IRQ+1
	ldx #swi_handler
	stx HOOK_SWI+1
	lda #1
	sta caps
	lda #$FF
	sta rptkey
	lda #BLINK_PERIOD
	sta blinkcnt

	jsr disk_init
	jsr cls
	ldx #banner
	jsr puts

	lda #$35		; CB1 (vertical sync) interrupt on the falling edge
	sta PIA0_CRB
	andcc #$EF		; IRQ on (FIRQ stays masked)
	jmp monitor

rti_stub	rti

* Store a table of (address, value) pairs ending in address 0 (X -> table).
write_table	ldy ,x++
	beq .end
	lda ,x+
	sta ,y
	bra write_table
.end	rts

	include "console.asm"
	include "keyboard.asm"
	include "disk.asm"
	include "sound.asm"
	include "monitor.asm"

* ---- initialisation data ----
* (address, value) pairs
gime_init	fdb INIT0
	fcb $84		; CoCo 1/2 compatible, MMU off, vectors in ROM, standard SCS (disk), ROM map 0
	fdb INIT1
	fcb $00		; task 0, slow timer clock
	fdb IRQENR
	fcb $00
	fdb FIRQENR
	fcb $00
	fdb TIMERH
	fcb $00
	fdb TIMERL
	fcb $00
	fdb VMODE
	fcb $00
	fdb VRES
	fcb $00
	fdb BORDER
	fcb $00
	fdb VBANK
	fcb $00
	fdb VSCROLL
	fcb $00
	fdb VOFFH
	fcb $E0		; screen at physical $70000 + SAM offset: the top 64K block
	fdb VOFFL
	fcb $00
	fdb HOFFSET
	fcb $00
	fdb 0

* Each PIA: select the data direction register, set it, then switch the data
* register in. $34 = CA2/CB2 low, data register selected, flag interrupts off.
pia_init	fdb PIA0_CRA
	fcb $00
	fdb PIA0_CRB
	fcb $00
	fdb PIA0_DA
	fcb $00		; keyboard rows: inputs
	fdb PIA0_DB
	fcb $FF		; keyboard columns: outputs
	fdb PIA0_CRA
	fcb $34
	fdb PIA0_CRB
	fcb $34
	fdb PIA0_DB
	fcb $FF		; no column strobed
	fdb PIA1_CRA
	fcb $00
	fdb PIA1_CRB
	fcb $00
	fdb PIA1_DA
	fcb $FC		; bit 0 cassette in, bit 1 serial in, bits 7-2 DAC out
	fdb PIA1_DB
	fcb $FA		; VDG bits 7-3 and sound bit 1 out, bits 2 and 0 in
	fdb PIA1_CRA
	fcb $34
	fdb PIA1_CRB
	fcb $34
	fdb PIA1_DA
	fcb $00
	fdb PIA1_DB
	fcb $00		; alphanumeric text, colour set 0
	fdb 0

* SAM bits to clear/set: VDG mode 0, display offset $0400 (F1 set), page 0,
* slow clock, 64K RAM, ROM map type
sam_init	fdb SAM_V0,SAM_V0+2,SAM_V0+4
	fdb SAM_F0,SAM_F1+1,SAM_F1+2,SAM_F1+4,SAM_F1+6,SAM_F1+8,SAM_F1+10
	fdb SAM_P1,SAM_R0,SAM_R1,SAM_M0,SAM_M1,SAM_TY
	fdb 0

* Power-up composite palette from docs/GimeRegisters.txt.
palette_init	fcb $12,$24,$0B,$07,$3F,$1F,$09,$26
	fcb $00,$12,$00,$3F,$00,$12,$00,$26

banner	fcb "COCO 3 OPEN ROM V0.1",13
	fcb "ORIGINAL BOOT ROM, GPLV3",13
	fcb "H FOR HELP",13,13,0

	if *>$C000
	error ROM code overflows into the cartridge space
	endif

* ---- interrupt vectors: straight into the RAM hook table ----
	org $FFF0
	fdb 0
	fdb HOOK_SWI3
	fdb HOOK_SWI2
	fdb HOOK_FIRQ
	fdb HOOK_IRQ
	fdb HOOK_SWI
	fdb HOOK_NMI
	fdb reset
