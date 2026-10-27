module main

import os
import wayland
import wayland.protocols.wayland as wl
import wayland.protocols.xdg_shell

// Opens a real xdg-shell toplevel window, animates it and exits when the
// window is closed or Escape is pressed.
//
//	v run examples/window
//	v run examples/window -- --frames 60   # present 60 frames, then exit
//
// The window is a wl_surface with two roles on top of it: an xdg_surface, which
// owns the configure/ack handshake, and an xdg_toplevel, which is the window
// itself. The first commit carries no buffer and asks the compositor for a
// configure event; from then on every frame is driven by a wl_callback frame
// callback, and the shared memory buffer is only redrawn once the compositor
// released it.
//
// Input comes through wl_seat: the seat reports its capabilities, and the
// keyboard it creates sends raw evdev key codes. Escape (key code 1) closes the
// window; the keymap the compositor sends is read and thrown away, because raw
// codes are enough for a shortcut like this one.

const default_width = 800

const default_height = 600

const usage = 'usage: v run examples/window [--frames <count>]'

// State is what the listeners report back to the frame loop.
struct State {
mut:
	// configured is true once the compositor sent the first configure event.
	configured bool
	// pending_serial is a configure serial that still needs an ack.
	pending_serial u32
	// width and height are the size the compositor asked for.
	width  int
	height int
	// has_size is set while the compositor asked for a specific size.
	has_size bool
	// redraw is set when another frame should be drawn.
	redraw bool
	// frames counts the frames presented so far.
	frames int
	// closed is set when the compositor says the window should close.
	closed bool
	// keyboard_created is set once the seat gave us a keyboard.
	keyboard_created bool
}

// WmBaseListener answers xdg_wm_base pings: a client that stays silent may be
// considered unresponsive.
struct WmBaseListener {}

fn (mut listener WmBaseListener) ping(proxy xdg_shell.XdgWmBase, serial u32) {
	proxy.pong(serial) or {}
}

// SurfaceListener records the configure the compositor sends for the surface.
// The ack belongs to the frame loop, which performs it together with the rest
// of the protocol handshake.
struct SurfaceListener {
mut:
	state &State
}

fn (mut listener SurfaceListener) configure(_ xdg_shell.XdgSurface, serial u32) {
	listener.state.pending_serial = serial
	listener.state.configured = true
	listener.state.redraw = true
}

// ToplevelListener records the size the window should have and keeps track of
// the close request.
struct ToplevelListener {
mut:
	state &State
}

fn (mut listener ToplevelListener) configure(_ xdg_shell.XdgToplevel, width i32, height i32, _states []u8) {
	if width > 0 && height > 0 {
		listener.state.width = int(width)
		listener.state.height = int(height)
		listener.state.has_size = true
	}
	listener.state.redraw = true
}

fn (mut listener ToplevelListener) close(_ xdg_shell.XdgToplevel) {
	listener.state.closed = true
}

fn (mut listener ToplevelListener) configure_bounds(_ xdg_shell.XdgToplevel, _width i32, _height i32) {
}

fn (mut listener ToplevelListener) wm_capabilities(_ xdg_shell.XdgToplevel, _capabilities []u8) {
}

// FrameListener is told when the compositor is ready for the next frame.
struct FrameListener {
mut:
	state &State
}

fn (mut listener FrameListener) done(_ wl.WlCallback, _callback_data u32) {
	listener.state.redraw = true
}

// SeatListener creates the keyboard as soon as the seat reports that it has
// one. The capabilities event can be sent again when devices come and go, so
// the keyboard is only created once.
struct SeatListener {
mut:
	state &State
}

fn (mut listener SeatListener) capabilities(seat wl.WlSeat, capabilities u32) {
	if listener.state.keyboard_created || capabilities & wl.wl_seat_capability_keyboard == 0 {
		return
	}
	keyboard := seat.get_keyboard() or { return }
	// The connection owns the sink that calls the listener, so the listener
	// itself is allocated on the heap and lives as long as the connection.
	keyboard.set_listener(&KeyboardListener{
		state: listener.state
	}) or { return }
	listener.state.keyboard_created = true
	println('input: keyboard ready')
}

fn (mut listener SeatListener) name(_ wl.WlSeat, _name string) {
}

// KeyboardListener receives keyboard events. The key codes are raw evdev codes:
// `wayland.key_name()` names the common ones, and `wayland.read_keymap()` hands
// back the xkb keymap for the rest.
struct KeyboardListener {
mut:
	state &State
}

fn (mut listener KeyboardListener) keymap(_ wl.WlKeyboard, format u32, fd int, size u32) {
	keymap := wayland.read_keymap(format, fd, size) or { return }
	println('input: keymap ${keymap.len} bytes')
}

fn (mut listener KeyboardListener) enter(_ wl.WlKeyboard, _serial u32, _surface wl.WlSurface, _keys []u8) {
	println('input: focus in')
}

fn (mut listener KeyboardListener) leave(_ wl.WlKeyboard, _serial u32, _surface wl.WlSurface) {
	println('input: focus out')
}

fn (mut listener KeyboardListener) key(_ wl.WlKeyboard, _serial u32, _time u32, key u32, state u32) {
	if state != wl.wl_keyboard_key_state_pressed {
		return
	}
	name := wayland.key_name(key) or { 'code ${key}' }
	println('input: ${name}')
	if key == wayland.key_escape {
		listener.state.closed = true
	}
}

