package vcc

import "core:os"
import "core:testing"
import "disk"

// Real Disk BASIC against a mounted image (skipped without coco3.rom / disk11.rom).

DISK_DIR :: "/tmp/claude-1000/-home-yermom-git-VCC/96287aaf-bc6a-4223-91f5-f790c6bf8d84/scratchpad/"

// Machine with Disk BASIC and `path` mounted in drive 0 (blank image created if asked).
disk_basic_machine :: proc(path: string, create := true, mount := true) -> ^Machine {
	m := real_rom_machine()
	if m == nil {return nil}
	cart, err := os.read_entire_file("disk11.rom", context.allocator)
	if err != nil {
		test_machine_free(m)
		return nil
	}
	machine_load_cart(m, cart)
	m.fdc.enabled = true
	if create {disk.create_blank(path, overwrite = true)}
	if mount {fdc_mount(m, 0, path)}
	machine_reset(m)
	for _ in 0 ..< 300 {machine_run_frame(m)} // reach the Disk BASIC prompt
	return m
}

disk_basic_free :: proc(m: ^Machine) {
	cart := m.cart
	test_machine_free(m)
	delete(cart)
}

type_basic :: proc(m: ^Machine, text: string, frames: int) {
	paste_text(m, text)
	for _ in 0 ..< frames {
		paste_step(m)
		machine_run_frame(m)
	}
}

@(test)
disk_basic_dir_of_blank_disk :: proc(t: ^testing.T) {
	path := join2(DISK_DIR, "int_blank.dsk")
	m := disk_basic_machine(path)
	if m == nil {return}
	defer {disk_basic_free(m); os.remove(path)}
	type_basic(m, "DIR\n", 600)
	text := screen_text(m)
	testing.expect(t, contains(text, "DISK EXTENDED COLOR BASIC 2.1"))
	testing.expect(t, contains(text, "\nDIR "), "DIR was typed")
	testing.expect(t, !contains(text, "ERROR"), "a blank disk lists as empty")
}

@(test)
disk_basic_save_dir_and_directory_bytes :: proc(t: ^testing.T) {
	path := join2(DISK_DIR, "int_save.dsk")
	m := disk_basic_machine(path)
	if m == nil {return}
	defer {disk_basic_free(m); os.remove(path)}
	// BASIC drops keys typed while a disk command runs, so each step gets its own wait
	type_basic(m, "10 PRINT \"HELLO\"\nSAVE \"T\"\n", 800)
	type_basic(m, "DIR\n", 600)
	text := screen_text(m)
	testing.expectf(t, contains(text, "T        BAS"), "directory listing; screen:\n%s", text)
	// the DECB directory lives on track 17, sectors 3-11
	dir: [256]u8
	disk.read_sector(&m.fdc.drives[0], 0, 17, 3, dir[:])
	testing.expect_value(t, string(dir[0:3]), "T  ")
	testing.expect_value(t, string(dir[8:11]), "BAS")
}

@(test)
disk_basic_file_survives_remount :: proc(t: ^testing.T) {
	path := join2(DISK_DIR, "int_remount.dsk")
	m := disk_basic_machine(path)
	if m == nil {return}
	defer os.remove(path)
	type_basic(m, "10 PRINT \"FROM DISK\"\nSAVE \"G\"\n", 1200)
	disk_basic_free(m)

	// a brand new machine, same image file
	m2 := disk_basic_machine(path, create = false)
	defer disk_basic_free(m2)
	type_basic(m2, "LOAD \"G\"\n", 800)
	type_basic(m2, "RUN\n", 600)
	text := screen_text(m2)
	testing.expect(t, contains(text, "FROM DISK"), "program loaded from the image and ran")
}

@(test)
disk_basic_without_disk_reports_io_error :: proc(t: ^testing.T) {
	m := disk_basic_machine("", create = false, mount = false)
	if m == nil {return}
	defer disk_basic_free(m)
	type_basic(m, "DIR\n", 3000)
	testing.expect(t, contains(screen_text(m), "?IO ERROR"))
}

@(test)
disk_basic_dskini_formats_a_disk :: proc(t: ^testing.T) {
	path := join2(DISK_DIR, "int_dskini.dsk")
	m := disk_basic_machine(path)
	if m == nil {return}
	defer {disk_basic_free(m); os.remove(path)}
	// DSKINI formats all 35 tracks with WRITE TRACK; the disk must work afterwards
	type_basic(m, "DSKINI 0\n", 3000)
	type_basic(m, "10 PRINT \"X\"\nSAVE \"A\"\n", 800)
	type_basic(m, "DIR\n", 600)
	text := screen_text(m)
	testing.expect(t, contains(text, "A        BAS"), "file saved on the freshly formatted disk")
	testing.expect(t, !contains(text, "ERROR"))
}
