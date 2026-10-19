# Open ROM for the CoCo 3

An original boot ROM and monitor for the Tandy Color Computer 3 and the Odin
VCC emulator. It is written from hardware documentation (`docs/GimeRegisters.txt`,
the MC6809E and MC6821 data sheets, the Technical Field Guide) and from the
behaviour of the emulator in `odin/`. No code, data tables or strings were
taken from `coco3.rom` or `disk11.rom`; they are never disassembled for this
project. License: GPLv3 like the rest of the repository.

It is a monitor, not BASIC: it initialises the machine, runs a text console,
reads the keyboard, loads and runs programs from a floppy disk or cassette,
reads the joysticks and makes sound. `coco3.rom` keeps working exactly as before (`--rom` takes any 32K image).

## Build and run

```
odin build odin/tools/asm6809 -out:asm6809
./asm6809 rom/boot.asm -o rom/ourrom.rom -l rom/ourrom.lst -s rom/ourrom.sym
odin build odin -out:vcc
./vcc --rom rom/ourrom.rom --new-disk work.dsk
```

(`odin run odin/tools/asm6809 -- rom/boot.asm -o rom/ourrom.rom` does the first
two steps.) `odin test odin` assembles the sources in memory and boots them.

Files: `boot.asm` (entry points, reset sequence, vectors, init tables),
`hw.asm` (equates, RAM map), `console.asm`, `keyboard.asm`, `disk.asm`,
`sound.asm`, `monitor.asm`, `hello.asm` (the smallest possible ROM, a demo).

## Memory map (CPU view, MMU off)

| Address | Use |
|---|---|
| `$0000-$00FF` | direct page: ROM variables (`hw.asm`). The ROM assumes **DP = 0** |
| `$0100-$0111` | interrupt hook table, six `JMP` slots (below) |
| `$0120-$012F` | key ring buffer |
| `$0130-$013E` | tape file header record; `$0140-$0147` the name typed for `I` |
| `$0200-$023B` | monitor input line (60 characters + terminator) |
| `$0200-$03FF` | the system stack grows down from `$03FF` |
| `$0400-$05FF` | 32 x 16 VDG text screen |
| `$0600-$06FF` | free; `$0700-$07FF` is the sector buffer of the `B` command |
| `$0800-$7FFF` | free RAM |
| `$8000-$BFFF` | this ROM (jump table at `$8000`) |
| `$C000-$FEFF` | cartridge ROM space (not used by the ROM) |
| `$FF00-$FFFF` | I/O and interrupt vectors |

The ROM lives in the lower 16K so cartridges stay visible. The text screen is
at physical `$70400`: the GIME video start register is set to `$E000` (x8) and
the SAM display offset to `$0400`.

### Interrupt hooks

The CPU vectors at `$FFF2-$FFFE` point straight into RAM; each slot holds a
`JMP`, initially to an `RTI`. Replace the address (slot + 1) to take over an
interrupt:

| Slot | Source | Default |
|---|---|---|
| `$0100` | SWI3 | RTI |
| `$0103` | SWI2 | RTI |
| `$0106` | SWI | monitor: save registers, return to the prompt |
| `$0109` | NMI | RTI |
| `$010C` | IRQ | 60 Hz tick, keyboard scan, cursor blink, disk motor timeout |
| `$010F` | FIRQ | RTI (FIRQ stays masked) |

A replacement IRQ handler should end by jumping to the old one, or else the
keyboard, the cursor and the motor timeout stop working.

## Public routines

A fixed jump table starts at `$8000`; call these with `JSR`. DP must be 0.

