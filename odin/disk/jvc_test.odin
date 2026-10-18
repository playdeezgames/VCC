package disk

import "core:os"
import "core:testing"

TMP :: "/tmp/claude-1000/-home-yermom-git-VCC/96287aaf-bc6a-4223-91f5-f790c6bf8d84/scratchpad/"

tmp_path :: proc(name: string) -> string {
	return tprint_path(name)
}

tprint_path :: proc(name: string) -> string {
	b := make([]u8, len(TMP) + len(name), context.temp_allocator)
	copy(b, TMP)
	copy(b[len(TMP):], name)
	return string(b)
}

write_file :: proc(path: string, data: []u8) {
	_ = os.write_entire_file(path, data)
}

@(test)
blank_disk_size_and_fill :: proc(t: ^testing.T) {
	path := tmp_path("blank35.dsk")
	defer os.remove(path)
	testing.expect_value(t, create_blank(path, overwrite = true), Error.None)
	data, err := os.read_entire_file(path, context.allocator)
	defer delete(data)
	testing.expect(t, err == nil)
	testing.expect_value(t, len(data), 35 * 18 * 256) // 161280, headerless
	all_ff := true
	for b in data {if b != 0xFF {all_ff = false}}
	testing.expect(t, all_ff)
}

@(test)
blank_double_sided_has_header :: proc(t: ^testing.T) {
	path := tmp_path("blank80x2.dsk")
	defer os.remove(path)
	testing.expect_value(t, create_blank(path, 80, 2, true), Error.None)
	img, err := mount(path)
	defer unmount(&img)
	testing.expect_value(t, err, Error.None)
	testing.expect_value(t, img.header_size, 2)
	testing.expect_value(t, img.sides, 2)
	testing.expect_value(t, img.sectors, 18)
	testing.expect_value(t, img.file_size, i64(2 + 80 * 2 * 18 * 256))
}

@(test)
create_refuses_to_overwrite :: proc(t: ^testing.T) {
	path := tmp_path("exists.dsk")
	defer os.remove(path)
	testing.expect_value(t, create_blank(path, overwrite = true), Error.None)
	testing.expect_value(t, create_blank(path), Error.Exists)
	testing.expect_value(t, create_blank(path, overwrite = true), Error.None)
	testing.expect_value(t, create_blank(path, 0, 1, true), Error.Bad_Geometry)
	testing.expect_value(t, create_blank(path, 35, 3, true), Error.Bad_Geometry)
}

@(test)
header_sizes :: proc(t: ^testing.T) {
	path := tmp_path("hdr.dsk")
	defer os.remove(path)
	body := make([]u8, 18 * 256 * 2, context.temp_allocator)

	// no header: defaults
	write_file(path, body)
	img, err := mount(path)
	testing.expect_value(t, err, Error.None)
	testing.expect_value(t, img.header_size, 0)
	testing.expect_value(t, img.sectors, 18)
	testing.expect_value(t, img.sides, 1)
	testing.expect_value(t, sector_size(&img), 256)
	testing.expect_value(t, img.first_sector, 1)
	unmount(&img)

	// 4 byte header: 10 sectors, 2 sides, 512 byte sectors, first sector 0
	full := make([]u8, 4 + 10 * 2 * 512, context.temp_allocator)
	full[0], full[1], full[2], full[3] = 10, 2, 2, 0
	write_file(path, full)
	img, err = mount(path)
	testing.expect_value(t, err, Error.None)
	testing.expect_value(t, img.header_size, 4)
	testing.expect_value(t, img.sectors, 10)
	testing.expect_value(t, img.sides, 2)
	testing.expect_value(t, sector_size(&img), 512)
	testing.expect_value(t, img.first_sector, 0)
	unmount(&img)

	// 3 byte header sets the sector size but not the first sector
	three := make([]u8, 3 + 10 * 128, context.temp_allocator) // body must be a multiple of 256
	three[0], three[1], three[2] = 10, 1, 0
	write_file(path, three)
	img, err = mount(path)
	testing.expect_value(t, err, Error.None)
	testing.expect_value(t, sector_size(&img), 128)
	testing.expect_value(t, img.first_sector, 1)
	unmount(&img)
}

@(test)
other_formats_are_rejected :: proc(t: ^testing.T) {
	path := tmp_path("vdk.dsk")
	defer os.remove(path)
	vdk := make([]u8, 12 + 18 * 256, context.temp_allocator) // VDK header size
	write_file(path, vdk)
	_, err := mount(path)
	testing.expect_value(t, err, Error.Unsupported_Format)
	dmk := make([]u8, 16 + 0x1900, context.temp_allocator) // DMK header size
	write_file(path, dmk)
	_, err = mount(path)
	testing.expect_value(t, err, Error.Unsupported_Format)
	_, err = mount(tmp_path("does_not_exist.dsk"))
	testing.expect_value(t, err, Error.Open_Failed)
}

