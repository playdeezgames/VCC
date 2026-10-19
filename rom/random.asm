* random.asm - pseudo random numbers.
*
* A 16 bit xorshift generator (shifts 7, 9, 8): x ^= x << 7; x ^= x >> 9;
* x ^= x << 8. It visits all 65535 non-zero states before repeating and is
* never zero. The state is stirred with the tick counter on every key press,
* so a program that waits for the user gets a different sequence each run.
*
*   rand        -> D = next value (1-65535)
*   rand_seed   D = new state (0 is replaced by a fixed non-zero value)
*   rand_range  A = n -> A = a value in 0..n-1 (n = 0 means 256).
*               Uses the high byte of rand, scaled; clobbers nothing else.

RAND_DEFAULT	equ $ACE1

rand	ldd rndstate
	std rndtmp
	aslb			; x << 7
	rola
	aslb
	rola
	aslb
	rola
	aslb
	rola
	aslb
	rola
	aslb
	rola
	aslb
	rola
	eora rndtmp
	eorb rndtmp+1
	std rndstate
	tfr a,b			; x >> 9 only touches the low byte
	lsrb
	eorb rndstate+1
	stb rndstate+1
	lda rndstate		; x << 8: high byte ^= low byte
	eora rndstate+1
	sta rndstate
	ldb rndstate+1
	rts

rand_seed	cmpd #0
	bne .set
	ldd #RAND_DEFAULT
.set	std rndstate
	rts

rand_range	pshs b
	tfr a,b
	pshs b			; n
	bsr rand
	ldb ,s+
	beq .full		; n = 256: the high byte as it is
	mul			; A = high byte * n / 256
.full	puls b
	rts

* Mix the tick counter into the state (called on key presses, from the IRQ).
rand_stir	pshs a
	lda ticks+3
	eora rndstate+1
	sta rndstate+1
	lda ticks+2
	eora rndstate
	sta rndstate
	ora rndstate+1		; never leave the generator at zero
	bne .ok
	lda #RAND_DEFAULT/256
	sta rndstate
	lda #RAND_DEFAULT&255
	sta rndstate+1
.ok	puls a,pc
