package vcc

import "core:fmt"
import "disk"

// Tandy FD-502 floppy controller: a WD1793 plus the $FF40 control register.
// Ports FD502/wd1793.cpp. Registers (low byte of the address):
//   $40 control (write only)   $48 status / command   $49 track
//   $4A sector                 $4B data
// The controller is advanced once per scanline by fdc_ping(). Like VCC, the
// "halt on DRQ" flag is not emulated: data is handed out immediately and the
// NMI raised when a command finishes ends DECB's transfer loops.

// Status register bits
FDC_READY :: u8(0)
FDC_BUSY :: u8(0x01)
FDC_DRQ :: u8(0x02)
FDC_INDEX :: u8(0x02) // type I commands: index pulse (shares the DRQ bit)
FDC_TRACK_ZERO :: u8(0x04)
FDC_LOSTDATA :: u8(0x04) // type II/III commands (shares the track 0 bit)
FDC_RECNOTFOUND :: u8(0x10)
FDC_WRITEPROTECT :: u8(0x40)

// Control register bits ($FF40)
CTRL_DRIVE0 :: u8(0x01)
CTRL_DRIVE1 :: u8(0x02)
CTRL_DRIVE2 :: u8(0x04)
CTRL_MOTOR :: u8(0x08)
CTRL_DENSITY :: u8(0x20) // also the NMI enable flag
CTRL_SIDE :: u8(0x40) // side select, or drive 3 on single sided systems
CTRL_HALT :: u8(0x80)

// Commands (high nibble written to $FF48)
CMD_RESTORE :: 0
CMD_SEEK :: 1
CMD_STEP :: 2
CMD_STEPUPD :: 3
CMD_STEPIN :: 4
CMD_STEPINUPD :: 5
CMD_STEPOUT :: 6
CMD_STEPOUTUPD :: 7
CMD_READSECTOR :: 8
CMD_READSECTORM :: 9
CMD_WRITESECTOR :: 10
CMD_WRITESECTORM :: 11
CMD_READADDRESS :: 12
CMD_FORCEINT :: 13
CMD_READTRACK :: 14
CMD_WRITETRACK :: 15
CMD_IDLE :: 255

FDC_NO_DRIVE :: 4 // index of the permanently empty "drive" used when none is selected
INDEX_TIME :: 262 * 60 / 5 // scanlines per revolution (300 rpm)
WAIT_TIME :: 5 // scanlines the CPU has to service a data request
STEP_TIME :: 15 // pings per millisecond
SETTLE_TIME :: 10
TRACK_BUFFER_SIZE :: 6272

STEP_TIMES_MS := [4]int{6, 12, 20, 30}

Xfer_Kind :: enum {
	Sector,
	Address,
	Track,
}

Fdc :: struct {
	enabled:         bool, // FD-502 present (routes $FF40-$FF4B)
	drives:          [5]disk.Image, // 0-3 real drives, 4 = empty
	head_pos:        [5]u8, // physical track under each head

	status:          u8,
	data:            u8,
	track:           u8,
	sector:          u8,
	control:         u8,
	side:            u8,
	cmd:             u8, // CMD_* or CMD_IDLE
	cur:             u8, // selected drive (FDC_NO_DRIVE if none)
	last:            u8,
	motor:           bool,
	int_enable:      bool, // NMI at command completion
	halt_enable:     bool,
	step_time_ms:    int,
	step_dir:        u8, // 1 = towards higher tracks
	index_pulse:     bool,
	index_counter:   int,
	wobble:          i8, // pseudo random jitter on the index period
	rng:             u32,
	turbo:           bool, // fast head movement (VCC default on)
	cycles_settle:   int,
	cycles_step:     int,
	lost_data:       bool,
	exec_wait:       int,
	io_wait:         int,
	read_kind:       Xfer_Kind,
	write_kind:      Xfer_Kind,
	xfer:            [16384]u8,
	xfer_idx:        int,
	xfer_size:       int,
}

