package vcc

import "core:os"
import "core:testing"
import "disk"

SCRATCH :: "/tmp/claude-1000/-home-yermom-git-VCC/96287aaf-bc6a-4223-91f5-f790c6bf8d84/scratchpad/"

// Machine with the FDC enabled and a blank single sided disk in drive 0.
fdc_machine :: proc(name: string, with_disk := true) -> (m: ^Machine, path: string) {
	m = test_machine()
	path = join2(SCRATCH, name)
	m.fdc.enabled = true
	if with_disk {
		disk.create_blank(path, overwrite = true)
		fdc_mount(m, 0, path)
	}
	// motor on, drive 0 selected, NMI enabled at command end
	fdc_write(m, 0x40, CTRL_MOTOR | CTRL_DRIVE0 | CTRL_DENSITY)
	return
}

fdc_machine_free :: proc(m: ^Machine, path: string) {
	test_machine_free(m)
	os.remove(path)
}

join2 :: proc(a, b: string) -> string {
	buf := make([]u8, len(a) + len(b), context.temp_allocator)
	copy(buf, a)
	copy(buf[len(a):], b)
	return string(buf)
}

// Run the controller (one ping per scanline) until the command finishes.
fdc_run :: proc(m: ^Machine, max_pings := 2000) -> int {
	n := 0
	for m.fdc.cmd != CMD_IDLE && n < max_pings {
		fdc_ping(m)
		n += 1
	}
	return n
}

nmi_pending :: proc(m: ^Machine) -> bool {return m.cpu.int_lines[.NMI] & int_bit(.NMI) != 0}

// Read a whole sector the way DECB does: 256 data reads, then one more read to finish.
read_sector_bytes :: proc(m: ^Machine) -> (data: [256]u8) {
	for i in 0 ..< 256 {data[i] = fdc_read(m, 0x4B)}
	return
}

@(test)
restore_homes_the_head :: proc(t: ^testing.T) {
	m, path := fdc_machine("fdc_restore.dsk")
	defer fdc_machine_free(m, path)
	m.fdc.head_pos[0] = 12
	m.fdc.track = 12
	fdc_write(m, 0x48, 0x00) // RESTORE
	testing.expect(t, m.fdc.status & FDC_BUSY != 0)
	fdc_run(m)
	testing.expect_value(t, m.fdc.head_pos[0], 0)
	testing.expect_value(t, m.fdc.track, 0)
	testing.expect(t, m.fdc.status & FDC_TRACK_ZERO != 0)
	testing.expect(t, m.fdc.status & FDC_BUSY == 0)
	testing.expect_value(t, m.fdc.cmd, CMD_IDLE)
}

@(test)
seek_moves_to_data_register_track :: proc(t: ^testing.T) {
	m, path := fdc_machine("fdc_seek.dsk")
	defer fdc_machine_free(m, path)
	fdc_write(m, 0x4B, 17)
	fdc_write(m, 0x48, 0x10) // SEEK
	pings := fdc_run(m)
	testing.expect_value(t, m.fdc.head_pos[0], 17)
	testing.expect_value(t, m.fdc.track, 17)
	testing.expect(t, m.fdc.status & FDC_TRACK_ZERO == 0)
	testing.expect(t, pings >= 17 && pings < 40, "about one track per scanline in turbo mode")
	// and back down
	fdc_write(m, 0x4B, 3)
	fdc_write(m, 0x48, 0x10)
	fdc_run(m)
	testing.expect_value(t, m.fdc.head_pos[0], 3)
}

@(test)
step_in_out_with_update :: proc(t: ^testing.T) {
	m, path := fdc_machine("fdc_step.dsk")
	defer fdc_machine_free(m, path)
	fdc_write(m, 0x48, 0x50) // STEP IN with track update
	fdc_run(m)
	testing.expect_value(t, m.fdc.head_pos[0], 1)
	testing.expect_value(t, m.fdc.track, 1)
	fdc_write(m, 0x48, 0x40) // STEP IN without update
	fdc_run(m)
	testing.expect_value(t, m.fdc.head_pos[0], 2)
	testing.expect_value(t, m.fdc.track, 1)
	fdc_write(m, 0x48, 0x70) // STEP OUT with update
	fdc_run(m)
	testing.expect_value(t, m.fdc.head_pos[0], 1)
	testing.expect_value(t, m.fdc.track, 0)
}

