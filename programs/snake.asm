* snake.asm - a snake game for the open ROM, on the 32 x 16 text screen.
*
* Steer with the arrow keys (or W A S D), eat the red blocks, do not hit the
* wall or yourself. BREAK quits to the monitor.
*
* Build a bootable disk:  programs/build.sh   (makes programs/snake.dsk)
* Play:  ./vcc --rom rom/ourrom.rom --disk0 programs/snake.dsk, then B at the prompt.
* Or load it any other way and  G 0800.

	include "../rom/hw.asm"

* ROM entry points (rom/README.md)
CLS	equ $8003
PUTC	equ $8006
PUTS	equ $8009
GETC	equ $8015
POLL	equ $8018
BEEP	equ $8021
TONE	equ $8024
RAND_RANGE	equ $8039
LOCATE	equ $803C

* VDG screen codes (semigraphics 4 solid blocks: $80 + colour*16 + $0F)
EMPTY	equ BLANK		; the console's blank
BODY	equ $8F			; green
HEAD	equ $9F			; yellow
FOOD	equ $BF			; red
WALL	equ $CF			; buff

* the playfield: walls on rows 1 and 15, columns 0 and 31
FIELD_W	equ 30
FIELD_H	equ 13
START_DELAY	equ 9		; ticks (1/60 s) between moves
MIN_DELAY	equ 3
WIN_LENGTH	equ 380

* game variables
V	equ $0F00
head	equ V		; fdb: screen address of the head
dir	equ V+2		; fdb: address step: +1 -1 +32 -32
qhead	equ V+4		; fdb: where the next body cell address goes
qtail	equ V+6		; fdb: oldest body cell
food	equ V+8		; fdb
score	equ V+10	; fdb
len	equ V+12	; fdb
delay	equ V+14	; fcb
last	equ V+15	; fcb: tick at the last move
quit	equ V+16	; fcb
ate	equ V+17	; fcb
tdigit	equ V+18	; fcb
divisor	equ V+19	; fdb
QBUF	equ $1000	; ring buffer of body cell addresses (2 bytes each)
QEND	equ $1400

	org $0800

start	clr quit
title	jsr CLS
	lda #11
	ldb #3
	jsr LOCATE
	ldx #txt_title
	jsr PUTS
	lda #3
	ldb #6
	jsr LOCATE
	ldx #txt_help1
	jsr PUTS
	lda #3
	ldb #8
	jsr LOCATE
	ldx #txt_help2
	jsr PUTS
	lda #3
	ldb #10
	jsr LOCATE
	ldx #txt_help3
	jsr PUTS
	lda #9
	ldb #13
	jsr LOCATE
	ldx #txt_press
	jsr PUTS
	jsr drain
	jsr GETC
	cmpa #$03
	lbeq exit

newgame	jsr CLS
	jsr draw_walls
	lda #0
	ldb #0
	jsr LOCATE
	ldx #txt_score
	jsr PUTS

	ldx #SCREEN+8*32+13	; a snake of three, heading right
	stx qtail
	ldd #SCREEN+8*32+13
	ldy #QBUF
	std ,y++
	lda #BODY
	sta ,x
	ldd #SCREEN+8*32+14
	std ,y++
	lda #BODY
	sta SCREEN+8*32+14
	ldd #SCREEN+8*32+15
	std ,y++
	std head
	lda #HEAD
	sta SCREEN+8*32+15
	sty qhead
	ldy #QBUF
	sty qtail
	ldd #1
	std dir
	ldd #3
	std len
	ldd #0
	std score
	lda #START_DELAY
	sta delay
	jsr drain
	jsr new_food
	jsr show_score
	lda ticks+3
	sta last

mainloop	sync			; one tick (1/60 s) at a time
	jsr read_keys
	tst quit
	lbne exit
	lda ticks+3
	suba last
	cmpa delay
	blo mainloop
	lda ticks+3
	sta last
	jsr step
	bcs gameover
	bra mainloop

* ---- game over ----
gameover	ldx #150		; a low growl
	ldy #40
	jsr TONE
	lda #11
	ldb #7
	jsr LOCATE
	ldx #txt_over
	jsr PUTS
	lda #9
	ldb #9
	jsr LOCATE
	ldx #txt_again
	jsr PUTS
	jsr drain
	jsr GETC
	cmpa #$03
	lbne newgame
exit	jsr CLS
	rts