| Address | Name | In | Out / notes |
|---|---|---|---|
| `$8000` | reset | | restart the machine |
| `$8003` | cls | | clear the screen, cursor home |
| `$8006` | putc | A = character | all registers kept. CR new line, BS ($08) back up and erase, FF ($0C) clear, BEL ($07) beep, other controls ignored. Lower case is shown as inverse upper case |
| `$8009` | puts | X -> zero terminated string | X returns past the zero |
| `$800C` | newline | | |
| `$800F` | puthex8 | A | two hex digits |
| `$8012` | puthex16 | D | four hex digits |
| `$8015` | getc | | A = key; waits (sleeping in SYNC) so the IRQ mask must be clear. Clobbers nothing but A |
| `$8018` | poll | | carry set and A = key, or carry clear. Clobbers B and X |
| `$801B` | disk_read | A = drive 0-3, B = track, Y = sector (1-18), X = buffer | carry clear on success; else carry set and A = error code. All registers but A and CC kept |
| `$801E` | disk_write | same | writes the 256 bytes at X |
| `$8021` | beep | | about 1 kHz for 0.1 s |
| `$8024` | tone | X = loops per half period, Y = periods | masks interrupts while it runs; all registers kept |
| `$8027` | joy_axis | A = axis (0 right X, 1 right Y, 2 left X, 3 left Y) | A = position 0-63 (centre about 32; a stick that is not there reads 0). Masks interrupts briefly |
| `$802A` | joy_buttons | | A = pressed buttons: bit 0 right 1, bit 1 left 1, bit 2 right 2, bit 3 left 2 |
| `$802D` | tape_save | X -> 15 byte header record | writes the header and `count` bytes from `load`; carry set + A = error on failure |
| `$8030` | tape_load | X -> 8 byte name (first byte 0: any), Y = load address (0: the file's) | loads the file, leaves its header at `$0130`; carry set + A = error |
| `$8033` | rand | | D = next pseudo random value, 1-65535 (16 bit xorshift, full period; the same sequence for the same seed) |
| `$8036` | rand_seed | D = state | 0 is replaced by a fixed non-zero value. The state starts at `$ACE1` and is also stirred with the tick counter on every key press, so programs that wait for the user get a different sequence each run |
| `$8039` | rand_range | A = n | A = a value in 0..n-1 (n = 0 means 256); scaled from the high byte of `rand`. Preserves B |
| `$803C` | locate | A = column 0-31, B = row 0-15 | moves the text cursor (out of range values are clamped); all registers kept |

Tape error codes: 1 no signal (or the tape ended), 2 checksum, 4 BREAK pressed
while waiting. Tape routines mask interrupts while they run and switch the
motor on only for that time.

Disk error codes: 1 timeout, 2 sector not found (no disk, bad sector, no
controller), 3 CRC, 4 lost data, 5 write protected, 6 write fault, 7 bad drive.

### Key codes

Letters are upper case unless SHIFT is held (like a real CoCo); SHIFT-0 toggles
that. Digits and punctuation follow the CoCo keyboard (SHIFT-2 is `"`, SHIFT-`-`
is `=`, SHIFT-`;` is `+` ...). Special keys: ENTER `$0D`, BREAK `$03`, CLEAR
`$0C`, UP `$0B`, DOWN `$0A`, LEFT `$08`, RIGHT `$09`, F1 `$81`, F2 `$82`; CTRL
with a letter gives the control code.

## Monitor

Prompt `>`. Numbers are hexadecimal (an optional `$` prefix is accepted), commands
and digits may be upper or lower case.

| Command | Action |
|---|---|
| `D [addr [len]]` | dump memory, 8 bytes per line, default 64 bytes continuing from the last dump |
| `M addr [byte ...]` | store bytes; without bytes show the byte there |
| `F start end byte` | fill `start`..`end` inclusive |
| `C src dst len` | copy (overlap safe) |
| `G addr` | call `addr`; RTS or SWI returns to the prompt |
| `R` | registers saved when `G` returned or an SWI hit |
| `T` | tick counter (60 per second) |
| `L drv trk sec adr [n]` | read `n` sectors (default 1) to memory; sector 18 is followed by sector 1 of the next track |
| `W drv trk sec adr [n]` | write sectors from memory |
| `B [drv]` | boot (below) |
| `S [loops periods]` | sound; plain `S` beeps |
| `N [count]` | print `count` random numbers (default 8) |
| `J` | joystick axes (0-3F) and buttons |
| `O name start len [entry]` | write memory to tape as file `name` (8 characters) |
| `I [name [addr]]` | read a file from tape (`*` or no name: the first one; `addr` overrides the load address). Prints `FOUND name` for every file it sees and `LOAD .. LEN .. ENTRY ..` at the end. BREAK abandons the wait |
| `H` or `?` | help |

An error prints `?` (bad command or arguments) or `DISK ERROR nn`.

### Boot sector

Track 0, sector 1 (single sided, 256 byte sectors):

| Offset | Content |
|---|---|
| 0-1 | `'O' 'B'` |
| 2-3 | load address |
| 4 | number of sectors to load (0-17), read from track 0 sectors 2... |
| 5-6 | entry address |

`B` loads the sectors and calls the entry address with `JSR`; an `RTS` returns
to the prompt. A disk without the signature prints `NO BOOT`.

### Tape format

FSK at roughly 1200 Hz (a 1 bit) and 2400 Hz (a 0 bit), one cycle per bit,
eight stepped sine values per cycle through the DAC; bytes are sent least
significant bit first. A block is: leader of `$55` bytes (128 before the first
block, 8 before the others), `$3C`, type, length, data, checksum (sum of type,
length and data, modulo 256), `$55`. Type 0 is the file header (name[8], kind
`'M'`, load address, byte count, entry address; 15 bytes), type 1 holds up to 255
data bytes, type `$FF` ends the file. The reader measures every cycle against a
threshold half way between the two tones, so it tolerates tape speed changes.
The block layout follows the platform's usual cassette convention (leader, sync,
type, length, checksum), but interchange with BASIC's own files has not been
tried: the header fields here are this ROM's own. What the test suite does
check is the emulated cassette itself, with the real Color BASIC's `CSAVE` and
`CLOAD` (when `coco3.rom` is present), and a save/load round trip of this ROM.

