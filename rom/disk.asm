* disk.asm - FD-502 floppy driver (WD1793 behind $FF40/$FF48-$FF4B), polled.
*
* Public routines (single sided disks, 256 byte sectors, sectors numbered
* from 1; DECB geometry is 35 tracks of 18 sectors):
*
*   disk_read   A = drive (0-3), B = track, Y = sector, X = buffer
*   disk_write  same registers; writes the 256 bytes at X
*     Both return carry clear on success. On failure carry is set and A is
*     one of the DE_ codes below. All registers except A and CC are kept. The
*     interrupt mask is raised during the transfer and restored at the end.
*
* The motor starts on first use (a fixed delay stands in for the spin-up) and
* stops by itself after DISK_IDLE ticks of inactivity (disk_tick, called from
* the IRQ handler). A drive whose head position is unknown is restored to
* track 0 before the first seek.
*
* $FF40 is written with drive | motor ($08) | density ($20), the value Disk
* BASIC uses (POKE 65344,41 starts drive 0).

DE_TIMEOUT	equ 1		; the controller did not finish
DE_NOTFOUND	equ 2		; sector not found (no disk, bad sector number, no controller)
DE_CRC		equ 3
DE_LOST		equ 4		; lost data
DE_PROTECT	equ 5		; write protected
DE_FAULT	equ 6		; write fault
DE_BADARG	equ 7		; drive out of range

CMD_RESTORE	equ $02		; restore, 20 ms steps
CMD_SEEK	equ $12
CMD_READ	equ $80
CMD_WRITE	equ $A0
CMD_RESET	equ $D0		; force interrupt: abort the current command

disk_init	lda #$FF
	ldx #dsktrk
	sta ,x+
	sta ,x+
	sta ,x+
	sta ,x
	clr dskctl
	clr dskbusy
	lda #0
	sta FDC_CTRL		; all drives off
	rts

* Called every tick: stop the motor after a while without use.
disk_tick	tst dskbusy
	bne .end
	tst dskctl
	beq .end
	dec dskidle
	bne .end
	clr dskctl
	lda #0
	sta FDC_CTRL
.end	rts

drive_bits	fcb $01,$02,$04,$40	; $FF40 select bit of drives 0-3

* A = drive: select it and start the motor (waits for spin-up if it was off).
select_drive	cmpa #3
	bhi .bad
	sta dskarg
	ldx #drive_bits
	ldb a,x
	orb #$28		; motor + density
	lda dskctl		; non-zero: the motor already runs
	stb dskctl
	stb FDC_CTRL
	tsta
	bne .running
	ldx #0			; spin-up: 65536 loops, about half a second
.spin	leax -1,x
	bne .spin
.running	lda #DISK_IDLE
	sta dskidle
	andcc #$FE
	rts
.bad	lda #DE_BADARG
	orcc #1
	rts

* Wait for the controller to leave BUSY. A = status; carry set (A = DE_TIMEOUT)
* when it never does.
wait_done	ldx #0
.poll	lda FDC_STATUS
	bita #1
	beq .done
	leax -1,x
	bne .poll
	lda #CMD_RESET
	sta FDC_CMD
	lda #DE_TIMEOUT
	orcc #1
	rts
.done	andcc #$FE
	rts

* Head to track 0.
restore	lda #CMD_RESTORE
	sta FDC_CMD
	bsr wait_done
	bcs .end
	bita #$04		; track 0 sensor
	bne .at0
	lda #DE_NOTFOUND
	orcc #1
	rts
.at0	ldx #dsktrk
	ldb dskarg
	lda #0
	sta b,x
	andcc #$FE
.end	rts

* B = track: move the head there (restoring first if the position is unknown).
seek	ldx #dsktrk
	ldb dskarg
	abx			; X -> head position of this drive
	lda ,x
	cmpa #$FF
	bne .known
	pshs x
	bsr restore
	puls x
	bcs .end
	lda ,x
