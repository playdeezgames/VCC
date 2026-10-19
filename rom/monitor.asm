* monitor.asm - the memory monitor. Commands (numbers are hex, '$' optional):
*
*   D [addr [len]]     dump memory, 8 bytes per line
*   M addr [byte...]   store bytes at addr (without bytes: show the byte there)
*   F start end byte   fill start..end inclusive
*   C src dst len      copy memory (overlap safe)
*   L drv trk sec adr [n]  read n sectors (default 1) into memory
*   W drv trk sec adr [n]  write n sectors from memory
*   B [drv]            boot: load and run the program described by track 0
*                      sector 1 (see below)
*   G addr             call addr; RTS or SWI returns to the monitor
*   S [loops periods]  sound: a tone (see sound.asm); plain S beeps
*   R                  show the registers saved when G came back or SWI hit
*   T                  show the tick counter
*   H or ?             help

monitor	lds #STACK_TOP
	clra
	tfr a,dp
.prompt	lda cursor+1		; start the prompt on a fresh line
	anda #$1F
	beq .at_start
	jsr newline
.at_start	lda #'>'
	jsr putc
	lbsr readline
	lbsr skipsp
	ldx lineptr
	lda ,x+
	beq .prompt		; empty line
	stx lineptr
	jsr upcase
	ldy #commands
.find	ldb ,y
	beq .unknown
	cmpa ,y
	beq .found
	leay 3,y
	bra .find
.found	jsr [1,y]
	bra .prompt
.unknown	lbsr syntax_error
	bra .prompt

commands	fcb 'D'
	fdb cmd_d
	fcb 'M'
	fdb cmd_m
	fcb 'F'
	fdb cmd_f
	fcb 'C'
	fdb cmd_c
	fcb 'G'
	fdb cmd_g
	fcb 'L'
	fdb cmd_l
	fcb 'W'
	fdb cmd_w
	fcb 'B'
	fdb cmd_b
	fcb 'S'
	fdb cmd_s
	fcb 'R'
	fdb cmd_r
	fcb 'T'
	fdb cmd_t
	fcb 'H'
	fdb cmd_h
	fcb '?'
	fdb cmd_h
	fcb 0

syntax_error	ldx #msg_error
	jsr puts
	rts
msg_error	fcb "?",13,0

* ---- line input ----
* Read a line with echo and backspace into LINEBUF (zero terminated).
readline	ldx #LINEBUF
.next	jsr getc
	cmpa #$0D
	beq .done
	cmpa #$08
	beq .back
	cmpa #$20
	blo .next
	cmpa #$7E
	bhi .next
	cmpx #LINEBUF+LINEMAX
	beq .next
	sta ,x+
	jsr putc
	bra .next
.back	cmpx #LINEBUF
	beq .next
	leax -1,x
	lda #$08
	jsr putc
	bra .next
.done	clr ,x
	jsr newline
	ldx #LINEBUF
	stx lineptr
	rts

* ---- parsing (position kept in lineptr) ----
upcase	cmpa #'a'
	blo .end
	cmpa #'z'
	bhi .end
	suba #$20
.end	rts

skipsp	pshs a,x
	ldx lineptr
.skip	lda ,x
	cmpa #$20
	bne .end
	leax 1,x
	bra .skip
.end	stx lineptr
	puls a,x,pc

* A = hex digit character -> A = 0-15 and carry set, or carry clear
hexval	bsr upcase
	cmpa #'0'
	blo .no
	cmpa #'9'
	bls .digit
	cmpa #'A'
	blo .no
	cmpa #'F'
	bhi .no
	suba #'A'-10
	orcc #1
	rts
.digit	suba #'0'
	orcc #1
	rts
.no	andcc #$FE
	rts

* Parse a hex number (optional leading '$'): D = value and carry set, or
* carry clear when there is no number.
parsehex	pshs x,y
	bsr skipsp
	ldx lineptr
	lda ,x
	cmpa #'$'
	bne .begin
	leax 1,x
.begin	ldy #0
	clr ndig
.digit	lda ,x
	bsr hexval
	bcc .end
	pshs a
	tfr y,d
	aslb
	rola
	aslb
	rola
	aslb
	rola
	aslb
	rola
	orb ,s+
	tfr d,y
	inc ndig
	leax 1,x
	bra .digit
.end	tst ndig
	beq .none
	stx lineptr
	tfr y,d
	orcc #1
	puls x,y,pc
