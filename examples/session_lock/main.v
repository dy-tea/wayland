module main

import os
import wayland
import wayland.protocols.ext_session_lock_v1 as lock_proto
import wayland.protocols.wayland as wl

// Locks the session the way a screen locker does, draws on every output and
// unlocks again on the first key press.
//
//	v run examples/session_lock
//	v run examples/session_lock -- --frames 120   # present 120 frames, then unlock
//
// ext-session-lock-v1 is the protocol of screen lockers (swaylock and
// friends). Locking is a role, not a window: the client asks the manager to
// lock the session, and while the lock is alive the compositor hides every
// other client's output - notifications, launchers, everything. The lock
// then covers each output with a lock surface of its own, which behaves
// like an xdg surface minus the niceties: the compositor sends a configure
// with the output size, the client acks and commits, and from the locked
// event on the session is visually locked and the keyboard is the lock
// surface's.
//
// The two ways out are mirrored in the two requests: before the compositor
// agreed (locked), destroy() cancels the attempt; after it, the session is
// only unlocked with unlock_and_destroy(), which hands control back to the
// compositor. A compositor that already has a lock answers finished instead,
// and the example explains that and exits - locking is exclusive.
//
// The keyboard needs no special handling: the compositor routes key events
// to the lock surface, so the ordinary wl_seat keyboard sees them. Any key
// press unlocks, because a real locker would ask for a password there.

const usage = 'usage: v run examples/session_lock [--frames <count>]'

const fallback_width = 800

const fallback_height = 600

// State is what the listeners report back to the main loop.
struct State {
mut:
	// locked is set by ext_session_lock_v1.locked, the moment the session
	// counts as locked; finished is set when the lock was refused or taken
	// away; quit is set by any key press.
	locked   bool
	finished bool
	quit     bool
	// surfaces is one entry per output, in the order the globals listed
	// them. They are heap references because listeners and the main loop
	// both fill in fields as the events arrive.
	surfaces []&LockSurface
	// frames counts the draw cycles, for --frames.
	frames int
	// keyboard is the keyboard the seat handed out, and keyboard_created
	// says whether it is there: a seat can gain and lose devices at run
	// time, and the capabilities event is sent again when they do.
	keyboard         wl.WlKeyboard
	keyboard_created bool
}

// LockSurface is one output's lock surface and its drawing state.
struct LockSurface {
	surface      wl.WlSurface
	lock_surface lock_proto.ExtSessionLockSurfaceV1
mut:
	// pending_serial is a configure that still needs an ack.
	pending_serial u32
	// configured is true once the compositor sent the first configure.
	configured bool
	redraw     bool
	// width and height are the size the compositor asked for.
	width  int
	height int
	// buffer is redrawn in place; it is replaced when the size changes.
	buffer &wayland.ShmBuffer = unsafe { nil }
}

// LockListener follows the lock itself.
struct LockListener {
mut:
	state &State
}

fn (mut listener LockListener) locked(_ lock_proto.ExtSessionLockV1) {
	listener.state.locked = true
	println('session_lock: the session is locked - press any key to unlock')
}

fn (mut listener LockListener) finished(_ lock_proto.ExtSessionLockV1) {
	// The compositor refused the lock (another locker holds it) or ended it
	// from its side. Either way there is nothing left to draw on.
	listener.state.finished = true
}

// LockSurfaceListener records the configure of one output's lock surface.
struct LockSurfaceListener {
mut:
	state &State
	index int
}

fn (mut listener LockSurfaceListener) configure(_ lock_proto.ExtSessionLockSurfaceV1, serial u32, width u32, height u32) {
	mut surface := listener.state.surfaces[listener.index]
	surface.pending_serial = serial
	surface.configured = true
	surface.redraw = true
	// The configure carries the size of the output; zero means the
	// compositor did not say, and the fallback keeps the example working.
	surface.width = if width > 0 { int(width) } else { fallback_width }
	surface.height = if height > 0 { int(height) } else { fallback_height }
}

// FrameListener is told when an output is ready for the next frame.
struct FrameListener {
mut:
	state &State
	index int
}

