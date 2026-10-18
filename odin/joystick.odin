package vcc

// Joystick input. The CoCo has a 6 bit DAC and a comparator per game port: a
// program writes a level to the DAC and reads PIA0 side A bit 7 to learn
// whether the selected axis is at or above that level. The analog mux (PIA0
// control bits) picks the axis. Buttons pull keyboard row bits low.
// Ports vccJoystickGetScan (standard joystick path) of joystickinput.cpp.

STICK_MAX :: 0x3FFF

Axis :: enum {
	Right_X,
	Right_Y,
	Left_X,
	Left_Y,
}

BUTTON_RIGHT_1 :: u8(1)
BUTTON_LEFT_1 :: u8(2)
BUTTON_RIGHT_2 :: u8(4)
BUTTON_LEFT_2 :: u8(8)

// Set an axis position, 0..STICK_MAX (0 means "no stick": comparator stays low).
machine_set_axis :: proc(m: ^Machine, axis: Axis, value: int) {
	m.joy_axis[axis] = u16(clamp(value, 0, STICK_MAX))
}

machine_set_button :: proc(m: ^Machine, mask: u8, down: bool) {
	if down {m.joy_buttons |= mask} else {m.joy_buttons &= ~mask}
}

// Add the comparator bit and button states to a keyboard scan byte.
joystick_scan_bits :: proc(m: ^Machine, code: u8) -> u8 {
	scan := code
	stick := int(m.joy_axis[Axis(get_mux_state(m))])
	dac := int(m.pia1.reg[0]) << 6
	if stick != 0 && stick >= dac {scan |= 0x80}
	if m.joy_buttons & BUTTON_LEFT_1 != 0 {scan &= 0xFD}
	if m.joy_buttons & BUTTON_RIGHT_1 != 0 {scan &= 0xFE}
	if m.joy_buttons & BUTTON_LEFT_2 != 0 {scan &= 0xF7}
	if m.joy_buttons & BUTTON_RIGHT_2 != 0 {scan &= 0xFB}
	return scan
}