@(test)
read_sector_streams_bytes_then_finishes :: proc(t: ^testing.T) {
	m, path := fdc_machine("fdc_read.dsk")
	defer fdc_machine_free(m, path)
	pattern: [256]u8
	for i in 0 ..< 256 {pattern[i] = u8(255 - i)}
	disk.write_sector(&m.fdc.drives[0], 0, 3, 5, pattern[:])

	fdc_write(m, 0x4B, 3)
	fdc_write(m, 0x48, 0x10) // SEEK 3
	fdc_run(m)
	fdc_write(m, 0x4A, 5) // sector 5
	fdc_write(m, 0x48, 0x80) // READ SECTOR
	testing.expect_value(t, m.fdc.status, FDC_BUSY | FDC_DRQ)
	data := read_sector_bytes(m)
	testing.expect(t, data == pattern)
	// the last byte ends the command (no extra read needed)
	testing.expect_value(t, m.fdc.status, FDC_READY)
	testing.expect_value(t, m.fdc.cmd, CMD_IDLE)
	testing.expect_value(t, m.fdc.sector, 6) // sector register advanced
	testing.expect(t, nmi_pending(m), "NMI at completion (control bit 5 set)")
}

@(test)
no_nmi_when_enable_bit_clear :: proc(t: ^testing.T) {
	m, path := fdc_machine("fdc_nonmi.dsk")
	defer fdc_machine_free(m, path)
	fdc_write(m, 0x40, CTRL_MOTOR | CTRL_DRIVE0) // density/NMI bit off
	fdc_write(m, 0x4A, 1)
	fdc_write(m, 0x48, 0x80)
	read_sector_bytes(m)
	testing.expect(t, !nmi_pending(m))
	testing.expect_value(t, m.fdc.cmd, CMD_IDLE)
}

@(test)
missing_sector_is_record_not_found :: proc(t: ^testing.T) {
	m, path := fdc_machine("fdc_rnf.dsk")
	defer fdc_machine_free(m, path)
	fdc_write(m, 0x4A, 99)
	fdc_write(m, 0x48, 0x80)
	fdc_read(m, 0x4B)
	testing.expect_value(t, m.fdc.status, FDC_RECNOTFOUND)
	testing.expect_value(t, m.fdc.cmd, CMD_IDLE)
	// wrong track register (head is on track 0, register says 9)
	fdc_write(m, 0x49, 9)
	fdc_write(m, 0x4A, 1)
	fdc_write(m, 0x48, 0x80)
	fdc_read(m, 0x4B)
	testing.expect_value(t, m.fdc.status, FDC_RECNOTFOUND)
}

@(test)
no_drive_selected_is_record_not_found :: proc(t: ^testing.T) {
	m, path := fdc_machine("fdc_nodrive.dsk")
	defer fdc_machine_free(m, path)
	fdc_write(m, 0x40, CTRL_MOTOR) // no drive bits
	testing.expect_value(t, m.fdc.cur, u8(FDC_NO_DRIVE))
	fdc_write(m, 0x4A, 1)
	fdc_write(m, 0x48, 0x80)
	fdc_read(m, 0x4B)
	testing.expect_value(t, m.fdc.status, FDC_RECNOTFOUND)
}

@(test)
write_sector_round_trip :: proc(t: ^testing.T) {
	m, path := fdc_machine("fdc_write.dsk")
	defer fdc_machine_free(m, path)
	fdc_write(m, 0x4B, 10)
	fdc_write(m, 0x48, 0x10)
	fdc_run(m)
	fdc_write(m, 0x4A, 2)
	fdc_write(m, 0x48, 0xA0) // WRITE SECTOR
	for m.fdc.status & FDC_DRQ == 0 {fdc_ping(m)} // DRQ rises a few scanlines after the command
	testing.expect(t, m.fdc.status & FDC_DRQ != 0)
	for i in 0 ..< 256 {fdc_write(m, 0x4B, u8(i ~ 0x5A))}
	fdc_run(m) // sector is committed when the transfer ends
	testing.expect_value(t, m.fdc.cmd, CMD_IDLE)
	testing.expect_value(t, m.fdc.sector, 3)
	buf: [256]u8
	disk.read_sector(&m.fdc.drives[0], 0, 10, 2, buf[:])
	for i in 0 ..< 256 {
		if buf[i] != u8(i ~ 0x5A) {
			testing.expectf(t, false, "byte %d = %02X", i, buf[i])
			break
		}
	}
	// the neighbour is untouched
	disk.read_sector(&m.fdc.drives[0], 0, 10, 3, buf[:])
	testing.expect_value(t, buf[0], 0xFF)
}

