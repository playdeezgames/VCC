* keyboard.asm - 60 Hz tick, keyboard matrix scan and the key buffer.
*
* The CoCo keyboard is an 8 column by 7 row matrix. Writing a 0 bit to
* PIA0_DB selects a column; PIA0_DA then reads the rows of that column,
* active low (bit 7 belongs to the joystick comparator). Every vertical sync
* interrupt we scan all columns. A key counts as pressed once it has been
* seen in two scans in a row (debounce); each newly pressed key becomes one
* character in a 16 entry ring buffer, and the last one repeats while held.
*
* Key ids are row_bit*8 + column, 0-55:
*
*          col: 0     1      2      3     4     5     6     7
*   bit 0:      @     A      B      C     D     E     F     G
*   bit 1:      H     I      J      K     L     M     N     O
*   bit 2:      P     Q      R      S     T     U     V     W
*   bit 3:      X     Y      Z      UP   DOWN  LEFT  RIGHT  SPACE
*   bit 4:      0     1      2      3     4     5     6     7
*   bit 5:      8     9      :      ;     ,     -     .     /
*   bit 6:    ENTER  CLEAR BREAK   ALT   CTRL   F1    F2   SHIFT
*
* Character codes: ASCII for printable keys, ENTER $0D, BREAK $03, CLEAR $0C,
* UP $0B, DOWN $0A, LEFT $08 (backspace), RIGHT $09, F1 $81, F2 $82, CTRL
* plus a letter gives the control code. Like a real CoCo, letters are upper
* case unless SHIFT is held; SHIFT-0 toggles that (caps lock).

REPEAT_DELAY	equ 30		; ticks before a held key repeats
REPEAT_RATE	equ 4		; ticks between repeats
KEY_ALT		equ 51
KEY_CTRL	equ 52
KEY_SHIFT	equ 55
KEY_ZERO	equ 32

* ---- IRQ handler (installed in the IRQ hook) ----
irq_handler	clra
	tfr a,dp
	lda PIA0_CRB
	bpl .exit		; not the vertical sync flag
	lda PIA0_DB		; reading the data register clears the flag
	inc ticks+3
	bne .counted
	inc ticks+2
	bne .counted
	inc ticks+1
	bne .counted
	inc ticks
.counted	lbsr kb_irq
	lbsr blink
	lbsr disk_tick
.exit	rti

* ---- one scan and its processing ----
kb_irq	ldx #kbcur		; read the 8 columns
	lda #$FE
.col	sta PIA0_DB
	ldb PIA0_DA
	comb
	andb #$7F
	stb ,x+
	orcc #1
	rola			; next column low
	cmpx #kbcur+8
	bne .col
	lda #$FF
	sta PIA0_DB

	clr kbt1		; phase 1: debounce every column
.deb	ldx #kbcur
	ldb kbt1
	abx
	lda ,x
	sta kbt2		; this scan
	anda 8,x		; seen before too
	sta kbt3
	ldb 16,x
	comb
	andb kbt3		; stable now, not before
	stb 24,x
	lda kbt3
	sta 16,x
	lda kbt2
	sta 8,x
	inc kbt1
	lda kbt1
	cmpa #8
	bne .deb

	clr kbt1		; phase 2: new presses, all columns
.new	ldx #kbnew
	ldb kbt1
	abx
	lda ,x
	beq .nextcol
	sta kbt3
	clr kbt2		; row bit number
.bit	lsr kbt3
	bcc .nobit
	lda kbt2
	asla
	asla
	asla
	adda kbt1
	lbsr kb_press
.nobit	inc kbt2
	tst kbt3
	bne .bit
.nextcol	inc kbt1
	lda kbt1
	cmpa #8
	bne .new

* repeat the last key while it stays down
	lda rptkey
	cmpa #$FF
	beq .done
	tfr a,b
	andb #7			; column
	ldx #kbstab
	abx
	ldb ,x			; rows down in that column
	lsra
	lsra
	lsra			; row bit number
.shift	tsta
	beq .test
	lsrb
	deca
	bra .shift
.test	andb #1
	beq .release
	dec rptcnt
	bne .done
	lda #REPEAT_RATE
	sta rptcnt
	ldb rptkey
	lbsr kb_translate
	tsta
	beq .done
	lbsr kb_put
	rts
.release	lda #$FF
	sta rptkey
.done	rts

* A = id of a key that has just been pressed
kb_press	cmpa #KEY_SHIFT
	beq .end
	cmpa #KEY_CTRL
	beq .end
	cmpa #KEY_ALT
	beq .end
	tfr a,b
	cmpb #KEY_ZERO
	bne .normal
	lda kbstab+7
	bita #$40
	beq .normal
	lda caps		; SHIFT-0 toggles caps lock
	eora #1
	sta caps
	rts
.normal	stb rptkey
	lda #REPEAT_DELAY
	sta rptcnt
	lbsr kb_translate
	tsta
	beq .end
	lbsr kb_put
.end	rts

* B = key id -> A = character, 0 for none. Preserves B, clobbers X.
kb_translate	pshs b
	ldx #keymap_plain
	lda kbstab+7
	bita #$40		; SHIFT down?
	beq .look
	ldx #keymap_shift
.look	lda b,x
	beq .done
	tst caps
	bne .ctrl
	cmpa #'A'		; caps off: swap the case of letters
	blo .ctrl
	cmpa #'Z'
	bls .swap
	cmpa #'a'
	blo .ctrl
	cmpa #'z'
	bhi .ctrl
.swap	eora #$20
.ctrl	ldb kbstab+4
	bitb #$40		; CTRL down?
	beq .done
	cmpa #$40
	blo .done
	cmpa #$7F
	bhs .done
	anda #$1F
.done	puls b,pc

* A -> ring buffer (dropped when it is full)
kb_put	pshs b,x
	ldb kbtail
	incb
	andb #15
	cmpb kbhead
	beq .end
	ldb kbtail
	ldx #KBBUF
	abx
	sta ,x
	incb
	andb #15
	stb kbtail
.end	puls b,x,pc

* Non-blocking read: carry set and A = character, or carry clear.
* Clobbers B and X.
poll	ldb kbhead
	cmpb kbtail
	beq .none
	ldx #KBBUF
	abx
	lda ,x
	incb
	andb #15
	stb kbhead
	orcc #1
	rts
.none	andcc #$FE
	rts

* Blocking read: wait for a key (sleeping until the next interrupt). The
* interrupt mask must be clear or this never returns. Clobbers nothing but A.
getc	pshs b,x
.wait	bsr poll
	bcs .got
	sync
	bra .wait
.got	puls b,x,pc

* ---- key maps, indexed by key id ----
keymap_plain	fcb "@ABCDEFG"
	fcb "HIJKLMNO"
	fcb "PQRSTUVW"
	fcb "XYZ",$0B,$0A,$08,$09,$20
	fcb "01234567"
	fcb "89:;,-./"
	fcb $0D,$0C,$03,0,0,$81,$82,0

keymap_shift	fcb "@abcdefg"
	fcb "hijklmno"
	fcb "pqrstuvw"
	fcb "xyz",$0B,$0A,$08,$09,$20
	fcb 0,"!",34,"#$%&",39
	fcb "()*+<=>?"
	fcb $0D,$0C,$03,0,0,$81,$82,0
