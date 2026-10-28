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
// keyboard and pointer it hands out are created from them. The keyboard sends
// raw evdev key codes - Escape (key code 1) closes the window, and the keymap
// the compositor sends is read and thrown away, because raw codes are enough
// for a shortcut like this one. The pointer paints a marker where it is, gets a
// cursor image of its own, drags the window through the compositor when the
// left button goes down, and changes the speed of the animation when scrolled.

const default_width = 800

const default_height = 600

// cursor_size is the edge length of the cursor images, the size themes use.
const cursor_size = 24

const cursor_hotspot = cursor_size / 2

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
	// keyboard is the keyboard the seat handed out, and keyboard_created says
	// whether it is there: a seat can gain and lose devices at run time.
	keyboard         wl.WlKeyboard
	keyboard_created bool
	// pointer is the pointer helper of the seat, nil while there is no pointer.
	pointer &wayland.Pointer = unsafe { nil }
	// pointer_inside is what `pointer.inside` was in the previous frame: the
	// cursor and the printing hang off the moment that changes.
	pointer_inside bool
	// buttons is the set of pointer buttons of the previous frame, which is how
	// a press and a release are told apart.
	buttons []u32
	// cursor and cursor_pressed are the images the cursor switches between.
	cursor         &wayland.ShmBuffer = unsafe { nil }
	cursor_pressed &wayland.ShmBuffer = unsafe { nil }
	// speed scales the animation; scrolling changes it.
	speed f64 = 1.0
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

// SeatListener creates the keyboard and the pointer as soon as the seat reports
// that it has them, and releases them when they go away: the capabilities event
// is sent again whenever devices come and go.
struct SeatListener {
mut:
	state      &State
	compositor wl.WlCompositor
}

fn (mut listener SeatListener) capabilities(seat wl.WlSeat, capabilities u32) {
	listener.update_keyboard(seat, capabilities)
	listener.update_pointer(seat, capabilities)
}

fn (mut listener SeatListener) update_keyboard(seat wl.WlSeat, capabilities u32) {
	has_keyboard := capabilities & wl.wl_seat_capability_keyboard != 0
	if has_keyboard && !listener.state.keyboard_created {
		keyboard := seat.get_keyboard() or {
			eprintln('input: could not create the keyboard: ${err.msg()}')
			return
		}
		// The connection owns the sink that calls the listener, so the listener
		// itself is allocated on the heap and lives as long as the connection.
		keyboard.set_listener(&KeyboardListener{
			state: listener.state
		}) or {
			eprintln('input: could not listen to the keyboard: ${err.msg()}')
			return
		}
		listener.state.keyboard = keyboard
		listener.state.keyboard_created = true
		println('input: keyboard ready')
	} else if !has_keyboard && listener.state.keyboard_created {
		listener.state.keyboard.release() or {}
		listener.state.keyboard_created = false
		println('input: keyboard gone')
	}
}

