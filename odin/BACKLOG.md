# Odin port backlog

Work that was deliberately left out so far. Roughly in priority order within each group.

## Bugs / polish
- **Audio popping.** Audible pops in the sound output (reported 2026-10-18). Suspects: the queue-based
  pacing in `audio.odin` (frames dropped or SDL under-runs when the queue runs dry), the DC step when the
  first non-zero DAC value arrives (samples are centred, VCC's are not), and no filtering of the 44.1 kHz
  square waves. Look at queue depth over time first.
- **Paste while BASIC is busy.** BASIC ignores keys typed during a disk command (SAVE/LOAD/DSKINI), so a pasted
  program with disk commands loses characters. Idea: after Enter, wait until the CPU polls the keyboard again
  (count PIA0 `$FF00` reads) instead of a fixed delay.
- PMODE 4 artifact colours (VCC's `Pmode4MonType` / NTSC artifact tables); only plain green/black today.
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
- HD6309 CPU (`hd6309.cpp`): native mode, extra registers, the 6309-only instructions.
- Cassette in/out (CLOAD/CSAVE, WAV and .CAS), `Cassette.cpp`.
- Joystick hardware (SDL game controllers) and the hi-res joystick ramp modes.
- Config file (ROM paths, monitor type, key layout, last-used disks) and a key-map editor.
- Alternate key layouts (positional "CoCo", compact).
- Other cartridge plugins: multi-pak interface, Orchestra-90, SSC speech/sound, GMC, ACIA, RAM disk.
- Debugger, memory viewer, execution trace.