@(test)
slow_cpu_loses_data :: proc(t: ^testing.T) {
	m, path := fdc_machine("fdc_lost.dsk")
	defer fdc_machine_free(m, path)
	fdc_write(m, 0x4A, 1)
	fdc_write(m, 0x48, 0x80)
	for _ in 0 ..< 3 {fdc_ping(m)}
	testing.expect_value(t, m.fdc.xfer_idx, 0) // still within the data-request window
	for _ in 0 ..< 10 {fdc_ping(m)}
	testing.expect(t, m.fdc.xfer_idx > 0, "bytes were dropped because the CPU did not read")
	testing.expect(t, m.fdc.lost_data)
}

@(test)
force_interrupt_aborts_and_raises_nmi :: proc(t: ^testing.T) {
	m, path := fdc_machine("fdc_force.dsk")
	defer fdc_machine_free(m, path)
	fdc_write(m, 0x4A, 1)
	fdc_write(m, 0x48, 0x80)
	fdc_write(m, 0x48, 0xD8) // FORCE INTERRUPT (immediate)
	testing.expect_value(t, m.fdc.cmd, CMD_IDLE)
	testing.expect_value(t, m.fdc.status, FDC_READY)
	testing.expect(t, nmi_pending(m))
}

@(test)
force_interrupt_zero_is_silent :: proc(t: ^testing.T) {
	m, path := fdc_machine("fdc_force0.dsk")
	defer fdc_machine_free(m, path)
	fdc_write(m, 0x48, 0x80)
	fdc_write(m, 0x48, 0xD0) // FORCE INTERRUPT, no condition
	testing.expect_value(t, m.fdc.cmd, CMD_IDLE)
	testing.expect(t, !nmi_pending(m))
}

@(test)
read_address_returns_six_bytes :: proc(t: ^testing.T) {
	m, path := fdc_machine("fdc_addr.dsk")
	defer fdc_machine_free(m, path)
	m.fdc.head_pos[0] = 7
	fdc_write(m, 0x48, 0xC0) // READ ADDRESS
	got: [6]u8
	for i in 0 ..< 6 {got[i] = fdc_read(m, 0x4B)}
	testing.expect_value(t, got[0], 7) // track
	testing.expect_value(t, got[1], 1) // sides
	testing.expect_value(t, got[3], 1) // 256 byte sectors
	fdc_read(m, 0x4B)
	testing.expect_value(t, m.fdc.cmd, CMD_IDLE)
}

@(test)
index_pulse_visible_in_status :: proc(t: ^testing.T) {
	m, path := fdc_machine("fdc_index.dsk")
	defer fdc_machine_free(m, path)
	seen_set, seen_clear := false, false
	for _ in 0 ..< INDEX_TIME * 2 {
		fdc_ping(m)
		if m.fdc.status & FDC_INDEX != 0 {seen_set = true} else {seen_clear = true}
	}
	testing.expect(t, seen_set && seen_clear, "index pulse toggles about 5 times a second")
}

@(test)
controller_idles_with_motor_off :: proc(t: ^testing.T) {
	m, path := fdc_machine("fdc_motor.dsk")
	defer fdc_machine_free(m, path)
	fdc_write(m, 0x40, CTRL_DRIVE0) // motor off
	m.fdc.head_pos[0] = 5
	m.fdc.track = 5
	fdc_write(m, 0x48, 0x00)
	for _ in 0 ..< 50 {fdc_ping(m)}
	testing.expect_value(t, m.fdc.head_pos[0], 5) // nothing moves
	fdc_write(m, 0x40, CTRL_MOTOR | CTRL_DRIVE0)
	fdc_run(m)
	testing.expect_value(t, m.fdc.head_pos[0], 0)
}