fdc_reset :: proc(m: ^Machine) {
	f := &m.fdc
	f.status = FDC_READY
	f.data, f.track, f.sector, f.control, f.side = 0, 0, 0, 0, 0
	f.cmd = CMD_IDLE
	f.cur = FDC_NO_DRIVE
	f.last = FDC_NO_DRIVE
	f.motor, f.int_enable, f.halt_enable = false, false, false
	f.step_dir = 1
	f.index_pulse = false
	f.index_counter = 0
	f.exec_wait = 0
	f.io_wait = 0
	f.lost_data = false
	f.xfer_idx, f.xfer_size = 0, 0
	f.read_kind, f.write_kind = .Sector, .Sector
	if f.rng == 0 {f.rng = 0x1234567}
	fdc_set_turbo(m, true)
}

fdc_set_turbo :: proc(m: ^Machine, on: bool) {
	f := &m.fdc
	f.turbo = on
	if on {
		f.cycles_settle, f.cycles_step = 1, 0
	} else {
		f.cycles_settle, f.cycles_step = SETTLE_TIME, STEP_TIME
	}
}

fdc_mount :: proc(m: ^Machine, drive: int, path: string) -> disk.Error {
	if drive < 0 || drive > 3 {return .Bad_Geometry}
	fdc_eject(m, drive)
	img, err := disk.mount(path)
	if err != .None {return err}
	m.fdc.drives[drive] = img
	m.fdc.enabled = true
	return .None
}

fdc_eject :: proc(m: ^Machine, drive: int) {
	if drive < 0 || drive > 3 {return}
	disk.unmount(&m.fdc.drives[drive])
}

fdc_shutdown :: proc(m: ^Machine) {
	for i in 0 ..< 4 {fdc_eject(m, i)}
}

fdc_mounted :: proc(m: ^Machine, drive: int) -> bool {
	return drive >= 0 && drive < 5 && m.fdc.drives[drive].file != nil
}

// Short status text for the window title.
fdc_status_text :: proc(m: ^Machine) -> string {
	f := &m.fdc
	if !f.motor {return ""}
	return fmt.tprintf("FD-502: Drv:%d Trk:%02d Sec:%02d Hd:%d", f.cur, f.head_pos[f.cur], f.sector, f.side)
}

// ---------------------------------------------------------------- registers

fdc_read :: proc(m: ^Machine, port: u8) -> u8 {
	f := &m.fdc
	switch port {
	case 0x48:
		return f.status
	case 0x49:
		return f.track
	case 0x4A:
		return f.sector
	case 0x4B:
		if f.cmd == CMD_IDLE {return f.data}
		return fdc_get_byte(m)
	}
	return 0 // $FF40 cannot be read
}

fdc_write :: proc(m: ^Machine, port: u8, val: u8) {
	f := &m.fdc
	switch port {
	case 0x48:
		fdc_dispatch_command(m, val)
	case 0x49:
		f.track = val
	case 0x4A:
		f.sector = val
	case 0x4B:
		if f.cmd == CMD_IDLE {
			f.data = val
		} else {
			fdc_put_byte(m, val)
		}
	case 0x40:
		f.control = val
		fdc_decode_control(m, val)
	}
}

fdc_decode_control :: proc(m: ^Machine, v: u8) {
	f := &m.fdc
	f.motor = false
	f.cur = FDC_NO_DRIVE
	f.side = 0
	f.int_enable = false
	f.halt_enable = false

	if v & CTRL_DRIVE0 != 0 {f.cur = 0}
	if v & CTRL_DRIVE1 != 0 {f.cur = 1}
	if v & CTRL_DRIVE2 != 0 {f.cur = 2}
	if v & CTRL_SIDE != 0 {f.side = 1} // drive 3 on "all single sided" systems
	if v & CTRL_MOTOR != 0 {f.motor = true}
	if f.side == 1 && f.cur == FDC_NO_DRIVE {
		f.cur = 3
		f.side = 0
	}
	f.last = f.cur
	if v & CTRL_DENSITY != 0 {f.int_enable = true}
	if v & CTRL_HALT != 0 {f.halt_enable = true}
}

// ---------------------------------------------------------------- command flow

fdc_command_done :: proc(m: ^Machine) {
	f := &m.fdc
	if f.int_enable {
		cpu_assert_interrupt(&m.cpu, .NMI, .NMI)
	}
	f.xfer_size = 0
	f.cmd = CMD_IDLE
}

