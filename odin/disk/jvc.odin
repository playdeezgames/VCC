package disk

// Floppy disk images for the FD-502 emulation. Only the JVC/DSK format is
// supported for now (VDK, OS-9 raw and DMK are in odin/BACKLOG.md).
//
// A JVC image is a plain dump of the sectors, optionally preceded by a small
// header. The header size is file size % 256:
//   0 bytes  18 sectors per track, 256 byte sectors, 1 side, first sector 1
//   2 bytes  + sectors per track, number of sides
//   3 bytes  + sector size code (0=128 1=256 2=512 3=1024)
//   4 bytes  + number of the first sector
// Sectors are stored track by track; on double sided disks side 0 and side 1
// of a track are stored one after the other.

import "core:os"

SECTOR_SIZES := [4]int{128, 256, 512, 1024}

DEFAULT_SECTORS :: 18
DEFAULT_TRACKS :: 35
FILL_BYTE :: 0xFF // what a formatted DECB disk contains

Error :: enum {
	None,
	Open_Failed,
	Unsupported_Format, // not a JVC header size (VDK = 12, DMK = 16 ...)
	Bad_Geometry,
	Exists, // create_blank refuses to overwrite
	Write_Failed,
}

Image :: struct {
	file:          ^os.File,
	path:          string,
	header_size:   int,
	sides:         int,
	sectors:       int, // per track
	size_code:     int,
	first_sector:  int,
	write_protect: bool, // file could only be opened read-only
	file_size:     i64,
}

sector_size :: proc(img: ^Image) -> int {return SECTOR_SIZES[img.size_code & 3]}

track_size :: proc(img: ^Image) -> int {return img.sectors * sector_size(img)}

// Open an existing image. The path is copied.
mount :: proc(path: string) -> (img: Image, err: Error) {
	file, ferr := os.open(path, os.O_RDWR)
	if ferr != nil {
		// might be read-only
		file, ferr = os.open(path, os.O_RDONLY)
		if ferr != nil {return {}, .Open_Failed}
		img.write_protect = true
	}
	size, serr := os.file_size(file)
	if serr != nil {
		os.close(file)
		return {}, .Open_Failed
	}

	img.file = file
	img.path = path
	img.file_size = size
	img.header_size = int(size % 256)
	img.sides = 1
	img.sectors = DEFAULT_SECTORS
	img.size_code = 1
	img.first_sector = 1

	header: [4]u8
	switch img.header_size {
	case 0:
	case 2, 3, 4:
		n, _ := os.read_at(file, header[:img.header_size], 0)
		if n != img.header_size {
			os.close(file)
			return {}, .Open_Failed
		}
		img.sectors = int(header[0])
		img.sides = int(header[1])
		if img.header_size >= 3 {img.size_code = int(header[2])}
		if img.header_size >= 4 {img.first_sector = int(header[3])}
	case:
		os.close(file)
		return {}, .Unsupported_Format
	}

	if img.sectors < 1 || img.sides < 1 || img.sides > 2 || img.size_code > 3 {
		os.close(file)
		return {}, .Bad_Geometry
	}
	return img, .None
}

unmount :: proc(img: ^Image) {
	if img.file != nil {os.close(img.file)}
	img^ = {}
}

// Byte offset of a sector in the image file.
sector_offset :: proc(img: ^Image, side, track, sector: int) -> i64 {
	ts := track_size(img)
	return i64(img.header_size + track * img.sides * ts + side * ts + sector_size(img) * (sector - img.first_sector))
}

// Does a (side, sector) address exist on this image?
valid_address :: proc(img: ^Image, side, sector: int) -> bool {
	return side < img.sides && sector >= img.first_sector && sector < img.first_sector + img.sectors
}

// Read one sector into buf (which must hold sector_size bytes). Returns the
// sector size, or 0 when the address does not exist. Parts of the image past
// the end of the file read as 0xFF, like a blank disk.
read_sector :: proc(img: ^Image, side, track, sector: int, buf: []u8) -> int {
	if img.file == nil || !valid_address(img, side, sector) {return 0}
	size := sector_size(img)
	if len(buf) < size {return 0}
	for i in 0 ..< size {buf[i] = FILL_BYTE}
	off := sector_offset(img, side, track, sector)
	if off < img.file_size {
		os.read_at(img.file, buf[:size], off)
	}
	return size
}

// Write one sector. The file grows if the sector lies beyond its end.
write_sector :: proc(img: ^Image, side, track, sector: int, data: []u8) -> bool {
	if img.file == nil || img.write_protect || !valid_address(img, side, sector) {return false}
	size := sector_size(img)
	if len(data) < size {return false}
	off := sector_offset(img, side, track, sector)
	if off > img.file_size {
		// extend with blank fill so earlier sectors still read as 0xFF
		gap := make([]u8, int(off - img.file_size), context.temp_allocator)
		for i in 0 ..< len(gap) {gap[i] = FILL_BYTE}
		if n, err := os.write_at(img.file, gap, img.file_size); err != nil || n != len(gap) {return false}
	}
	n, err := os.write_at(img.file, data[:size], off)
	if err != nil || n != size {return false}
	if off + i64(size) > img.file_size {img.file_size = off + i64(size)}
	return true
}

// Create a blank, formatted-looking disk: every sector 0xFF, which DECB reads
// as an empty disk (all granules free, no directory entries). One sided disks
// are headerless; two sided ones get the 2 byte JVC header.
create_blank :: proc(path: string, tracks := DEFAULT_TRACKS, sides := 1, overwrite := false) -> Error {
	if tracks < 1 || tracks > 255 || sides < 1 || sides > 2 {return .Bad_Geometry}
	if !overwrite && os.exists(path) {return .Exists}

	header_size := 2 if sides == 2 else 0
	total := header_size + tracks * sides * DEFAULT_SECTORS * 256
	data := make([]u8, total)
	defer delete(data)
	for i in 0 ..< total {data[i] = FILL_BYTE}
	if header_size == 2 {
		data[0] = DEFAULT_SECTORS
		data[1] = u8(sides)
	}
	if err := os.write_entire_file(path, data); err != nil {return .Write_Failed}
	return .None
}

error_text :: proc(e: Error) -> string {
	switch e {
	case .None:
		return "ok"
	case .Open_Failed:
		return "cannot open the file"
	case .Unsupported_Format:
		return "unsupported disk image format (only JVC/DSK is supported)"
	case .Bad_Geometry:
		return "bad disk geometry"
	case .Exists:
		return "file already exists"
	case .Write_Failed:
		return "cannot write the file"
	}
	return "unknown error"
}