* ---- one move; carry set when the snake dies ----
step	ldd head
	addd dir
	tfr d,u			; the cell the head moves to
	clr ate
	lda ,u
	cmpa #FOOD
	beq .eat
	cmpa #EMPTY
	lbne .dead
	ldx qtail		; plain move: the tail cell empties
	ldy ,x++
	lda #EMPTY
	sta ,y
	cmpx #QEND
	blo .tail
	ldx #QBUF
.tail	stx qtail
	bra .place
.eat	inc ate
	ldd score
	addd #1
	std score
	ldd len
	addd #1
	std len
.place	ldx head		; the old head becomes body
	lda #BODY
	sta ,x
	stu head
	lda #HEAD
	sta ,u
	ldx qhead
	stu ,x++
	cmpx #QEND
	blo .queued
	ldx #QBUF
.queued	stx qhead
	tst ate
	beq .done
	ldx #20			; a short chirp
	ldy #12
	jsr TONE
	lda score+1
	anda #1
	bne .slow
	lda delay		; every second apple the game speeds up
	cmpa #MIN_DELAY
	bls .slow
	dec delay
.slow	jsr show_score
	ldd len
	cmpd #WIN_LENGTH
	lbhs .win
	jsr new_food
.done	andcc #$FE
	rts
.win	ldd #0			; no room left for food: count it as the end
	std dir
.dead	orcc #1
	rts

* ---- food on a random empty cell ----
new_food	lda #FIELD_W
	jsr RAND_RANGE
	inca			; column 1-30
	sta tdigit
	lda #FIELD_H
	jsr RAND_RANGE
	adda #2			; row 2-14
	ldb #32
	mul
	addd #SCREEN
	std divisor		; row start address
	ldb tdigit
	clra
	addd divisor		; plus the column
	tfr d,x
	lda ,x
	cmpa #EMPTY
	bne new_food
	stx food
	lda #FOOD
	sta ,x
	rts

* ---- keyboard: the last arrow key wins, but no turning back on yourself ----
read_keys	jsr POLL
	bcc .end
	ldx #-32
	cmpa #$0B		; up
	beq .turn
	cmpa #'W'
	beq .turn
	cmpa #'w'
	beq .turn
	ldx #32
	cmpa #$0A		; down
	beq .turn
	cmpa #'S'
	beq .turn
	cmpa #'s'
	beq .turn
	ldx #-1
	cmpa #$08		; left
	beq .turn
	cmpa #'A'
	beq .turn
	cmpa #'a'
	beq .turn
	ldx #1
	cmpa #$09		; right
	beq .turn
	cmpa #'D'
	beq .turn
	cmpa #'d'
	beq .turn
	cmpa #$03		; BREAK
	bne read_keys
	lda #1
	sta quit
	rts
.turn	tfr x,d
	addd dir		; opposite direction: the sum is zero
	beq read_keys
	stx dir
	bra read_keys
.end	rts

drain	jsr POLL
	bcs drain
	rts

* ---- screen ----
draw_walls	ldx #SCREEN+32
	ldb #32
	lda #WALL
.top	sta ,x+
	decb
	bne .top
	ldx #SCREEN+15*32
	ldb #32
.bottom	sta ,x+
	decb
	bne .bottom
	ldx #SCREEN+2*32
	ldb #13
.side	sta ,x
	sta 31,x
	leax 32,x
	decb
	bne .side
	rts

show_score	lda #13
	ldb #0
	jsr LOCATE
	ldd score
	bsr print_dec
	rts

* D = 0-999 as three digits
print_dec	pshs d,x,y
	ldx #dectab
.next	ldy ,x++
	sty divisor
	clr tdigit
.sub	subd divisor
	bcs .digit
	inc tdigit
	bra .sub
.digit	addd divisor
	pshs d
	lda tdigit
	adda #'0'
	jsr PUTC
	puls d
	cmpx #dectab+6
	bne .next
	puls d,x,y,pc
dectab	fdb 100,10,1

txt_title	fcn "S N A K E"
txt_help1	fcn "ARROW KEYS OR WASD STEER"
txt_help2	fcn "EAT THE RED BLOCKS TO GROW"
txt_help3	fcn "BREAK QUITS"
txt_press	fcn "PRESS ANY KEY"
txt_score	fcn "SNAKE  SCORE"
txt_over	fcn "GAME OVER"
txt_again	fcn "ANY KEY: AGAIN"

	end