fn (mut listener KeyboardListener) modifiers(_ wl.WlKeyboard, _serial u32, _mods_depressed u32, _mods_latched u32, _mods_locked u32, _group u32) {
}

fn (mut listener KeyboardListener) repeat_info(_ wl.WlKeyboard, _rate i32, _delay i32) {
}

// paint draws one frame: a gradient background that drifts with the frame
// number and a bright square bouncing across the window. xrgb8888 stores four
// bytes per pixel, blue first.
fn paint(buffer &wayland.ShmBuffer, frame int) {
	mut pixels := buffer.pixels()
	stride := buffer.stride
	drift := u8((frame * 3) & 0x3f)
	for y in 0 .. buffer.height {
		row := y * stride
		level := u8(6 + (y * 40) / buffer.height)
		for x in 0 .. buffer.width {
			offset := row + x * 4
			pixels[offset] = u8(level + drift)
			pixels[offset + 1] = u8(level / 2)
			pixels[offset + 2] = u8(level / 4)
			pixels[offset + 3] = u8(0)
		}
	}
	size := buffer.height / 6
	span := buffer.width - size
	if span <= 0 {
		return
	}
	travel := (frame * 6) % (2 * span)
	x := if travel < span { travel } else { 2 * span - travel }
	y := buffer.height / 2 - size / 2
	for dy in 0 .. size {
		row := (y + dy) * stride
		for dx in 0 .. size {
			offset := row + (x + dx) * 4
			pixels[offset] = u8(0x40)
			pixels[offset + 1] = u8(0xc0)
			pixels[offset + 2] = u8(0xff)
			pixels[offset + 3] = u8(0)
		}
	}
}

// frame_limit reads the optional --frames option: the number of frames to
// present before exiting, which makes the example usable without a human
// closing the window. Zero means "until the window is closed".
fn frame_limit() int {
	args := os.args[1..]
	mut index := 0
	for index < args.len {
		match args[index] {
			'--' {}
			'--frames' {
				if index + 1 >= args.len {
					eprintln('--frames needs a count')
					exit(2)
				}
				limit := args[index + 1].int()
				if limit <= 0 {
					eprintln('--frames needs a positive count, got ${args[index + 1]}')
					exit(2)
				}
				return limit
			}
			'-h', '--help' {
				println(usage)
				exit(0)
			}
			else {
				eprintln('unknown option ${args[index]}')
				println(usage)
				exit(2)
			}
		}
		index++
	}
	return 0
}

fn main() {
	limit := frame_limit()
	mut conn := wayland.connect()!
	defer {
		conn.close()
	}
	globals := conn.globals()!
	compositor_global := globals.find('wl_compositor') or {
		eprintln('this compositor does not advertise wl_compositor')
		return
	}
	shm_global := globals.find('wl_shm') or {
		eprintln('this compositor does not advertise wl_shm')
		return
	}
	wm_base_global := globals.find('xdg_wm_base') or {
		eprintln('this compositor does not speak xdg-shell')
		return
	}
	compositor := wl.bind_wl_compositor(conn, compositor_global)!
	shm := wl.bind_wl_shm(conn, shm_global)!
	wm_base := xdg_shell.bind_xdg_wm_base(conn, wm_base_global)!
	mut wm_base_listener := WmBaseListener{}
	wm_base.set_listener(&wm_base_listener)!

	surface := compositor.create_surface()!
	xdg_surface := wm_base.get_xdg_surface(surface)!
	toplevel := xdg_surface.get_toplevel()!
	toplevel.set_title('wayland')!
	toplevel.set_app_id('dev.wayland.window')!

	mut state := State{}
	mut surface_listener := SurfaceListener{
		state: &state
	}
	xdg_surface.set_listener(&surface_listener)!
	mut toplevel_listener := ToplevelListener{
		state: &state
	}
	toplevel.set_listener(&toplevel_listener)!
	mut frame_listener := FrameListener{
		state: &state
	}

	// The seat is optional: without one the window still works, it just cannot
	// be closed with the keyboard.
	mut seat_listener := SeatListener{
		state: &state
	}
	if seat_global := globals.find('wl_seat') {
		seat := wl.bind_wl_seat(conn, seat_global)!
		seat.set_listener(&seat_listener)!
	} else {
		println('input: the compositor has no seat, Escape will not work')
	}

	surface.commit()!

	mut buffer := wayland.ShmBuffer.new(shm, default_width, default_height, wl.wl_shm_format_xrgb8888)!
	println('window: ${buffer.width}x${buffer.height}, close it or press Escape to quit')

	for !state.closed {
		// Deliver one event, which also flushes the requests queued below.
		conn.dispatch()!
		if state.pending_serial != 0 {
			xdg_surface.ack_configure(state.pending_serial)!
			state.pending_serial = 0
		}
		if state.has_size && !buffer.busy
			&& (state.width != buffer.width || state.height != buffer.height) {
			// The compositor asked for another size: the buffer is replaced.
			buffer.destroy()
			buffer = wayland.ShmBuffer.new(shm, state.width, state.height, wl.wl_shm_format_xrgb8888)!
		}
		if !state.configured || !state.redraw || buffer.busy {
			continue
		}
		paint(buffer, state.frames)
		buffer.attach(surface)!
		callback := surface.frame()!
		callback.set_listener(&frame_listener)!
		surface.commit()!
		state.redraw = false
		state.frames++
		if limit > 0 && state.frames >= limit {
			break
		}
	}
	buffer.destroy()
	println('window: closed after ${state.frames} frames')
}
