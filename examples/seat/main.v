module main

import wayland
import wayland.protocols.wayland

// Binds the seat and prints what the compositor reports about it.
//
//	v run examples/seat
//
// wl_seat is one of the interfaces that send events as soon as a client binds
// it, which makes it a compact example of typed listeners: implement the
// events you care about, install the listener, drive the connection.
struct SeatListener {
mut:
	has_name     bool
	name         string
	has_caps     bool
	capabilities u32
}

fn (mut listener SeatListener) capabilities(_ wayland.WlSeat, capabilities u32) {
	listener.has_caps = true
	listener.capabilities = capabilities
}

fn (mut listener SeatListener) name(_ wayland.WlSeat, name string) {
	listener.has_name = true
	listener.name = name
}

fn describe_capabilities(capabilities u32) string {
	mut names := []string{}
	if capabilities & wayland.wl_seat_capability_pointer != 0 {
		names << 'pointer'
	}
	if capabilities & wayland.wl_seat_capability_keyboard != 0 {
		names << 'keyboard'
	}
	if capabilities & wayland.wl_seat_capability_touch != 0 {
		names << 'touch'
	}
	if names.len == 0 {
		return 'none'
	}
	return names.join(', ')
}

fn main() {
	mut conn := wayland.connect()!
	defer {
		conn.close()
	}
	globals := conn.globals()!
	seat_global := globals.find('wl_seat') or {
		eprintln('this compositor does not advertise wl_seat')
		return
	}
	mut seat := wayland.bind_wl_seat(conn, seat_global)!
	mut listener := SeatListener{}
	seat.set_listener(&listener)!
	// The compositor sends name and capabilities right after the bind.
	conn.roundtrip()!
	if listener.has_name {
		println('seat: ${listener.name}')
	} else {
		println('seat: (the compositor did not send a name)')
	}
	if listener.has_caps {
		println('capabilities: ${describe_capabilities(listener.capabilities)}')
	} else {
		println('capabilities: (the compositor did not send them)')
	}
	// Listening on input devices follows the same shape: the seat creates them
	// with get_keyboard(), get_pointer() and get_touch(), and the generated
	// wl_keyboard, wl_pointer and wl_touch listeners receive their events.
	println('interface version: ${seat_global.version}')
}