fdc_dispatch_command :: proc(m: ^Machine, v: u8) {
	f := &m.fdc
	command := v >> 4
	if f.cmd != CMD_IDLE && command != CMD_FORCEINT {return}
	f.cmd = command
	switch command {
	case CMD_RESTORE:
		fdc_type1_flags(m, v)
		f.exec_wait = f.cycles_settle + f.cycles_step * f.step_time_ms
		f.status = FDC_BUSY
	case CMD_SEEK:
		fdc_type1_flags(m, v)
		f.exec_wait = f.cycles_settle + f.cycles_step * f.step_time_ms
		f.track = f.data
		f.status = FDC_BUSY
		f.step_dir = 0 if f.head_pos[f.cur] > f.data else 1
	case CMD_STEP, CMD_STEPUPD, CMD_STEPIN, CMD_STEPINUPD, CMD_STEPOUT, CMD_STEPOUTUPD:
		fdc_type1_flags(m, v)
		f.exec_wait = f.cycles_settle + f.cycles_step * f.step_time_ms
		f.status = FDC_BUSY
	case CMD_READSECTOR, CMD_READSECTORM:
		f.xfer_idx = 0
		f.status = FDC_BUSY | FDC_DRQ
		f.read_kind = .Sector
		f.exec_wait = 1
		f.io_wait = 0
	case CMD_WRITESECTOR, CMD_WRITESECTORM:
		f.xfer_idx = 0
		f.status = FDC_BUSY
		f.write_kind = .Sector
		f.exec_wait = 5
		f.io_wait = 0
	case CMD_READADDRESS:
		f.xfer_idx = 0
		f.status = FDC_BUSY | FDC_DRQ
		f.read_kind = .Address
		f.exec_wait = 1
		f.io_wait = 0
	case CMD_FORCEINT:
		f.cmd = CMD_IDLE
		f.xfer_size = 0
		f.status = FDC_READY
		f.exec_wait = 1
		if v & 15 != 0 {
			cpu_assert_interrupt(&m.cpu, .NMI, .NMI)
		}
	case CMD_READTRACK:
		f.xfer_idx = 0
		f.status = FDC_BUSY | FDC_DRQ
		f.read_kind = .Track
		f.exec_wait = 1
		f.io_wait = 0
	case CMD_WRITETRACK:
		f.xfer_idx = 0
		f.status = FDC_BUSY
		f.write_kind = .Track
		f.exec_wait = 5
		f.io_wait = 0
	}
}

fdc_type1_flags :: proc(m: ^Machine, v: u8) {
	m.fdc.step_time_ms = STEP_TIMES_MS[v & 3]
}

// Status bits describing the selected drive's state after head movement.
fdc_type1_status :: proc(m: ^Machine) -> u8 {
	f := &m.fdc
	s := FDC_READY
	if f.head_pos[f.cur] == 0 {s |= FDC_TRACK_ZERO}
	if f.drives[f.cur].write_protect {s |= FDC_WRITEPROTECT}
	return s
}

