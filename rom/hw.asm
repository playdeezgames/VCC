* hw.asm - hardware addresses and the RAM layout used by the ROM.
*
* Sources: docs/GimeRegisters.txt, the MC6821 and MC6809E datasheets and the
* emulator's own source. Nothing here is taken from any other ROM.

* ---- RAM map (CPU view, MMU off) ----
*   $0000-$00FF  direct page: ROM variables
*   $0100-$011F  interrupt hook table (JMP slots, see below)
*   $0120-$01FF  more ROM state
*   $0200-$03FF  input buffer and system stack (grows down from $03FF)
*   $0400-$05FF  32x16 VDG text screen
*   $0600-$7FFF  free RAM
*   $8000-$BFFF  this ROM
*   $C000-$FEFF  cartridge ROM space
*   $FF00-$FFFF  I/O and interrupt vectors

STACK_TOP	equ $03FF
SCREEN		equ $0400
SCREEN_END	equ $0600
COLS		equ 32
ROWS		equ 16
BLANK		equ $60		; VDG code of a normal-video space

* ---- interrupt hook table: one 3 byte JMP per source; the ROM vectors point here ----
HOOK_SWI3	equ $0100
HOOK_SWI2	equ $0103
HOOK_SWI	equ $0106
HOOK_NMI	equ $0109
HOOK_IRQ	equ $010C
HOOK_FIRQ	equ $010F
HOOK_END	equ $0112

* ---- PIA0: keyboard, joystick comparator, HSYNC (CA1) and VSYNC (CB1) ----
PIA0_DA		equ $FF00	; keyboard rows in (also DDRA when CRA bit 2 = 0)
PIA0_CRA	equ $FF01
PIA0_DB		equ $FF02	; keyboard columns out
PIA0_CRB	equ $FF03

* ---- PIA1: DAC, cassette, VDG mode, single bit sound, cartridge FIRQ ----
PIA1_DA		equ $FF20	; bits 7-2: 6 bit DAC
PIA1_CRA	equ $FF21
PIA1_DB		equ $FF22	; bits 7-3: VDG A/G, GM2-GM0, CSS; bit 1: sound
PIA1_CRB	equ $FF23

* ---- FD-502 floppy controller: latch at $FF40, WD1793 at $FF48 ----
FDC_CTRL	equ $FF40	; write only: bits 0-2 drive 0-2, 3 motor, 5 density, 6 drive 3
FDC_CMD		equ $FF48	; command (write) / status (read)
FDC_STATUS	equ $FF48
FDC_TRACK	equ $FF49
FDC_SECTOR	equ $FF4A
FDC_DATA	equ $FF4B

* ---- GIME ----
INIT0		equ $FF90	; bit 7 CoCo mode, 6 MMU, 3 vector RAM, 2 standard SCS (disk), 1-0 ROM map
INIT1		equ $FF91
IRQENR		equ $FF92
FIRQENR		equ $FF93
TIMERH		equ $FF94
TIMERL		equ $FF95
VMODE		equ $FF98
VRES		equ $FF99
BORDER		equ $FF9A
VBANK		equ $FF9B
VSCROLL		equ $FF9C
VOFFH		equ $FF9D	; video start / 8 in physical RAM (high byte)
VOFFL		equ $FF9E
HOFFSET		equ $FF9F
MMU_T0		equ $FFA0	; task 0 bank registers, 8 bytes
MMU_T1		equ $FFA8	; task 1
PALETTE		equ $FFB0	; 16 palette registers

* ---- SAM: writing any value to an address sets (odd) or clears (even) a bit ----
SAM_V0		equ $FFC0
SAM_F0		equ $FFC6
SAM_F1		equ $FFC8
SAM_P1		equ $FFD4
SAM_R0		equ $FFD6
SAM_R1		equ $FFD8
SAM_M0		equ $FFDA
SAM_M1		equ $FFDC
SAM_TY		equ $FFDE

* ---- ROM variables (direct page; the ROM runs with DP = 0) ----
	setdp 0
cursor		equ $00		; fdb: address of the cursor cell on the screen
under		equ $02		; fcb: the screen byte hidden under the cursor
curvis		equ $03		; fcb: 1 while the cursor is drawn
cblock		equ $04		; fcb: non-zero while putc/cls change the screen (no blinking)
ticks		equ $05		; 4 bytes, big endian: 60 Hz interrupt count
blinkcnt	equ $09		; fcb: ticks until the cursor toggles
kbhead		equ $0A		; fcb: key ring buffer read index
kbtail		equ $0B		; fcb: write index
caps		equ $0C		; fcb: 1 = letters come out upper case unshifted (CoCo style)
rptkey		equ $0D		; fcb: key id being repeated, $FF = none
rptcnt		equ $0E		; fcb: ticks until the next repeat
kbcur		equ $10		; 8 bytes: this scan, one byte of row bits per column
kbprev		equ kbcur+8	; the scan before
kbstab		equ kbcur+16	; keys seen in two scans in a row (debounced)
kbnew		equ kbcur+24	; keys that became stable in this scan
lineptr		equ $30		; fdb: parse position in the input line
lastdump	equ $32		; fdb: next address for D
rega		equ $34		; registers saved after G / SWI
regb		equ $35
regdp		equ $36
regcc		equ $37
regx		equ $38		; fdb
regy		equ $3A		; fdb
regu		equ $3C		; fdb
regpc		equ $3E		; fdb
tmp1		equ $40		; fdb scratch
tmp2		equ $42		; fdb
tmp3		equ $44		; fdb
ndig		equ $46		; fcb
dskctl		equ $47		; fcb: shadow of the $FF40 latch, 0 = motor off
dskarg		equ $48		; fcb: drive of the current operation
dsktrk		equ $49		; 4 bytes: head track per drive, $FF = unknown
dskbusy		equ $4D		; fcb: non-zero while a disk operation runs
dskidle		equ $4E		; fcb: ticks until the motor is switched off
dsktgt		equ $4F		; fcb: track wanted
dsksec		equ $50		; fcb: sector wanted
dskbuf		equ $51		; fdb: transfer address
argdrv		equ $53		; monitor disk command arguments
argtrk		equ $54
argsec		equ $55
argop		equ $56		; 0 = read, 1 = write
argadr		equ $57		; fdb
argcnt		equ $59		; fdb
dskerr		equ $5B		; fcb: result code of the last disk call
bootent		equ $5C		; fdb: entry address from a boot sector
dsktmp		equ $5E		; fdb: scratch of the disk driver
kbt1		equ $60		; scratch of the IRQ handler (never shared with foreground code)
kbt2		equ $61
kbt3		equ $62

KBBUF		equ $0120	; 16 byte key ring buffer
LINEBUF		equ $0200	; input line, LINEMAX characters plus a terminator
LINEMAX		equ 60
BOOT_BUF	equ $0700	; sector read by the B command
SECTORS		equ 18		; sectors per track (DECB geometry, single sided)
DISK_IDLE	equ 180		; ticks (3 s) without disk use before the motor stops
BLINK_PERIOD	equ 30		; ticks between cursor toggles