fn (mut listener FrameListener) done(_ wl.WlCallback, _callback_data u32) {
	listener.state.surfaces[listener.index].redraw = true
}

// SeatListener creates the keyboard while the seat reports having one.
struct SeatListener {
mut:
	state &State
}

fn (mut listener SeatListener) capabilities(seat wl.WlSeat, capabilities u32) {
	has_keyboard := capabilities & wl.wl_seat_capability_keyboard != 0
	if has_keyboard && !listener.state.keyboard_created {
		keyboard := seat.get_keyboard() or {
			eprintln('session_lock: could not create the keyboard: ${err.msg()}')
			return
		}
		keyboard.set_listener(&KeyboardListener{
			state: listener.state
		}) or {
			eprintln('session_lock: could not listen to the keyboard: ${err.msg()}')
			return
		}
		listener.state.keyboard = keyboard
		listener.state.keyboard_created = true
	} else if !has_keyboard && listener.state.keyboard_created {
		listener.state.keyboard.release() or {}
		listener.state.keyboard_created = false
	}
}

fn (mut listener SeatListener) name(_ wl.WlSeat, _name string) {
}

// KeyboardListener unlocks on any key press. The keymap the compositor sends
// is read and thrown away: raw key codes are enough to notice "a key was
// pressed", which is all a demo needs.
struct KeyboardListener {
mut:
	state &State
}

fn (mut listener KeyboardListener) keymap(_ wl.WlKeyboard, format u32, fd int, size u32) {
	keymap := wayland.read_keymap(format, fd, size) or { return }
	println('session_lock: keymap ${keymap.len} bytes')
}

fn (mut listener KeyboardListener) enter(_ wl.WlKeyboard, _serial u32, _surface wl.WlSurface, _keys []u8) {
}

fn (mut listener KeyboardListener) leave(_ wl.WlKeyboard, _serial u32, _surface wl.WlSurface) {
}

fn (mut listener KeyboardListener) key(_ wl.WlKeyboard, _serial u32, _time u32, key u32, state u32) {
	if state != wl.wl_keyboard_key_state_pressed {
		return
	}
	name := wayland.key_name(key) or { 'code ${key}' }
	println('session_lock: ${name} pressed, unlocking')
	listener.state.quit = true
}

fn (mut listener KeyboardListener) modifiers(_ wl.WlKeyboard, _serial u32, _mods_depressed u32, _mods_latched u32, _mods_locked u32, _group u32) {
}

fn (mut listener KeyboardListener) repeat_info(_ wl.WlKeyboard, _rate i32, _delay i32) {
}

// paint draws one frame of a lock surface: a dark gradient with a band of
// light moving across it, and a brighter field once the session really is
// locked. A locker would draw a password prompt here; drawing text needs a
// font, which is why the demo stays abstract.
fn paint(buffer &wayland.ShmBuffer, frame int, locked bool) {
	mut pixels := buffer.pixels()
	stride := buffer.stride
	for y in 0 .. buffer.height {
		row := y * stride
		level := u8(if locked {
			16 + (y * 24) / buffer.height
		} else {
			4 + (y * 12) / buffer.height
		})
		for x in 0 .. buffer.width {
			offset := row + x * 4
			pixels[offset] = level
			pixels[offset + 1] = u8(level / 2)
			pixels[offset + 2] = u8(level * 3)
			pixels[offset + 3] = u8(0)
		}
	}
	// A band of light that bounces from edge to edge, so the animation is
	// visible while the lock is held.
	size := buffer.height / 5
	span := buffer.width - size
	if span <= 0 {
		return
	}
	travel := (frame * 7) % (2 * span)
	x := if travel < span { travel } else { 2 * span - travel }
	for dy in 0 .. buffer.height {
		row := dy * stride
		shade := u8(40 + (dy * 60) / buffer.height)
		for dx in 0 .. size {
			offset := row + (x + dx) * 4
			pixels[offset] = u8(0)
			pixels[offset + 1] = shade
			pixels[offset + 2] = shade
			pixels[offset + 3] = u8(0)
		}
	}
}