.none	andcc #$FE
	puls x,y,pc

* ---- commands ----
cmd_d	lbsr parsehex
	bcc .nostart
	std lastdump
.nostart	lbsr parsehex
	bcs .haslen
	ldd #64
.haslen	std tmp1		; bytes left
	ldx lastdump
.line	ldd tmp1
	beq .end
	tfr x,d
	jsr puthex16
	lda #8
	sta tmp3
.byte	lda #' '
	jsr putc
	lda ,x+
	jsr puthex8
	ldd tmp1
	subd #1
	std tmp1
	beq .endline
	dec tmp3
	bne .byte
.endline	jsr newline
	bra .line
.end	stx lastdump
	rts

cmd_m	lbsr parsehex
	lbcc cmd_error
	tfr d,u
	clr tmp3
.next	lbsr parsehex
	bcc .end
	stb ,u+
	inc tmp3
	bra .next
.end	tst tmp3
	bne .ret
	lda ,u			; no bytes given: show the current one
	jsr puthex8
	jsr newline
.ret	rts

cmd_error	jmp syntax_error

cmd_f	lbsr parsehex
	lbcc cmd_error
	std tmp1
	lbsr parsehex
	lbcc cmd_error
	std tmp2
	lbsr parsehex
	lbcc cmd_error
	stb tmp3
	ldd tmp1
	cmpd tmp2
	lbhi cmd_error
	ldx tmp1
	lda tmp3
.fill	sta ,x
	cmpx tmp2
	beq .end
	leax 1,x
	bra .fill
.end	rts

cmd_c	lbsr parsehex
	lbcc cmd_error
	std tmp1		; source
	lbsr parsehex
	lbcc cmd_error
	std tmp2		; destination
	lbsr parsehex
	lbcc cmd_error
	std tmp3		; length
	beq .end
	ldy tmp1
	ldu tmp2
	ldx tmp3
	ldd tmp2
	cmpd tmp1
	bls .forward		; destination below source
	subd tmp1
	cmpd tmp3
	bhs .forward		; far enough above: no overlap
	ldd tmp1		; overlap: copy from the top down
	addd tmp3
	subd #1
	tfr d,y
	ldd tmp2
	addd tmp3
	subd #1
	tfr d,u
.back	lda ,y
	sta ,u
	leay -1,y
	leau -1,u
	leax -1,x
	bne .back
	rts
.forward	lda ,y+
	sta ,u+
	leax -1,x
	bne .forward
.end	rts

cmd_g	lbsr parsehex
	lbcc cmd_error
	tfr d,x
	jsr ,x
* back from the routine: keep its registers for R (it may have changed DP)
	pshs dp,a,cc
	clra
	tfr a,dp
	stb regb
	stx regx
	sty regy
	stu regu
	puls a
	sta regcc
	puls a
	sta rega
	puls a
	sta regdp
	rts

cmd_r	ldx #msg_a
	jsr puts
	lda rega
	jsr puthex8
	ldx #msg_b
	jsr puts
	lda regb
	jsr puthex8
	ldx #msg_dp
	jsr puts
	lda regdp
	jsr puthex8
	ldx #msg_cc
	jsr puts
	lda regcc
	jsr puthex8
	jsr newline
	ldx #msg_x
	jsr puts
	ldd regx
	jsr puthex16
	ldx #msg_y
	jsr puts
	ldd regy
	jsr puthex16
	ldx #msg_u
	jsr puts
	ldd regu
	jsr puthex16
	jsr newline
	rts
msg_a	fcb "A=",0
msg_b	fcb " B=",0
msg_dp	fcb " DP=",0
msg_cc	fcb " CC=",0
msg_x	fcb "X=",0
msg_y	fcb " Y=",0
msg_u	fcb " U=",0

cmd_t	ldx #msg_ticks
	jsr puts
	ldd ticks
	jsr puthex16
	ldd ticks+2
	jsr puthex16
	jsr newline
	rts
msg_ticks	fcb "TICKS ",0

cmd_h	ldx #help
	jsr puts
	rts
help	fcb "D [ADDR [LEN]]  DUMP",13
	fcb "M ADDR [BYTE..] STORE/SHOW",13
	fcb "F START END BYTE  FILL",13
	fcb "C SRC DST LEN     COPY",13
	fcb "L/W DRV TRK SEC ADR [N]",13
	fcb "B [DRV]   BOOT FROM DISK",13
	fcb "G ADDR   CALL (RTS/SWI BACK)",13
	fcb "R REGISTERS  T TICKS  S BEEP",13
	fcb "NUMBERS ARE HEX",13,0

