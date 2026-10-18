package vcc

import SDL "vendor:sdl2"

// Two MC6821 PIAs (ports mc6821.cpp).
//   PIA0 $FF00-$FF03: keyboard/joystick in, HSYNC (CA1) and VSYNC (CB1) IRQs.
//   PIA1 $FF20-$FF23: 6-bit DAC, cassette, VDG mode out, cartridge FIRQ (CB1).
//
// Like VCC, `reg[n]` holds the port/control registers 0..3 (A data, A ctrl,
// B data, B ctrl) and `dd[n]` holds the data direction registers, which share
// the data register addresses until control bit 2 is set.

Pia :: struct {
	reg: [4]u8,
	dd:  [4]u8,
}

Edge :: enum {
	Falling,
	Rising,
	Any,
}

PIA_CTRL_DDR_SELECT :: 4

pia_reset :: proc(m: ^Machine) {
	m.pia0 = {}
	m.pia1 = {}
	m.asample, m.ssample, m.csample = 0, 0, 0
}

// Analog multiplexer select (joystick axis / DAC routing): 0..3.
get_mux_state :: proc(m: ^Machine) -> u8 {
	return ((m.pia0.reg[1] & 8) >> 3) + ((m.pia0.reg[3] & 8) >> 2)
}

pia0_read :: proc(m: ^Machine, port: u8) -> u8 {
	p := &m.pia0
	dda := p.reg[1] & PIA_CTRL_DDR_SELECT != 0
	ddb := p.reg[3] & PIA_CTRL_DDR_SELECT != 0
	switch port {
	case 1, 3:
		return p.reg[port]
	case 0:
		if dda {
			p.reg[1] &= 63
			cpu_deassert_interrupt(&m.cpu, .PIA0_HSYNC, .IRQ)
			return joystick_scan_bits(m, keyboard_get_scan(&m.kb, p.reg[2] | ~p.dd[2]))
		}
		return p.dd[0]
	case 2:
		if ddb {
			p.reg[3] &= 63
			cpu_deassert_interrupt(&m.cpu, .PIA0_VSYNC, .IRQ)
			return p.reg[2] & p.dd[2]
		}
		return p.dd[2]
	}
	return 0
}

pia0_write :: proc(m: ^Machine, port: u8, data: u8) {
	p := &m.pia0
	dda := p.reg[1] & PIA_CTRL_DDR_SELECT != 0
	ddb := p.reg[3] & PIA_CTRL_DDR_SELECT != 0
	switch port {
	case 0:
		if dda {p.reg[0] = data} else {p.dd[0] = data}
	case 2:
		if ddb {p.reg[2] = data} else {p.dd[2] = data}
	case 1:
		p.reg[1] = data & 0x3F
		// Disabling the interrupt (or a mode that cannot fire) drops the line.
		if data & 0x01 == 0 && (data & 0x28) != 0x08 {
			cpu_deassert_interrupt(&m.cpu, .PIA0_HSYNC, .IRQ)
		}
	case 3:
		p.reg[3] = data & 0x3F
		if data & 0x01 == 0 && (data & 0x28) != 0x08 {
			cpu_deassert_interrupt(&m.cpu, .PIA0_VSYNC, .IRQ)
		}
	}
}

pia1_read :: proc(m: ^Machine, port_in: u8) -> u8 {
	p := &m.pia1
	port := port_in - 0x20
	dda := p.reg[1] & PIA_CTRL_DDR_SELECT != 0
	ddb := p.reg[3] & PIA_CTRL_DDR_SELECT != 0
	switch port {
	case 1, 3:
		return p.reg[port]
	case 2:
		if ddb {
			p.reg[3] &= 63
			cpu_deassert_interrupt(&m.cpu, .PIA1_CART, .FIRQ)
			return p.reg[2] & p.dd[2]
		}
		return p.dd[2]
	case 0:
		if dda {
			p.reg[1] &= 63 // clears the CD flag (cassette in)
			cpu_deassert_interrupt(&m.cpu, .PIA1_CD, .FIRQ)
			return p.reg[0]
		}
		return p.dd[0]
	}
	return 0
}

pia1_write :: proc(m: ^Machine, port_in: u8, data: u8) {
	p := &m.pia1
	port := port_in - 0x20
	dda := p.reg[1] & PIA_CTRL_DDR_SELECT != 0
	ddb := p.reg[3] & PIA_CTRL_DDR_SELECT != 0
	switch port {
	case 0:
		if dda {
			p.reg[0] = data
			if get_mux_state(m) == 0 {
				if p.reg[3] & 8 != 0 {
					m.asample = (p.reg[0] & 0xFC) >> 1 // 6 bit DAC, 0..127
				} else {
					m.csample = p.reg[0] & 0xFC // cassette write
				}
			}
		} else {
			p.dd[0] = data
		}
	case 2:
		if ddb {
			p.reg[2] = data & p.dd[2]
			m.ssample = (p.reg[2] & 2) << 6 // single bit sound
		} else {
			p.dd[2] = data
		}
	case 1:
		p.reg[1] = data & 0x3F
		m.cass_motor = data & 8 != 0
	case 3:
		p.reg[3] = data & 0x3F
	}
}

// VDG mode bits ($FF22 bits 7-3: A/G, GM2, GM1/INV, GM0, CSS).
pia_vdg_mode :: proc(m: ^Machine) -> u8 {return (m.pia1.reg[2] & 248) >> 3}

// HSYNC (CA1 of PIA0), every scanline.
irq_hs :: proc(m: ^Machine, edge: Edge) {
	p := &m.pia0
	switch edge {
	case .Falling:
		if p.reg[1] & 2 != 0 {return} // configured for rising edge
	case .Rising:
		if p.reg[1] & 2 == 0 {return}
	case .Any:
	}
	p.reg[1] |= 128
	if p.reg[1] & 1 != 0 {
		cpu_assert_interrupt(&m.cpu, .PIA0_HSYNC, .IRQ)
	}
}

// VSYNC (CB1 of PIA0), 60Hz. Also latches the cartridge line when a cart is
// inserted and auto-start is on.
irq_fs :: proc(m: ^Machine, edge: Edge) {
	p := &m.pia0
	if m.cart_inserted && m.cart_autostart {
		pia_assert_cart(m)
	}
	switch edge {
	case .Falling:
		if p.reg[3] & 2 != 0 {return}
	case .Rising:
		if p.reg[3] & 2 == 0 {return}
	case .Any:
	}
	p.reg[3] |= 128
	if p.reg[3] & 1 != 0 {
		cpu_assert_interrupt(&m.cpu, .PIA0_VSYNC, .IRQ)
	}
}

// Cartridge line (CB1 of PIA1) raising FIRQ.
pia_assert_cart :: proc(m: ^Machine) {
	m.pia1.reg[3] |= 128
	if m.pia1.reg[3] & 1 != 0 {
		cpu_assert_interrupt(&m.cpu, .PIA1_CART, .FIRQ)
	} else {
		cpu_deassert_interrupt(&m.cpu, .PIA1_CART, .FIRQ)
	}
}

machine_key_event :: proc(m: ^Machine, sc: SDL.Scancode, down: bool) {
	keyboard_key(&m.kb, sc, down)
	if down {gime_assert_keyboard(m)}
}