// Called once per scanline (HSYNC): index pulse, head movement, data timeouts.
fdc_ping :: proc(m: ^Machine) {
	f := &m.fdc
	if !f.enabled || !f.motor {return}

	f.index_counter += 1
	if f.index_counter > INDEX_TIME - 30 + int(f.wobble) {f.index_pulse = true}
	if f.index_counter > INDEX_TIME + int(f.wobble) {
		f.index_pulse = false
		f.index_counter = 0
		f.rng = f.rng * 1664525 + 1013904223
		f.wobble = i8(f.rng >> 24) / 4
	}

	if (f.cmd <= 7 || f.cmd == CMD_IDLE) && f.drives[f.cur].file != nil {
		if f.index_pulse {f.status |= FDC_INDEX} else {f.status &= ~FDC_INDEX}
	}
	if f.cmd == CMD_IDLE {return}
	f.exec_wait -= 1
	if f.exec_wait > 0 {return}
	f.exec_wait = 1
	f.io_wait += 1

	d := &f.head_pos[f.cur]
	switch f.cmd {
	case CMD_RESTORE:
		if d^ != 0 {
			d^ -= 1
			f.exec_wait = f.cycles_step * f.step_time_ms
		} else {
			f.track = 0
			f.status = fdc_type1_status(m)
			fdc_command_done(m)
		}
	case CMD_SEEK:
		if d^ != f.data {
			if f.step_dir == 1 {d^ += 1} else {d^ -= 1}
			f.exec_wait = f.cycles_step * f.step_time_ms
		} else {
			d^ = f.track
			f.status = fdc_type1_status(m)
			fdc_command_done(m)
		}
	case CMD_STEP, CMD_STEPUPD:
		if f.step_dir == 1 {d^ += 1} else if d^ > 0 {d^ -= 1}
		if f.cmd & 1 != 0 {
			if f.step_dir == 1 {f.track += 1} else {f.track -= 1}
		}
		f.status = FDC_READY // as in VCC
		fdc_command_done(m)
	case CMD_STEPIN, CMD_STEPINUPD:
		f.step_dir = 1
		d^ += 1
		if f.cmd & 1 != 0 {f.track += 1}
		f.status = FDC_READY
		fdc_command_done(m)
	case CMD_STEPOUT, CMD_STEPOUTUPD:
		f.step_dir = 0
		if d^ > 0 {d^ -= 1}
		if f.cmd & 1 != 0 {f.track -= 1}
		f.status = FDC_READY
		fdc_command_done(m)
	case CMD_READSECTOR, CMD_READSECTORM, CMD_READADDRESS, CMD_READTRACK:
		if f.io_wait > WAIT_TIME {
			f.lost_data = true
			fdc_get_byte(m)
		}
	case CMD_WRITESECTOR, CMD_WRITESECTORM, CMD_WRITETRACK:
		f.status |= FDC_DRQ
		if f.io_wait > WAIT_TIME {
			f.lost_data = true
			fdc_put_byte(m, 0)
		}
	}
}

// ---------------------------------------------------------------- data transfer

fdc_get_byte :: proc(m: ^Machine) -> u8 {
	switch m.fdc.read_kind {
	case .Sector:
		return fdc_get_sector_byte(m)
	case .Address:
		return fdc_get_address_byte(m)
	case .Track:
		return fdc_get_track_byte(m)
	}
	return 0
}

fdc_put_byte :: proc(m: ^Machine, v: u8) {
	switch m.fdc.write_kind {
	case .Sector:
		fdc_put_sector_byte(m, v)
	case .Track:
		fdc_put_track_byte(m, v)
	case .Address:
	}
}

fdc_get_sector_byte :: proc(m: ^Machine) -> (ret: u8) {
	f := &m.fdc
	img := &f.drives[f.cur]
	if f.xfer_size == 0 {
		f.xfer_size = fdc_read_sector(m)
	}
	if f.xfer_size == 0 {
		fdc_command_done(m)
		f.status = FDC_RECNOTFOUND
		return 0
	}
	if f.xfer_idx < f.xfer_size {
		ret = f.xfer[f.xfer_idx]
		f.xfer_idx += 1
		f.status = FDC_BUSY | FDC_DRQ
		f.io_wait = 0
	} else {
		f.status = FDC_READY
		fdc_command_done(m)
		if f.lost_data {
			f.status = FDC_LOSTDATA
			f.lost_data = false
		}
		f.sector += 1
	}
	_ = img
	return
}

// JVC: the head must be over the requested track and the sector must exist.
fdc_read_sector :: proc(m: ^Machine) -> int {
	f := &m.fdc
	img := &f.drives[f.cur]
	if img.file == nil || f.track != f.head_pos[f.cur] {return 0}
	return disk.read_sector(img, int(f.side), int(f.head_pos[f.cur]), int(f.sector), f.xfer[:])
}