fn (mut listener SeatListener) update_pointer(seat wl.WlSeat, capabilities u32) {
	has_pointer := capabilities & wl.wl_seat_capability_pointer != 0
	if has_pointer && listener.state.pointer == unsafe { nil } {
		pointer := wayland.Pointer.new(listener.compositor, seat) or {
			eprintln('input: could not create the pointer: ${err.msg()}')
			return
		}
		listener.state.pointer = pointer
		println('input: pointer ready')
	} else if !has_pointer && listener.state.pointer != unsafe { nil } {
		mut pointer := listener.state.pointer
		pointer.release() or {}
		listener.state.pointer = unsafe { nil }
		listener.state.pointer_inside = false
		println('input: pointer gone')
	}
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
// number, a bright square bouncing across the window, and a marker where the
// pointer is. xrgb8888 stores four bytes per pixel, blue first.
fn paint(buffer &wayland.ShmBuffer, state &State, frame int) {
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
	if state.pointer != unsafe { nil } && state.pointer.inside {
		draw_marker(buffer, state.pointer.x, state.pointer.y)
	}
	size := buffer.height / 6
	span := buffer.width - size
	if span <= 0 {
		return
	}
	// Scrolling scales the animation: the square still bounces from edge to
	// edge, only faster or slower.
	travel := (int(f64(frame) * 6 * state.speed)) % (2 * span)
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

// draw_marker draws a small crosshair where the pointer is, clipped to the
// buffer: the pointer can sit outside it, for instance after a resize.
fn draw_marker(buffer &wayland.ShmBuffer, x int, y int) {
	mut pixels := buffer.pixels()
	stride := buffer.stride
	radius := 6
	for dy in -radius .. radius + 1 {
		for dx in -radius .. radius + 1 {
			// A plus sign: either arm is one pixel wide around the position.
			vertical := dx >= -1 && dx <= 1
			horizontal := dy >= -1 && dy <= 1
			if !vertical && !horizontal {
				continue
			}
			px := x + dx
			py := y + dy
			if px < 0 || py < 0 || px >= buffer.width || py >= buffer.height {
				continue
			}
			offset := py * stride + px * 4
			pixels[offset] = u8(0x40)
			pixels[offset + 1] = u8(0xe0)
			pixels[offset + 2] = u8(0x60)
			pixels[offset + 3] = u8(0)
		}
	}
}

// draw_cursor paints one of the two cursor images: a crosshair with a hole in
// the middle, or a filled dot while a button is held. argb8888 stores four
// bytes per pixel, blue first and alpha last, so pixels nobody writes stay
// transparent and the compositor draws them as see-through.
fn draw_cursor(buffer &wayland.ShmBuffer, pressed bool) {
	mut pixels := buffer.pixels()
	center := cursor_size / 2
	radius := cursor_size / 2 - 2
	for y in 0 .. cursor_size {
		for x in 0 .. cursor_size {
			dx := x - center
			dy := y - center
			distance := dx * dx + dy * dy
			if pressed {
				if distance <= radius * radius {
					// A light disc with a dark rim, so it is visible on any
					// background.
					level := if distance >= (radius - 1) * (radius - 1) {
						u8(0x20)
					} else {
						u8(0xff)
					}
					write_cursor_pixel(mut pixels, x, y, level)
				}
			} else if (dx >= -1 && dx <= 1) || (dy >= -1 && dy <= 1) {
				// The arms of the crosshair, with the middle left empty so that
				// the exact position stays visible.
				if dx >= -2 && dx <= 2 && dy >= -2 && dy <= 2 {
					continue
				}
				write_cursor_pixel(mut pixels, x, y, 0xff)
			}
		}
	}
}

fn write_cursor_pixel(mut pixels []u8, x int, y int, level u8) {
	offset := (y * cursor_size + x) * 4
	pixels[offset] = level
	pixels[offset + 1] = level
	pixels[offset + 2] = level
	pixels[offset + 3] = 0xff
}

// handle_pointer reads what the pointer reported since the last frame: the
// marker follows it, the cursor image says what it is doing, a left press drags
// the window, and scrolling changes the speed of the animation.
fn handle_pointer(mut state State, seat wl.WlSeat, has_seat bool, toplevel xdg_shell.XdgToplevel) {
	mut pointer := state.pointer
	if _ := pointer.take_motion() {
		// The marker draws at pointer.x and pointer.y, so the distance is only
		// interesting as a reason to draw another frame.
		state.redraw = true
	}
	if scroll := pointer.take_scroll() {
		if scroll.y != 0 {
			step := if scroll.y > 0 { 1.25 } else { 0.8 }
			mut speed := state.speed * step
			if speed < 0.1 {
				speed = 0.1
			}
			if speed > 8 {
				speed = 8
			}
			state.speed = speed
			println('input: scrolled ${scroll.y:.1f} (${wayland.axis_source_name(scroll.source) or { 'unknown' }}), speed x${state.speed:.2f}')
		}
		state.redraw = true
	}

	// The cursor image is undefined after an enter until the client sets one.
	if pointer.inside && !state.pointer_inside {
		pointer.set_cursor(state.cursor, cursor_hotspot, cursor_hotspot) or {}
		println('input: pointer entered at ${pointer.x}, ${pointer.y}')
	} else if !pointer.inside && state.pointer_inside {
		println('input: pointer left')
	}
	for button in pointer.pressed_buttons() {
		if button !in state.buttons {
			println('input: ${wayland.button_name(button) or { 'button ${button}' }} pressed')
		}
	}
	for button in state.buttons {
		if !pointer.pressed(button) {
			println('input: ${wayland.button_name(button) or { 'button ${button}' }} released')
		}
	}

	// A left press drags the window: from there on the compositor moves it, and
	// all it needs for that is the seat and the serial of the press. The cursor
	// has an image of its own while the button is held.
	held := pointer.pressed(wayland.btn_left)
	was_held := wayland.btn_left in state.buttons
	if held && !was_held {
		if has_seat {
			toplevel.move(seat, pointer.serial) or {}
		}
		pointer.set_cursor(state.cursor_pressed, cursor_hotspot, cursor_hotspot) or {}
	} else if !held && was_held && pointer.inside {
		pointer.set_cursor(state.cursor, cursor_hotspot, cursor_hotspot) or {}
	}

	state.pointer_inside = pointer.inside
	state.buttons = pointer.pressed_buttons()
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
	// be closed with the keyboard or dragged with the pointer.
	mut seat_listener := SeatListener{
		state:      &state
		compositor: compositor
	}
	mut seat := wl.WlSeat{}
	mut seat_bound := false
	if seat_global := globals.find('wl_seat') {
		seat = wl.bind_wl_seat(conn, seat_global)!
		seat.set_listener(&seat_listener)!
		seat_bound = true
	} else {
		println('input: the compositor has no seat, Escape will not work')
	}

	surface.commit()!

	mut buffer := wayland.ShmBuffer.new(shm, default_width, default_height, wl.wl_shm_format_xrgb8888)!
	// The cursor images are buffers of their own, in a 32 bit format with alpha,
	// and the compositor shows one of them instead of its own cursor while the
	// pointer is over one of this client's surfaces.
	mut cursor := wayland.ShmBuffer.new(shm, cursor_size, cursor_size, wl.wl_shm_format_argb8888)!
	mut cursor_pressed := wayland.ShmBuffer.new(shm, cursor_size, cursor_size, wl.wl_shm_format_argb8888)!
	draw_cursor(cursor, false)
	draw_cursor(cursor_pressed, true)
	state.cursor = cursor
	state.cursor_pressed = cursor_pressed
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
		if state.pointer != unsafe { nil } {
			handle_pointer(mut state, seat, seat_bound, toplevel)
		}
		if !state.configured || !state.redraw || buffer.busy {
			continue
		}
		paint(buffer, &state, state.frames)
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
	cursor.destroy()
	cursor_pressed.destroy()
	println('window: closed after ${state.frames} frames')
}