.known	cmpa dsktgt
	beq .there
	sta FDC_TRACK		; where the chip thinks the head is
	lda dsktgt
	sta FDC_DATA		; where it should go
	lda #CMD_SEEK
	sta FDC_CMD
	pshs x
	bsr wait_done
	puls x
	bcs .end
	bita #$10		; seek error
	bne .notfound
	lda dsktgt
	sta ,x
.there	lda dsktgt
	sta FDC_TRACK
	andcc #$FE
	rts
.notfound	lda #DE_NOTFOUND
	orcc #1
.end	rts

* Seek to dsktgt and load the sector register with dsksec (drive selected).
prepare	lbsr seek
	bcs .end
	lda dsksec
	sta FDC_SECTOR
	andcc #$FE
.end	rts

* A = status after a sector command -> carry/A. B = mask of error bits to look at.
status_error	pshs b
	anda ,s+
	beq .ok
	bita #$40
	bne .protect
	bita #$20
	bne .fault
	bita #$10
	bne .notfound
	bita #$08
	bne .crc
	lda #DE_LOST
	bra .fail
.protect	lda #DE_PROTECT
	bra .fail
.fault	lda #DE_FAULT
	bra .fail
.notfound	lda #DE_NOTFOUND
	bra .fail
.crc	lda #DE_CRC
.fail	orcc #1
	rts
.ok	andcc #$FE
	rts

* Common exit: A = code and carry (set on error). Restores the registers
* and the caller's interrupt mask; the carry the caller sees is the result.
disk_leave	sta dskerr		; (STA keeps the carry)
	bcs .failed
	lda ,s
	anda #$FE
	sta ,s
	bra .out
.failed	lda ,s
	ora #$01
	sta ,s
.out	clr dskbusy
	lda #DISK_IDLE
	sta dskidle
	puls cc,b,x,y,u
	lda dskerr
	rts

disk_read	pshs cc,b,x,y,u
	sta dskarg
	stb dsktgt
	sty dsktmp
	lda dsktmp+1
	sta dsksec
	stx dskbuf
	inc dskbusy
	lda dskarg
	lbsr select_drive	; (may wait for the motor, interrupts still on)
	bcs disk_leave
	orcc #$10		; from here on no interrupts: the controller needs the CPU
	lbsr prepare
	bcs disk_leave
	ldx dskbuf
	ldy #0			; polls without data before giving up
	lda #CMD_READ
	sta FDC_CMD
.poll	lda FDC_STATUS
	bita #2			; DRQ: a byte is ready
	beq .nodrq
	lda FDC_DATA
	sta ,x+
	bra .poll
.nodrq	bita #1			; BUSY
	beq .finished
	leay -1,y
	bne .poll
	lda #CMD_RESET
	sta FDC_CMD
	lda #DE_TIMEOUT
	orcc #1
	bra disk_leave
.finished	cmpx dskbuf
	beq .nodata		; nothing arrived: no controller or no such sector
	lda FDC_STATUS
	ldb #$1C		; record not found, CRC, lost data
	lbsr status_error
	bra disk_leave
.nodata	lda #DE_NOTFOUND
	orcc #1
	bra disk_leave

disk_write	pshs cc,b,x,y,u
	sta dskarg
	stb dsktgt
	sty dsktmp
	lda dsktmp+1
	sta dsksec
	stx dskbuf
	inc dskbusy
	lda dskarg
	lbsr select_drive
	lbcs disk_leave
	orcc #$10
	lbsr prepare
	lbcs disk_leave
	ldx dskbuf
	ldy #0
	lda #CMD_WRITE
	sta FDC_CMD
.poll	lda FDC_STATUS
	bita #2
	beq .nodrq
	ldb ,x+
	stb FDC_DATA
	bra .poll
.nodrq	bita #1
	beq .finished
	leay -1,y
	bne .poll
	lda #CMD_RESET
	sta FDC_CMD
	lda #DE_TIMEOUT
	orcc #1
	lbra disk_leave
.finished	cmpx dskbuf
	beq .nodata
	lda FDC_STATUS
	ldb #$7C		; protect, fault, record not found, CRC, lost data
	lbsr status_error
	lbra disk_leave
.nodata	lda #DE_NOTFOUND
	orcc #1
	lbra disk_leave