// frame_limit reads the optional --frames option: the number of draw cycles
// before the example unlocks and exits, which makes it usable without a
// human pressing a key. Zero means "until a key is pressed".
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
	manager_global := globals.find('ext_session_lock_manager_v1') or {
		eprintln('this compositor does not speak ext-session-lock-v1')
		return
	}
	output_globals := globals.find_all('wl_output')
	if output_globals.len == 0 {
		eprintln('this compositor does not advertise any output to lock')
		return
	}
	compositor := wl.bind_wl_compositor(conn, compositor_global)!
	shm := wl.bind_wl_shm(conn, shm_global)!

	// The lock is asked for before the surfaces are created: the protocol
	// wants the role established first, and a compositor that refuses sends
	// finished right away.
	manager := lock_proto.bind_ext_session_lock_manager_v1(conn, manager_global)!
	lock_session := manager.lock_()!
	mut state := State{}
	lock_session.set_listener(&LockListener{
		state: &state
	})!

	for global in output_globals {
		output := wl.bind_wl_output(conn, global)!
		surf := compositor.create_surface()!
		lock_surface := lock_session.get_lock_surface(surf, output)!
		lock_surface.set_listener(&LockSurfaceListener{
			state: &state
			index: state.surfaces.len
		})!
		state.surfaces << &LockSurface{
			surface:      surf
			lock_surface: lock_surface
		}
	}

	// The seat is optional: without one the lock still works, it just cannot
	// be unlocked from here.
	if seat_global := globals.find('wl_seat') {
		seat := wl.bind_wl_seat(conn, seat_global)!
		seat.set_listener(&SeatListener{
			state: &state
		})!
	} else {
		println('session_lock: the compositor has no seat, use --frames to exit')
	}

	// The first commit carries no buffer: it asks for the configure events
	// that name the size of every output.
	for entry in state.surfaces {
		entry.surface.commit()!
	}
	println('session_lock: locked ${output_globals.len} output(s)')

	for !state.quit && !state.finished {
		conn.dispatch()!
		mut presented := false
		for index, surface in state.surfaces {
			if !surface.configured {
				continue
			}
			if surface.pending_serial != 0 {
				surface.lock_surface.ack_configure(surface.pending_serial)!
				state.surfaces[index].pending_serial = 0
			}
			if surface.buffer != unsafe { nil }
				&& (surface.width != surface.buffer.width || surface.height != surface.buffer.height) {
				// The compositor asked for another size: the buffer is
				// replaced, like in the window example.
				surface.buffer.destroy()
				state.surfaces[index].buffer = unsafe { nil }
			}
			if surface.buffer == unsafe { nil } && !surface.redraw {
				continue
			}
			if surface.buffer == unsafe { nil } {
				state.surfaces[index].buffer = wayland.ShmBuffer.new(shm, surface.width, surface.height, wl.wl_shm_format_xrgb8888)!
			}
			if surface.redraw && !surface.buffer.busy {
				paint(surface.buffer, state.frames, state.locked)
				state.surfaces[index].buffer.attach(surface.surface)!
				callback := surface.surface.frame()!
				callback.set_listener(&FrameListener{
					state: &state
					index: index
				})!
				surface.surface.commit()!
				state.surfaces[index].redraw = false
				presented = true
			}
		}
		if presented {
			state.frames++
			if limit > 0 && state.frames >= limit {
				break
			}
		}
	}

	// The way out depends on how far the handshake got: an acknowledged
	// lock can only end with unlock_and_destroy, an unconfirmed one with
	// plain destroy. Closing the connection would work too, but the
	// requests are the protocol's way of saying goodbye.
	if state.locked {
		lock_session.unlock_and_destroy()!
		conn.roundtrip()!
		println('session_lock: unlocked after ${state.frames} frames')
	} else {
		lock_session.destroy()!
		if state.finished {
			println('session_lock: the compositor refused the lock (is another locker running?)')
		} else {
			println('session_lock: cancelled after ${state.frames} frames')
		}
	}
	for entry in state.surfaces {
		if entry.buffer != unsafe { nil } {
			entry.buffer.destroy()
		}
	}
}