## Programs

`programs/` holds programs for the ROM, written against the jump table.
`odin build odin/tools/mkboot -out:mkboot && ./mkboot programs/snake.asm programs/snake.dsk`
(or `programs/build.sh`) assembles one and writes a disk whose boot sector
loads it; start it with `B` at the prompt:

```
./vcc --rom rom/ourrom.rom --disk0 programs/snake.dsk
```

* `snake.asm`: Snake on the text screen (arrow keys or WASD, eat the red
  blocks, each one makes the snake three cells longer; BREAK quits). It uses `locate`, `puts`, `poll`, `getc`, `rand_range`
  and `tone`, writes screen codes (semigraphics blocks) straight to `$0400`,
  keeps its state at `$0F00` and the body queue at `$1000`.

### A ROM that boots into a program

`rom/snakerom.asm` defines `AUTOSTART` and includes `boot.asm`, which then
includes `programs/snake.asm` into the ROM and calls its `start` instead of
printing the banner. BREAK ends the game and drops into the monitor as usual:

```
./asm6809 rom/snakerom.asm -o rom/snake.rom
./vcc --rom rom/snake.rom
```

## Hardware notes and assumptions

* GIME `INIT0` = `$84`: CoCo 1/2 compatible video, MMU off, vectors in ROM,
  standard SCS (needed for the disk controller), ROM map 0. The MMU bank
  registers are preloaded with the identity map of the top 64K (`$38-$3F`).
* Palette: the documented power-up composite values; SAM: text mode, display
  offset `$0400`, slow clock, map type 0.
* PIA0 `$FF01/$FF03` = `$34` then `$35` for the vertical sync (60 Hz) IRQ.
  The keyboard is scanned once per tick; a key must be seen in two scans.
* FD-502: `$FF40` = drive bit | `$08` motor | `$20` density, the value Disk
  BASIC uses (`POKE 65344,41` for drive 0); `$FF40` bit 5 also enables the NMI
  at command completion in the emulator, which the ROM ignores (the NMI hook is
  an RTI). The spin-up wait is a fixed delay of about half a second. Sector
  transfers run with interrupts masked and poll DRQ/BUSY.
* The emulated FD-502 ends a sector read/write with the last data byte, like
  the real WD1793. Not yet verified on real hardware.
* Joystick: the stick's position is found by successive approximation on the
  DAC (6 comparisons), with the analog multiplexer set through the CA2 and CB2
  bits of PIA0 and put back to the sound source afterwards. A pressed button
  also shows up as a pressed key in the matrix (row 0-3, every column), exactly
  as on the real machine, so do not hold one while typing.
* Tape: the DAC drives the cassette output while the multiplexer is on the
  sound source and the sound enable (CB2 of PIA1) is low; the motor is PIA1 CA2.
  Real tape recorders need level adjustment; the write levels swing about `$80`
  by +-`$2C`, which is what the emulator's WAV output uses.
* No RAM sizing is done; the ROM assumes at least 64K behind the CPU's low
  32K, and uses only the bottom 2K of it.

## Not done yet

BASIC (out of scope), .CAS files, 40/80 column and graphics helpers, RAM sizing and
MMU paging helpers, a file system, interrupt-driven disk I/O.