@(test)
sector_offsets :: proc(t: ^testing.T) {
	img := Image{header_size = 2, sides = 2, sectors = 18, size_code = 1, first_sector = 1}
	testing.expect_value(t, sector_offset(&img, 0, 0, 1), i64(2))
	testing.expect_value(t, sector_offset(&img, 0, 0, 2), i64(2 + 256))
	testing.expect_value(t, sector_offset(&img, 1, 0, 1), i64(2 + 18 * 256))
	testing.expect_value(t, sector_offset(&img, 0, 1, 1), i64(2 + 2 * 18 * 256))
	testing.expect_value(t, sector_offset(&img, 1, 17, 18), i64(2 + (17 * 2 + 1) * 18 * 256 + 17 * 256))
}

@(test)
read_write_round_trip_and_persistence :: proc(t: ^testing.T) {
	path := tmp_path("rw.dsk")
	defer os.remove(path)
	create_blank(path, overwrite = true)

	img, err := mount(path)
	testing.expect_value(t, err, Error.None)
	data: [256]u8
	for i in 0 ..< 256 {data[i] = u8(i)}
	testing.expect(t, write_sector(&img, 0, 17, 3, data[:]))
	buf: [256]u8
	testing.expect_value(t, read_sector(&img, 0, 17, 3, buf[:]), 256)
	testing.expect(t, buf == data)
	// neighbours untouched
	testing.expect_value(t, read_sector(&img, 0, 17, 2, buf[:]), 256)
	testing.expect_value(t, buf[0], 0xFF)
	unmount(&img)

	// written through to the file
	raw, rerr := os.read_entire_file(path, context.allocator)
	defer delete(raw)
	testing.expect(t, rerr == nil)
	off := (17 * 18 + 2) * 256
	testing.expect_value(t, raw[off], 0)
	testing.expect_value(t, raw[off + 255], 255)
	testing.expect_value(t, len(raw), 35 * 18 * 256)
}

@(test)
invalid_addresses_and_short_images :: proc(t: ^testing.T) {
	path := tmp_path("short.dsk")
	defer os.remove(path)
	// only the first sector exists in the file (256 bytes, headerless)
	one := make([]u8, 256, context.temp_allocator)
	for i in 0 ..< 256 {one[i] = 0x11}
	write_file(path, one)
	img, err := mount(path)
	defer unmount(&img)
	testing.expect_value(t, err, Error.None)
	buf: [256]u8
	testing.expect_value(t, read_sector(&img, 0, 0, 1, buf[:]), 256)
	testing.expect_value(t, buf[10], 0x11)
	testing.expect_value(t, read_sector(&img, 0, 5, 7, buf[:]), 256) // past EOF reads as blank
	testing.expect_value(t, buf[10], 0xFF)
	testing.expect_value(t, read_sector(&img, 1, 0, 1, buf[:]), 0) // no side 1
	testing.expect_value(t, read_sector(&img, 0, 0, 0, buf[:]), 0) // first sector is 1
	testing.expect_value(t, read_sector(&img, 0, 0, 19, buf[:]), 0)
	// writing beyond the end grows the file and fills the gap
	data: [256]u8
	for i in 0 ..< 256 {data[i] = 0x22}
	testing.expect(t, write_sector(&img, 0, 2, 1, data[:]))
	testing.expect_value(t, read_sector(&img, 0, 1, 5, buf[:]), 256)
	testing.expect_value(t, buf[0], 0xFF)
	testing.expect_value(t, read_sector(&img, 0, 2, 1, buf[:]), 256)
	testing.expect_value(t, buf[0], 0x22)
	testing.expect(t, !write_sector(&img, 1, 0, 1, data[:])) // invalid side
}

@(test)
read_only_file_is_write_protected :: proc(t: ^testing.T) {
	path := tmp_path("ro.dsk")
	defer {
		os.chmod(path, os.Permissions_Read_All + {.Write_User})
		os.remove(path)
	}
	create_blank(path, overwrite = true)
	testing.expect(t, os.chmod(path, os.Permissions_Read_All) == nil)
	img, err := mount(path)
	defer unmount(&img)
	testing.expect_value(t, err, Error.None)
	// running as a user that can still write (e.g. root) would not set the flag
	if img.write_protect {
		data: [256]u8
		testing.expect(t, !write_sector(&img, 0, 0, 1, data[:]))
	}
}
