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

* ---- GIME ----
INIT0		equ $FF90
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