@(test)
drive_3_via_side_select_bit :: proc(t: ^testing.T) {
	m, path := fdc_machine("fdc_drive3.dsk")
	defer fdc_machine_free(m, path)
	fdc_write(m, 0x40, CTRL_MOTOR | CTRL_SIDE) // side bit with no drive bits = drive 3
	testing.expect_value(t, m.fdc.cur, u8(3))
	testing.expect_value(t, m.fdc.side, u8(0))
	fdc_write(m, 0x40, CTRL_MOTOR | CTRL_SIDE | CTRL_DRIVE1) // with a drive selected = side 1
	testing.expect_value(t, m.fdc.cur, u8(1))
	testing.expect_value(t, m.fdc.side, u8(1))
}

@(test)
write_protected_image_refuses_writes :: proc(t: ^testing.T) {
	m, path := fdc_machine("fdc_wp.dsk")
	defer {
		os.chmod(path, os.Permissions_Read_All + {.Write_User})
		fdc_machine_free(m, path)
	}
	fdc_eject(m, 0)
	os.chmod(path, os.Permissions_Read_All)
	fdc_mount(m, 0, path)
	if !m.fdc.drives[0].write_protect {return} // running as a user who can still write
	fdc_write(m, 0x4A, 1)
	fdc_write(m, 0x48, 0xA0)
	fdc_ping(m)
	for _ in 0 ..< 256 {fdc_write(m, 0x4B, 0x11)}
	fdc_run(m)
	testing.expect(t, m.fdc.status & FDC_WRITEPROTECT != 0)
}

@(test)
write_track_formats_sectors :: proc(t: ^testing.T) {
	m, path := fdc_machine("fdc_format.dsk")
	defer fdc_machine_free(m, path)
	// A DECB style track image: for each sector an ID mark (FE trk side sec len F7),
	// gap, a data mark (FB), 256 bytes of fill and a CRC request (F7).
	track: [TRACK_BUFFER_SIZE]u8
	n := 0
	put :: proc(track: ^[TRACK_BUFFER_SIZE]u8, n: ^int, b: u8) {
		if n^ < TRACK_BUFFER_SIZE {track[n^] = b}
		n^ += 1
	}
	for sec in 1 ..= 18 {
		for _ in 0 ..< 22 {put(&track, &n, 0x4E)}
		for _ in 0 ..< 12 {put(&track, &n, 0x00)}
		for b in ([]u8{0xFE, 5, 0, u8(sec), 1, 0xF7}) {put(&track, &n, b)}
		for _ in 0 ..< 22 {put(&track, &n, 0x4E)}
		put(&track, &n, 0xFB)
		for _ in 0 ..< 256 {put(&track, &n, u8(sec) + 0x20)}
		put(&track, &n, 0xF7)
	}
	fdc_write(m, 0x4B, 5)
	fdc_write(m, 0x48, 0x10)
	fdc_run(m)
	fdc_write(m, 0x48, 0xF0) // WRITE TRACK
	fdc_ping(m)
	for i in 0 ..< TRACK_BUFFER_SIZE {fdc_write(m, 0x4B, track[i])}
	fdc_run(m)
	testing.expect_value(t, m.fdc.cmd, CMD_IDLE)
	buf: [256]u8
	for sec in 1 ..= 18 {
		disk.read_sector(&m.fdc.drives[0], 0, 5, sec, buf[:])
		if buf[0] != u8(sec) + 0x20 || buf[255] != u8(sec) + 0x20 {
			testing.expectf(t, false, "sector %d not formatted (%02X)", sec, buf[0])
		}
	}
	// other tracks untouched
	disk.read_sector(&m.fdc.drives[0], 0, 6, 1, buf[:])
	testing.expect_value(t, buf[0], 0xFF)
}

@(test)
ports_route_through_machine_bus :: proc(t: ^testing.T) {
	m, path := fdc_machine("fdc_bus.dsk")
	defer fdc_machine_free(m, path)
	mem_write8(m, 0xFF49, 0x21) // track register via the CPU bus
	testing.expect_value(t, mem_read8(m, 0xFF49), 0x21)
	mem_write8(m, 0xFF4A, 0x07)
	testing.expect_value(t, mem_read8(m, 0xFF4A), 0x07)
	// ports are silent when the controller is absent
	m2 := test_machine()
	defer test_machine_free(m2)
	mem_write8(m2, 0xFF49, 0x21)
	testing.expect_value(t, mem_read8(m2, 0xFF49), 0)
}
