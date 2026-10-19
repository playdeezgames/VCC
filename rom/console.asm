* console.asm - text console on the 32x16 VDG screen at $0400.
*
* The screen holds VDG codes: $40-$7F are normal characters (the code is the
* ASCII value with bit 6 forced on, for $20-$5F), $00-$3F the same glyphs in
* inverse video. Lower case ASCII has no glyph of its own and is shown as
* inverse upper case. The cursor is the cell under `cursor`, drawn in inverse
* video (code XOR $40); `under` remembers what it covers.
*
* Public routines (all preserve every register unless noted):
*   cls       clear the screen, cursor to the top left
*   putc      A = ASCII character. CR: new line; BS ($08): back up and erase;
*             FF ($0C): clear screen; BEL ($07): beep; other controls are ignored
*   puts      X -> zero terminated string; X returns past the terminator
*   locate    A = column, B = row: move the cursor
*   newline   same as putc of CR
*   puthex8   A as two hex digits
*   puthex16  D as four hex digits

* A = ASCII $20-$7E -> VDG code
to_vdg	cmpa #$60
	blo .upper
	suba #$20		; lower case shows as inverse upper case
	anda #$3F
	rts
.upper	anda #$3F
	ora #$40
	rts

cur_hide	pshs x,a
	tst curvis
	beq .end
	ldx cursor
	lda under
	sta ,x
	clr curvis
.end	puls a,x,pc

cur_show	pshs x,a
	tst curvis
	bne .end
	ldx cursor
	lda ,x
	sta under
	eora #$40
	sta ,x
	lda #1
	sta curvis
.end	puls a,x,pc

* Called every tick: toggle the cursor unless the screen is being changed.
blink	tst cblock
	bne .end
	dec blinkcnt
	bne .end
	lda #BLINK_PERIOD
	sta blinkcnt
	tst curvis
	beq .on
	bra cur_hide
.on	bra cur_show
.end	rts

clear_screen	pshs x,a
	ldx #SCREEN
	lda #BLANK
.fill	sta ,x+
	cmpx #SCREEN_END
	bne .fill
	ldx #SCREEN
	stx cursor
	clr curvis		; the cursor cell was overwritten
	puls a,x,pc

cls	inc cblock
	bsr clear_screen
	bsr cur_show
	dec cblock
	rts

* Scroll the screen up one row; the cursor goes to the start of the last row.
scroll	pshs d,x,y
	ldx #SCREEN
	ldy #SCREEN+COLS
.copy	ldd ,y++
	std ,x++
	cmpy #SCREEN_END
	bne .copy
	lda #BLANK
	ldb #COLS
.clear	sta ,x+
	decb
	bne .clear
	ldx #SCREEN_END-COLS
	stx cursor
	puls d,x,y,pc

* Move the cursor to the start of the next row, scrolling at the bottom.
newline_raw	pshs d
	ldd cursor
	subd #SCREEN
	andb #$E0		; start of the current row
	addd #SCREEN+COLS
	cmpd #SCREEN_END
	blo .set
	bsr scroll
	puls d,pc
.set	std cursor
	puls d,pc

putc	pshs d,x,y
	inc cblock
	lbsr cur_hide
	cmpa #$0D
	beq .newline
	cmpa #$08
	beq .back
	cmpa #$0C
	beq .formfeed
	cmpa #$07
	beq .bell
	cmpa #$20
	blo .done		; other control characters do nothing
	cmpa #$7F
	bhs .done
	lbsr to_vdg
	ldx cursor
	sta ,x+
	stx cursor
	cmpx #SCREEN_END
	blo .done
	bsr scroll
	bra .done
.newline	bsr newline_raw
	bra .done
.back	ldx cursor
	cmpx #SCREEN
	bls .done
	leax -1,x
	stx cursor
	lda #BLANK
	sta ,x
	bra .done
.bell	lbsr beep
	bra .done
.formfeed	lbsr clear_screen
.done	lbsr cur_show
	lda #BLINK_PERIOD
	sta blinkcnt		; solid cursor for a while after output
	dec cblock
	puls d,x,y,pc

newline	pshs a
	lda #$0D
	bsr putc
	puls a,pc

puts	pshs a
.next	lda ,x+
	beq .end
	bsr putc
	bra .next
.end	puls a,pc

* A -> hex digit of its low nibble
hexdigit	anda #$0F
	adda #'0'
	cmpa #'9'
	bls .print
	adda #7
.print	bra putc

puthex8	pshs a
	lsra
	lsra
	lsra
	lsra
	bsr hexdigit
	lda ,s			; the original value
	bsr hexdigit
	puls a,pc

puthex16	pshs d
	bsr puthex8		; high byte
	tfr b,a
	bsr puthex8
	puls d,pc

* A = column (0-31), B = row (0-15): move the cursor there (clamped to the
* screen). All registers kept.
locate	pshs d,x
	inc cblock
	lbsr cur_hide
	cmpb #ROWS-1
	bls .rowok
	ldb #ROWS-1
.rowok	lda #COLS
	mul			; D = row * 32
	addd #SCREEN
	tfr d,x
	ldb ,s			; the column (A as pushed)
	cmpb #COLS-1
	bls .colok
	ldb #COLS-1
.colok	abx
	stx cursor
	lbsr cur_show
	dec cblock
	puls d,x,pc
