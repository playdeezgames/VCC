# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

## What this is

VCC (Virtual Color Computer): a Windows-only C++17 emulator of the Tandy CoCo 3 (GPL v3). The original is built with Visual Studio 2022 and uses Win32, DirectDraw/OpenGL and DLL plugins, so **it cannot be built or run on this Ubuntu machine**. Work here is a clean-rewrite port to **Odin + `vendor:sdl2`** in `odin/` (plan: `~/.claude/plans/distributed-painting-melody.md`). The C++ in the repo root is read-only reference; do not edit it, and per the README never change `.sln`/`.vcxproj` files.

## Commands

- Original (Windows only, "Developer Command Prompt for VS 2022"): `Build.bat` (Release, x86), `BuildClean.bat`, `BuildAll.bat`. Output goes to `__bin\Win32\<config>`.
- The only tests runnable on Linux are the portable SSC chip cores: `ssc/test/run_tests.sh` (plain g++ -std=c++17; builds each `smoke_*.cpp` against `ssc/*.cpp` and runs it).
- Odin port (once present): `odin build odin -out:vcc`, `odin test odin` (tests live beside the code as `*_test.odin`; one test: `-define:ODIN_TEST_NAMES=vcc.<name>`), `./vcc --rom /path/to/coco3.rom`. `coco3.rom` and `disk11.rom` sit in the repo root but are gitignored (`*.rom`); never commit them. Uses Odin's `vendor:sdl2` (needs `libsdl2-dev`). Headless: `./vcc --rom coco3.rom --dump-frame N --text-dump` runs N frames without a window and prints registers plus the VDG text screen (the tests use the real ROM too and skip without it). Hotkeys: F6 pause, F7 paste clipboard, F8 keyboard joystick (arrows, Ctrl/Alt buttons; the mouse is always the right joystick), F9 soft reset, F10 quit, F11 fullscreen; `--mute` disables audio. `--cart disk11.rom` loads the external ROM at $C000.

## Architecture of the original (what to read when porting)

Everything hangs off one global `SystemState EmuState` (`defines.h`) and file-static globals in each module; there is no central machine object.

- **Frame driver** `coco3.cpp`: `RenderFrame()` runs 262 scanlines via `HLINE()` (vsync, top border, active lines, bottom border). `CPUCycle()` slices each line's CPU run between timer-IRQ and audio-sample events (nanosecond accounting with `CycleDrift` carry-over) and calls `CPUExec` (function pointer to the 6809 or 6309 core). Video lines are drawn per scanline during the same loop.
- **CPUs**: `mc6809.cpp` and `hd6309.cpp` are each one huge `Do_Opcode` switch with per-op cycle counts; flags are a `std::array<bool,8> cc`. Interrupt lines are latched per instruction. `docs/VCC-Notes.md` lists unemulated/untested 6309 ops.
- **Memory** `tcc1014mmu.cpp`: GIME 8K-page MMU with two tasks, internal ROM (`LoadRom` reads `coco3.rom`), ROM/RAM map types, I/O dispatch for $FF00-$FFFF. `iobus.cpp` routes cartridge ports.
- **GIME/SAM** `tcc1014registers.cpp`: $FF90-$FFBF GIME regs, $FFC0-$FFDF SAM, interrupt sources, timer. `docs/GimeRegisters.txt` documents them.
- **Video** `tcc1014graphics.cpp` (10k lines): `GimeGpu::SetupDisplay()` decodes mode on any register write; renderers are duplicated per bit depth (8/16/32) through function-pointer tables. Fonts in `cc2font.h`/`cc3font.h`.
- **Peripherals**: `mc6821.cpp` (PIA0 keyboard/joystick/sync interrupts; PIA1 DAC, cassette, VDG mode, serial), `keyboard.cpp` (PC scancode to CoCo 8x7 matrix, selectable/custom layouts), `Audio.cpp`, `Cassette.cpp`, `joystickinput.cpp`.
- **Cartridge/plugin system**: external DLLs export `Pak*` functions (`PakInitialize`, `PakReadPort`, `PakWritePort`, `PakReset`, `PakSampleAudio`, ...); host side is `pakinterface.cpp`/`pakrouter.cpp` with shared code in `libcommon/vcc/bus` (docs: `CartridgeInterface.txt`, `CartridgeMenuSystem.txt`). Each device lives in its own directory: `mpi`, `FD502` (+`becker`), `HardDisk`, `SuperIDE`, `sdc`, `ssc`, `orch90`, `GMC`, `acia`, `Ramdisk`, `xsid`.
- **Host/UI layer (not portable)**: `Vcc.cpp` (Win32 loop/menus), `config.cpp`, `DirectDrawInterface`/`OpenGL*`, `Debugger*`/`ExecutionTrace`/`MMUMonitor`, `Vcc.rc`, `resources/`.

## Port conventions

- Single `Machine` struct passed by pointer in place of the C++ globals; one 32-bit pixel format only.
- Milestone 1 scope is the core machine (6809, MMU, GIME/SAM, PIAs, keyboard, video, audio) booting to the BASIC `OK` prompt. 6309, disk, MPI and other plugins are later, separate plans.