fdc_get_address_byte :: proc(m: ^Machine) -> (ret: u8) {
	f := &m.fdc
	img := &f.drives[f.cur]
	if f.xfer_size == 0 {
		f.xfer[0] = f.head_pos[f.cur]
		f.xfer[1] = u8(img.sides)
		f.xfer[2] = u8(f.index_counter / 176)
		f.xfer[3] = u8(img.size_code)
		f.xfer[4] = 0 // CRC
		f.xfer[5] = 0
		f.xfer_size = 6
	}
	if img.file == nil {
		f.status = FDC_RECNOTFOUND
		fdc_command_done(m)
		return 0
	}
	if f.xfer_idx < f.xfer_size {
		ret = f.xfer[f.xfer_idx]
		f.xfer_idx += 1
		f.status = FDC_BUSY | FDC_DRQ
		f.io_wait = 0
	} else {
		f.status = FDC_READY
		fdc_command_done(m)
		if f.lost_data {
			f.status = FDC_LOSTDATA
			f.lost_data = false
		}
	}
	return
}

// READ TRACK is a stub for JVC images (as in VCC): the sector is never found.
fdc_get_track_byte :: proc(m: ^Machine) -> u8 {
	f := &m.fdc
	fdc_command_done(m)
	f.status = FDC_RECNOTFOUND
	return 0
}

fdc_put_sector_byte :: proc(m: ^Machine, v: u8) {
	f := &m.fdc
	img := &f.drives[f.cur]
	if f.xfer_size == 0 {
		f.xfer_size = disk.sector_size(img)
		if f.xfer_size == 0 || f.track != f.head_pos[f.cur] || int(f.sector) >= img.first_sector + img.sectors {
			f.status = FDC_RECNOTFOUND
			fdc_command_done(m)
			return
		}
	}
	if f.xfer_idx >= f.xfer_size {
		ok := false
		if img.file != nil {
			ok = disk.write_sector(img, int(f.side), int(f.head_pos[f.cur]), int(f.sector), f.xfer[:f.xfer_size])
		}
		f.status = FDC_READY
		if !ok || f.lost_data {f.status = FDC_LOSTDATA}
		if img.write_protect {f.status = FDC_WRITEPROTECT | FDC_RECNOTFOUND}
		fdc_command_done(m)
		f.lost_data = false
		f.sector += 1
	} else {
		f.xfer[f.xfer_idx] = v
		f.xfer_idx += 1
		f.status = FDC_BUSY | FDC_DRQ
		f.io_wait = 0
	}
}

// WRITE TRACK (format): scan the track image for ID and data address marks
// and write each data field to the matching sector (JVC has no sector headers).
fdc_put_track_byte :: proc(m: ^Machine, v: u8) {
	f := &m.fdc
	img := &f.drives[f.cur]
	if f.xfer_size == 0 {f.xfer_size = TRACK_BUFFER_SIZE}
	if f.xfer_idx >= f.xfer_size {
		ok := fdc_write_track(m)
		f.status = FDC_READY
		if !ok || f.lost_data {f.status = FDC_LOSTDATA}
		if img.write_protect {f.status = FDC_WRITEPROTECT | FDC_RECNOTFOUND}
		fdc_command_done(m)
		f.lost_data = false
	} else {
		f.xfer[f.xfer_idx] = v
		f.xfer_idx += 1
		f.status = FDC_BUSY | FDC_DRQ
		f.io_wait = 0
	}
}

fdc_write_track :: proc(m: ^Machine) -> bool {
	f := &m.fdc
	img := &f.drives[f.cur]
	if img.file == nil {return false}
	size := disk.sector_size(img)
	buf := f.xfer[:TRACK_BUFFER_SIZE]
	x_sector := 0
	wrote := false
	i := 0
	for i < TRACK_BUFFER_SIZE {
		if buf[i] == 0xFE && i + 6 < TRACK_BUFFER_SIZE { 	// ID address mark
			x_sector = int(buf[i + 3])
			i += 6
		}
		if buf[i] == 0xFB { 	// data address mark: sector data follows
			i += 1
			if i + size <= TRACK_BUFFER_SIZE && x_sector >= img.first_sector {
				if disk.write_sector(img, int(f.side), int(f.head_pos[f.cur]), x_sector, buf[i:i + size]) {
					wrote = true
				}
			}
			i += size
		}
		i += 1
	}
	return wrote
}
