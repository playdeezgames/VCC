# Odin port backlog

Work that was deliberately left out so far. Roughly in priority order within each group.

## Platforms
- **WebAssembly build** alongside the native SDL client (Odin `js_wasm32`, canvas + Web Audio, keyboard/mouse
  and file input from the browser for ROM and disk images). Needs the machine core kept free of OS calls
  (file access and timing only in `main.odin`, `audio.odin`, `disk/`), a JS shim for video/audio/input, and
  a way to supply ROMs and disk images without the filesystem (user-picked files, or our own ROM built in).
  The custom ROM work (branch `custom-rom`) makes this practical, since `coco3.rom` cannot be shipped.

## Bugs / polish
- **Audio popping** (reported 2026-10-18): the pop on every start came from a DC step (silence -> centred
  level) in `dac_sample`; fixed with a 10 Hz high-pass filter primed at the current level, plus a fade-out on
  pause. Queue under-runs were measured (`--audio-stats`: none) and the output captured with SDL's disk audio
  driver (`SDL_AUDIODRIVER=disk`). If pops are still heard: look at note boundaries in BASIC `SOUND`/`PLAY`
  (each ends with a DAC step) and at the 44.1 kHz sample-and-hold of fast DAC changes (no anti-aliasing).
- **Paste while BASIC is busy.** BASIC ignores keys typed during a disk command (SAVE/LOAD/DSKINI), so a pasted
  program with disk commands loses characters. Idea: after Enter, wait until the CPU polls the keyboard again
  (count PIA0 `$FF00` reads) instead of a fixed delay.
- Scanline-gap option and window scaling controls (VCC `ScanLines`).

## Disks (FD-502 is JVC/DSK only for now)
- **VDK images** (12 byte header; sides at byte 9).
- **OS-9 raw images** (headerless; geometry and side count from LSN0: total sectors in bytes 0-2, sectors
  per track at byte 3, side bit at byte 16).
- **DMK images** (16 byte header, IDAM pointer tables, CCITT CRC; also needed for copy-protected disks and
  for a real READ TRACK). `ccitt_crc16` and `GetSectorInfo` in `FD502/wd1793.cpp` are the references.
- Multi-sector read/write (the READSECTORM/WRITESECTORM variants behave like single sector, as in VCC).
- Physical floppy access (`*Floppy A:`, uses fdrawcmd on Windows; not portable).
- FD-502 real-time clock at `$FF50/$FF51`, and the Becker port (`$FF41/$FF42`, DriveWire over TCP).
- Mounting UI beyond CLI/drag-and-drop (menu), write-protect toggle, persistent mounts.
- Virtual hard disk interface (`HardDisk/`, VHD files) and SuperIDE.

## CPU / machine
- **HD6309 CPU** (reference: `hd6309.cpp`, 7.6k lines; docs: `docs/The_6309_Book.pdf`, `docs/6x09_Instruction_Sets.pdf`,
  `docs/VCC-Notes.md`). Needed for NitrOS-9 and 6309-aware software. Scope when picked up:
  - New core `cpu6309.odin` behind the same `Bus`/`cpu_exec` interface as `cpu6809.odin`, selectable from the
    machine (VCC switches `CPUExec` at runtime; the 6309 must start in emulation mode and behave like a 6809).
  - Extra registers E, F (with W = E:F and Q = D:W) and V; mode register MD (native mode, FIRQ stacking, divide-
    by-zero and illegal-opcode traps); TFR/EXG with the new register codes.
  - Native mode timing (fewer cycles than the 6809) and the 6309 interrupt stacking differences.
  - Opcodes: LDQ/STQ, ADDE/ADDF/ADDW, SUBE/SUBF/SUBW, CMPE/CMPF/CMPW, bit ops (BAND/BIAND/BOR/BIOR/BEOR/BIEOR,
    LDBT/STBT), AIM/EIM/OIM/TIM, MULD, DIVD/DIVQ, SEXW, block moves TFM, PSHSW/PULSW etc., COMD/NEGD/..., ADCR/
    ADDR/SUBR/..., CLRD/CLRW/..., LDMD, DECD/INCD/INCW...
  - `docs/VCC-Notes.md` lists the instructions VCC itself leaves unemulated (ADCD, SBCD, ADCR, SBCR, BAND/BEOR/
    BIAND/BIEOR/BIOR/BOR, LDBT, STBT): decide whether to implement them properly or match VCC.
  - Tests: reuse the 6809 test rig (`cpu6809_test.odin`) for emulation-mode compatibility, then per-opcode
    known-answer tests in native mode.
- Cassette: WAV in/out is done (`cassette.odin`, `--tape`, `--tape-out`). Still open: .CAS files (byte stream
  <-> FSK conversion as in `Cassette.cpp`), tape counter/stop/rewind/pause controls, fast-load, CA1 carrier detect.
- Joystick hardware (SDL game controllers) and the hi-res joystick ramp modes.
- Config file (ROM paths, monitor type, key layout, last-used disks) and a key-map editor.
- Alternate key layouts (positional "CoCo", compact).
- Other cartridge plugins: multi-pak interface, Orchestra-90, SSC speech/sound, GMC, ACIA, RAM disk.
- Debugger, memory viewer, execution trace.
