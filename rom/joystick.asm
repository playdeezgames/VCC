* joystick.asm - the two analog joysticks and their buttons.
*
* There is no analog to digital converter. Each game port feeds a comparator
* whose output is PIA0 side A bit 7: it is high while the stick's voltage is
* above the level on the 6 bit DAC (PIA1 side A bits 7-2). The analog
* multiplexer picks the axis: PIA0 CRA bit 3 (CA2) is the low select bit and
* PIA0 CRB bit 3 (CB2) the high one:
*
*   axis 0 right X   1 right Y   2 left X   3 left Y
*
* The buttons pull keyboard row bits low (active low, read with no keyboard
* column selected): bit 0 right button 1, bit 1 left button 1, bit 2 right
* button 2, bit 3 left button 2.
*
*   joy_axis     A = axis (0-3)  ->  A = position 0-63 (centre about 32).
*                A stick that is not there reads 0. Interrupts are masked
*                for the measurement; the multiplexer goes back to the sound
*                source and the DAC to 0 afterwards (so it clicks on a
*                speaker; schedule it like the Field Guide suggests).
*   joy_buttons  -> A = bit mask of the pressed buttons (bit set = pressed)

joy_axis	pshs cc,b,x
	orcc #$10
	ldb #$34		; CA2 low/high = low select bit
	bita #1
	beq .lowsel
	ldb #$3C
.lowsel	stb PIA0_CRA
	ldb #$35		; CB2 = high select bit; keep the vertical sync IRQ enabled
	bita #2
	beq .highsel
	ldb #$3D
.highsel	stb PIA0_CRB
	ldb #$FF
	stb PIA0_DB		; no keyboard column selected
	clrb			; result
	lda #32			; bit being tried
.next	pshs a
	pshs b
	ora ,s			; trial = result | bit
	leas 1,s
	asla
	asla			; DAC bits 7-2
	sta PIA1_DA
	ldx #8			; let the comparator settle
.settle	leax -1,x
	bne .settle
	lda PIA0_DA
	bpl .below
	orb ,s			; the stick is at or above the trial level
.below	puls a
	lsra
	bne .next
	stb joytmp
	lda #0
	sta PIA1_DA
	lda #$34		; multiplexer back to the sound source
	sta PIA0_CRA
	lda #$35
	sta PIA0_CRB
	puls cc,b,x
	lda joytmp
	rts

joy_buttons	lda #$FF
	sta PIA0_DB
	lda PIA0_DA
	coma
	anda #$0F
	rts