cmd_s	lbsr parsehex
	bcs .tone
	jmp beep
.tone	tfr d,u			; loops
	lbsr parsehex
	lbcc cmd_error
	tfr d,y			; periods
	tfr u,x
	jmp tone

* ---- disk commands ----
cmd_l	clr argop
	bra disk_cmd
cmd_w	lda #1
	sta argop
disk_cmd	lbsr parsehex
	lbcc cmd_error
	tsta
	lbne cmd_error
	cmpb #3
	lbhi cmd_error
	stb argdrv
	lbsr parsehex
	lbcc cmd_error
	tsta
	lbne cmd_error
	stb argtrk
	lbsr parsehex
	lbcc cmd_error
	tsta
	lbne cmd_error
	tstb
	lbeq cmd_error
	cmpb #SECTORS
	lbhi cmd_error
	stb argsec
	lbsr parsehex
	lbcc cmd_error
	std argadr
	lbsr parsehex
	bcs .count
	ldd #1
.count	std argcnt
	lbeq cmd_error
	lbsr disk_run
	bcs disk_report
	rts

* Print the disk error code in A.
disk_report	pshs a
	ldx #msg_diskerr
	jsr puts
	puls a
	jsr puthex8
	jsr newline
	rts
msg_diskerr	fcb "DISK ERROR ",0

* Transfer argcnt sectors between the disk (argdrv, argtrk, argsec) and memory
* (argadr), one sector after the other; sector 18 is followed by sector 1 of
* the next track. Carry set and A = error code on failure.
disk_run	ldd argcnt
	beq .ok
	ldx argadr
	ldb argsec
	clra
	tfr d,y
	lda argdrv
	ldb argtrk
	tst argop
	bne .write
	jsr disk_read
	bra .done
.write	jsr disk_write
.done	bcs .end
	ldd argadr
	adda #1			; next 256 bytes
	std argadr
	inc argsec
	lda argsec
	cmpa #SECTORS+1
	blo .same
	lda #1
	sta argsec
	inc argtrk
.same	ldd argcnt
	subd #1
	std argcnt
	bra disk_run
.ok	andcc #$FE
.end	rts

* ---- boot ----
* Track 0 sector 1 is the boot sector:
*   +0  'O','B'   signature
*   +2  load address (word)
*   +4  number of sectors to load (0-17), taken from track 0 sectors 2...
*   +5  entry address (word)
* The monitor calls the entry address (JSR); RTS comes back to the prompt.
BOOT_SIG	equ $4F42

cmd_b	lbsr parsehex
	bcs .drive
	ldd #0
.drive	tsta
	lbne cmd_error
	cmpb #3
	lbhi cmd_error
	stb argdrv
	clr argop
	clr argtrk
	lda #1
	sta argsec
	ldd #BOOT_BUF
	std argadr
	ldd #1
	std argcnt
	lbsr disk_run
	lbcs disk_report
	ldx #BOOT_BUF
	ldd ,x
	cmpd #BOOT_SIG
	bne .noboot
	ldd 2,x
	std argadr
	ldd 5,x
	std bootent
	lda 4,x
	cmpa #SECTORS-1
	bhi .noboot
	clr argcnt
	sta argcnt+1
	lda #2
	sta argsec
	lbsr disk_run
	lbcs disk_report
	ldx bootent
	jsr ,x
	rts
.noboot	ldx #msg_noboot
	jsr puts
	rts
msg_noboot	fcb "NO BOOT",13,0

* SWI (from a program started with G, or a breakpoint): save the registers
* of the interrupted program and go back to the prompt.
swi_handler	clra
	tfr a,dp
	lda ,s
	sta regcc
	lda 1,s
	sta rega
	lda 2,s
	sta regb
	lda 3,s
	sta regdp
	ldx 4,s
	stx regx
	ldx 6,s
	stx regy
	ldx 8,s
	stx regu
	ldx 10,s
	leax -1,x		; the SWI opcode itself
	stx regpc
	andcc #$AF		; the SWI masked IRQ and FIRQ; leave FIRQ off
	andcc #$EF
	ldx #msg_swi
	jsr puts
	ldd regpc
	jsr puthex16
	jsr newline
	jmp monitor
msg_swi	fcb "SWI AT ",0
