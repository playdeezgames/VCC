* tape.asm - cassette interface: FSK on the PIA1 DAC and comparator.
*
* Hardware (see docs / Field Guide section 21): the motor is switched by PIA1
* CA2 ($FF21 bit 3 high = on). Output goes through the 6 bit DAC ($FF20 bits
* 7-2) with the analog multiplexer on the sound source and the sound enable
* (CB2, $FF23 bit 3) low. Input is the comparator on $FF20 bit 0.
* Bits are frequency shift keyed, one full cycle per bit:
*   1 = about 1200 Hz   0 = about 2400 Hz   (8 stepped sine values per cycle)
*
* Tape format (the usual block layout of the platform):
*   leader of $55 bytes, $3C, type, length, data, checksum, trailer $55
*   byte = 8 bits, least significant bit first; checksum = sum of type,
*   length and data, modulo 256.
*   type 0: file header, 15 bytes: name (8, space padded) kind (1, 'M')
*           load address (2) byte count (2) entry address (2)
*   type 1: data (1-255 bytes), type $FF: end of file
*
* Public routines (interrupts are masked while they run; the motor is on only
* while they run):
*   tape_save  X -> 15 byte header record. Writes the header and the
*              count bytes at the load address. Carry set + A = TE_ code on error.
*   tape_load  X -> 8 byte name (first byte 0: any file), Y = load address
*              (0: the header's). Searches for the file, loads it, leaves
*              its header at TAPEHDR. Carry set + A = TE_ code on error.
*              (BREAK aborts the wait for the tape.)

TE_NOSIGNAL	equ 1		; no tape signal (or the tape ended)
TE_CHECKSUM	equ 2
TE_BREAK	equ 4

TAPE_DLY1	equ 13		; delay loops per step: 1 bit, ~1200 Hz
TAPE_DLY0	equ 3		; 0 bit, ~2400 Hz
TAPE_THRESH	equ 37		; poll loops per cycle: more = a 1 bit
LEADER_FIRST	equ 128
LEADER_NEXT	equ 8
TAPE_BLOCK	equ 255

* ---- writing ----
sine8	fcb $90,$AC,$AC,$90,$6C,$54,$54,$6C	; one cycle around the middle ($80)

put_cycle	pshs a,b,x
	ldx #sine8
.step	lda ,x+
	sta PIA1_DA
	ldb tapedly
.wait	decb
	bne .wait
	cmpx #sine8+8
	bne .step
	puls a,b,x,pc

* A = byte: write it, least significant bit first
put_byte	pshs a,b
	ldb #8
	stb tapecnt
.bit	lsra
	bcs .one
	ldb #TAPE_DLY0
	bra .go
.one	ldb #TAPE_DLY1
.go	stb tapedly
	bsr put_cycle
	dec tapecnt
	bne .bit
	puls a,b,pc

put_byte_sum	pshs a
	adda tapesum
	sta tapesum
	puls a
	bra put_byte

* One block: tapetype, X -> data, B = length, Y = number of leader bytes.
put_block	pshs x,y,d
	stb tapelen
.lead	lda #$55
	bsr put_byte
	leay -1,y
	bne .lead
	lda #$3C
	bsr put_byte
	clr tapesum
	lda tapetype
	bsr put_byte_sum
	lda tapelen
	bsr put_byte_sum
	tst tapelen
	beq .nodata
	ldb tapelen
.data	lda ,x+
	bsr put_byte_sum
	decb
	bne .data
.nodata	lda tapesum
	bsr put_byte
	lda #$55
	bsr put_byte
	puls x,y,d,pc

motor_on	lda #$34		; multiplexer on the sound source, sound enable low
	sta PIA0_CRA
	lda #$35
	sta PIA0_CRB
	lda #$34
	sta PIA1_CRB
	lda #$3C		; CA2 high: motor on
	sta PIA1_CRA
	rts

motor_off	lda #$80		; DAC to the middle, then off
	sta PIA1_DA
	lda #0
	sta PIA1_DA
	lda #$34
	sta PIA1_CRA
	rts

tape_save	pshs cc,b,x,y,u
	orcc #$10
	tfr x,u
	bsr motor_on
	ldx #0			; let the motor reach speed: about half a second
.spin	leax -1,x
	bne .spin
	lda #0			; header block
	sta tapetype
	tfr u,x
	ldb #15
	ldy #LEADER_FIRST
	lbsr put_block
	ldx 9,u			; load address
	stx tapedst
	ldd 11,u		; byte count
	std tapeleft
.more	ldd tapeleft
	beq .eof
	tsta
	bne .full
	cmpb #TAPE_BLOCK
	blo .chunk
.full	ldb #TAPE_BLOCK
.chunk	stb tapechunk
	lda #1
	sta tapetype
	ldx tapedst
	ldy #LEADER_NEXT
	lbsr put_block
	ldb tapechunk
	clra
	addd tapedst
	std tapedst
	ldd tapeleft
	subb tapechunk
	sbca #0
	std tapeleft
	bra .more
.eof	lda #$FF
	sta tapetype
	ldy #LEADER_NEXT
	ldb #0
	lbsr put_block
	lbsr motor_off
	puls cc,b,x,y,u
	andcc #$FE		; (the saved CC may have carry set)
	rts

* ---- reading ----
* A = desired level (0/1): wait for the input to reach it. About 17 s, BREAK
* aborts. Carry set + A = TE_ code on failure.
wait_level	sta tapetmp
	lda #240
	sta tapeouter
.outer	ldx #4096
.poll	lda PIA1_DA
	anda #1
	cmpa tapetmp
	beq .got
	leax -1,x
	bne .poll
	lda #$FB		; BREAK key: column 2, row bit 6
	sta PIA0_DB
	lda PIA0_DA
	ldb #$FF
	stb PIA0_DB
	bita #$40
	beq .break
	dec tapeouter
	bne .outer
	lda #TE_NOSIGNAL
	orcc #1
	rts
.break	lda #TE_BREAK
	orcc #1
	rts
.got	andcc #$FE
	rts

* Wait for a rising edge: afterwards the input has just gone high.
sync_rise	lda PIA1_DA
	anda #1
	beq .low
	lda #0			; high now: wait for it to fall first
	bsr wait_level
	bcs .end
.low	lda #1
	bsr wait_level
.end	rts

* Measure one cycle starting just after a rising edge: A = 1 or 0, carry set +
* A = TE_NOSIGNAL if the input stops changing.
get_bit	clrb
.high	incb
	beq .none
	lda PIA1_DA
	anda #1
	bne .high
.low	incb
	beq .none
	lda PIA1_DA
	anda #1
	beq .low
	cmpb #TAPE_THRESH
	blo .zero
	lda #1
	andcc #$FE
	rts
.zero	lda #0
	andcc #$FE
	rts
.none	lda #TE_NOSIGNAL
	orcc #1
	rts

* A = byte (carry clear) or error
get_byte	lda #8
	sta tapecnt
	clr tapebyte
.bit	bsr get_bit
	bcs .end
	lsr tapebyte
	tsta
	beq .zero
	lda tapebyte
	ora #$80
	sta tapebyte
.zero	dec tapecnt
	bne .bit
	lda tapebyte
	andcc #$FE
.end	rts

* Search the leader, then the $3C that ends it.
find_sync	lbsr sync_rise
	bcs .end
	clr tapebyte
.look	bsr get_bit
	bcs .end
	lsr tapebyte
	tsta
	beq .zero
	lda tapebyte
	ora #$80
	sta tapebyte
.zero	lda tapebyte
	cmpa #$3C
	bne .look
	andcc #$FE
.end	rts

* One block. The data goes to tapedst (advancing it), unless that is 0.
* Carry clear: A = type, B = length. Carry set: A = error.
read_block	lbsr find_sync
	bcs .end
	lbsr get_byte
	bcs .end
	sta tapetype
	sta tapesum
	lbsr get_byte
	bcs .end
	sta tapeblen
	sta tapelen
	adda tapesum
	sta tapesum
	tst tapelen
	beq .cks
.data	lbsr get_byte
	bcs .end
	pshs a
	adda tapesum
	sta tapesum
	puls a
	ldx tapedst
	beq .skip
	sta ,x+
	stx tapedst
.skip	dec tapelen
	bne .data
.cks	lbsr get_byte
	bcs .end
	cmpa tapesum
	bne .bad
	lda tapetype
	ldb tapeblen
	andcc #$FE
.end	rts
.bad	lda #TE_CHECKSUM
	orcc #1
	rts

tape_load	pshs cc,b,x,y,u
	orcc #$10
	stx tapenm
	sty tapeovr
	lbsr motor_on
.header	ldx #TAPEHDR
	stx tapedst
	lbsr read_block
	lbcs .fail
	cmpa #0
	bne .header		; not a header: keep looking
	cmpb #15
	bne .header
	tst tapeverbose
	beq .quiet
	lbsr tape_announce
.quiet	ldx tapenm
	lda ,x
	beq .match		; no name: any file
	ldy #TAPEHDR
	ldb #8
.cmp	lda ,x+
	cmpa ,y+
	bne .skipfile
	decb
	bne .cmp
.match	ldx tapeovr
	bne .dest
	ldx TAPEHDR+9		; the file's own load address
.dest	stx tapedst
.blocks	lbsr read_block
	bcs .fail
	cmpa #$FF
	bne .blocks		; data block: stored, next
	lbsr motor_off
	puls cc,b,x,y,u
	andcc #$FE
	rts
.skipfile	ldx #0			; other file: read past its blocks
	stx tapedst
.skip	lbsr read_block
	bcs .fail
	cmpa #$FF
	bne .skip
	bra .header
.fail	sta tapetmp
	lbsr motor_off
	puls cc,b,x,y,u
	lda tapetmp
	orcc #1
	rts

* Print "FOUND name" (the header is at TAPEHDR).
tape_announce	pshs a,b,x
	ldx #msg_found
	jsr puts
	ldb #8
	ldx #TAPEHDR
.name	lda ,x+
	jsr putc
	decb
	bne .name
	jsr newline
	puls a,b,x,pc
msg_found	fcb "FOUND ",0
