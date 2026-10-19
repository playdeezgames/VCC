* sound.asm - square wave tones through the 6 bit DAC.
*
* The DAC is PIA1 side A bits 7-2 ($FF20). It reaches the speaker only while
* the analog multiplexer is on its sound source (PIA0 $FF01/$FF03 bit 3 = 0,
* the boot default) and the sound enable bit (PIA1 $FF23 bit 3, CB2) is high.
* tone raises that bit for its duration and puts it back.
*
*   tone   X = loops per half period, Y = number of periods.
*          One loop is 8 CPU cycles, so the pitch is about
*          1 / (2 * (X * 8 + 15) cycles * 1.118 us). Interrupts are masked
*          while it runs. Preserves all registers.
*   beep   about 1 kHz for 0.1 s (also what BEL, $07, does in putc)

DAC_HIGH	equ $A0
DAC_LOW		equ $00
BEEP_LOOPS	equ 54
BEEP_PERIODS	equ 100

tone	pshs cc,a,x,y,u
	orcc #$10
	tfr x,u			; loops per half period
	lda PIA1_CRB
	pshs a
	lda #$3C		; CB2 high: sound enable
	sta PIA1_CRB
.period	lda #DAC_HIGH
	sta PIA1_DA
	tfr u,x
.high	leax -1,x
	bne .high
	lda #DAC_LOW
	sta PIA1_DA
	tfr u,x
.low	leax -1,x
	bne .low
	leay -1,y
	bne .period
	puls a
	sta PIA1_CRB
	puls cc,a,x,y,u,pc

beep	pshs x,y
	ldx #BEEP_LOOPS
	ldy #BEEP_PERIODS
	bsr tone
	puls x,y,pc
