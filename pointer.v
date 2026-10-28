module wayland

import wayland.protocols.wayland as wl

// Pointer input.
//
// wl_pointer reports one logical piece of input as a group of events with a
// wl_pointer.frame at the end: a scroll arrives as a value, a source and
// sometimes discrete steps, a drag as motion, buttons and the point where the
// press happened. Acting on each event as it lands means acting on half a
// scroll, so `Pointer` keeps the state and hands out the deltas of a frame.
//
// The helper installs itself as the listener of the pointer it creates, so
// there is nothing for the application to implement: the frame loop reads `x`,
// `y`, `inside` and `pressed()`, takes the deltas it needs, and `set_cursor()`
// with an image of its own.

// Pointer buttons, as the evdev codes wl_pointer.button reports
// (linux/input-event-codes.h).
pub const btn_left = u32(0x110)

pub const btn_right = u32(0x111)

pub const btn_middle = u32(0x112)

pub const btn_side = u32(0x113)

pub const btn_extra = u32(0x114)

pub const btn_forward = u32(0x115)

pub const btn_back = u32(0x116)

// button_name returns the name of a button code, for the codes this file
// defines.
pub fn button_name(button u32) ?string {
	return match button {
		btn_left { 'Left' }
		btn_right { 'Right' }
		btn_middle { 'Middle' }
		btn_side { 'Side' }
		btn_extra { 'Extra' }
		btn_forward { 'Forward' }
		btn_back { 'Back' }
		else { none }
	}
}

// axis_name returns the name of a wl_pointer.axis value.
pub fn axis_name(axis u32) ?string {
	return match axis {
		wl.wl_pointer_axis_vertical_scroll { 'vertical' }
		wl.wl_pointer_axis_horizontal_scroll { 'horizontal' }
		else { none }
	}
}

// axis_source_name returns the name of a wl_pointer.axis_source value, which
// tells how a scroll was generated.
pub fn axis_source_name(source u32) ?string {
	return match source {
		wl.wl_pointer_axis_source_wheel { 'wheel' }
		wl.wl_pointer_axis_source_finger { 'finger' }
		wl.wl_pointer_axis_source_continuous { 'continuous' }
		wl.wl_pointer_axis_source_wheel_tilt { 'wheel tilt' }
		else { none }
	}
}

// Motion is how far the pointer moved, in surface pixels.
pub struct Motion {
pub:
	dx int
	dy int
}

// Scroll is the axis input of one frame: `x` and `y` are the distances scrolled
// along each axis, in surface coordinate units, already converted from the 24.8
// fixed point the protocol sends. A positive vertical value is what a wheel
// rolled away from the user sends, the direction that scrolls further down a
// document; a trackpad sends smaller values with source `finger`.
pub struct Scroll {
pub:
	x f64
	y f64
	// steps_x and steps_y count whole wheel steps. Client side, the discrete
	// events the protocol sends are in wheel clicks (up to wl_pointer version 7)
	// or in 120ths of one (version 8 and later), which are divided down here.
	steps_x i32
	steps_y i32
	// source is the wl_pointer.axis_source that caused the scroll. The event
	// only exists since wl_pointer version 5, so a client bound to an older
	// version only ever sees the default, which is the wheel.
	source u32
	// stopped is true when the axis input that caused this scroll ended in this
	// frame, which is what kinetic scrolling waits for. Compositors send it for
	// fingers, and only sometimes for wheels.
	stopped bool
}

// Pointer is a wl_pointer that keeps its own state.
//
// `x`, `y` and `inside` are the position within the surface the pointer is over,
// `serial` is the serial that the cursor and the xdg-shell grabs expect, and
// `pressed()` answers for the buttons. The rest of the input of a frame is taken
// with `take_motion()`, `take_scroll()` and `take_frame()`.
@[heap]
pub struct Pointer {
pub mut:
	// x and y are the pointer position within the focused surface, in pixels.
	x int
	y int
	// inside is true while the pointer is over a surface of this client.
	inside bool
	// serial is the serial of the most recent enter or button event: the one
	// set_cursor, xdg_toplevel.move and xdg_toplevel.resize expect.
	serial u32
mut:
	proxy          wl.WlPointer
	cursor_surface wl.WlSurface
	// buttons holds the button codes currently pressed.
	buttons []u32
	// fx and fy are the position with the precision the protocol sends.
	fx f64
	fy f64
	// moved, motion_dx and motion_dy accumulate the motion of a frame.
	moved     bool
	motion_dx int
	motion_dy int
	// The axis input of a frame is accumulated here and handed out as a Scroll.
	scroll_x       f64
	scroll_y       f64
	scroll_steps_x i32
	scroll_steps_y i32
	scroll_source  u32
	scroll_stopped bool
	scrolled       bool
	// frame_ready is set by wl_pointer.frame.
	frame_ready bool
}

// new creates the pointer of a seat and installs the listener that keeps its
// state up to date. `compositor` is only used for the surface a cursor image is
// drawn on, which is created here and owned by the pointer.
pub fn Pointer.new(compositor wl.WlCompositor, seat wl.WlSeat) !&Pointer {
	mut pointer := &Pointer{
		proxy:          seat.get_pointer()!
		cursor_surface: compositor.create_surface()!
	}
	pointer.proxy.set_listener(&PointerSink{
		pointer: pointer
	})!
	return pointer
}

// pressed reports whether a button is held down.
pub fn (p &Pointer) pressed(button u32) bool {
	return button in p.buttons
}

// pressed_buttons returns the button codes held down, in the order they were
// pressed.
pub fn (p &Pointer) pressed_buttons() []u32 {
	return p.buttons.clone()
}

// take_frame reports whether a complete frame of pointer input arrived since the
// last call. Within a frame the events belong together, which is why the
// protocol asks clients to accumulate them before acting.
pub fn (mut p Pointer) take_frame() bool {
	if !p.frame_ready {
		return false
	}
	p.frame_ready = false
	return true
}

// take_motion returns how far the pointer moved since the last call and forgets
// it. It answers none when the pointer did not move.
pub fn (mut p Pointer) take_motion() ?Motion {
	if !p.moved {
		return none
	}
	motion := Motion{
		dx: p.motion_dx
		dy: p.motion_dy
	}
	p.moved = false
	p.motion_dx = 0
	p.motion_dy = 0
	return motion
}

// take_scroll returns the axis input since the last call and forgets it. It
// answers none when nothing was scrolled.
pub fn (mut p Pointer) take_scroll() ?Scroll {
	if !p.scrolled {
		return none
	}
	scroll := Scroll{
		x:       p.scroll_x
		y:       p.scroll_y
		steps_x: p.scroll_steps_x
		steps_y: p.scroll_steps_y
		source:  p.scroll_source
		stopped: p.scroll_stopped
	}
	p.scroll_x = 0
	p.scroll_y = 0
	p.scroll_steps_x = 0
	p.scroll_steps_y = 0
	p.scroll_source = 0
	p.scroll_stopped = false
	p.scrolled = false
	return scroll
}

// set_cursor makes an image the pointer cursor while the pointer is over this
// client's surfaces. `image` is usually small (the themes in /usr/share/icons
// are 24x24), in a 32 bit wl_shm format with alpha, and `hotspot_x`/`hotspot_y`
// are the point in it that sits on the pointer location. The image is attached
// to the pointer's own cursor surface, so it must stay alive (and must not be
// drawn into) for as long as it is the cursor.
//
// The cursor image only changes while the pointer is inside one of the client's
// surfaces, so this is usually called when the pointer enters (the protocol
// leaves the cursor undefined until then) and the serial of that enter event is
// what it is set with.
pub fn (p &Pointer) set_cursor(image &ShmBuffer, hotspot_x int, hotspot_y int) ! {
	if p.serial == 0 {
		return error('the pointer has not entered a surface yet, and set_cursor needs the serial of that event')
	}
	p.cursor_surface.attach(image.object, 0, 0)!
	p.cursor_surface.damage(0, 0, i32(image.width), i32(image.height))!
	p.cursor_surface.commit()!
	p.proxy.set_cursor(p.serial, p.cursor_surface, i32(hotspot_x), i32(hotspot_y))!
}

// hide_cursor hides the pointer image while the pointer is over this client's
// surfaces. The compositor paints its own cursor again once the pointer leaves
// or another client sets one.
pub fn (p &Pointer) hide_cursor() ! {
	if p.serial == 0 {
		return error('the pointer has not entered a surface yet, and set_cursor needs the serial of that event')
	}
	p.proxy.set_cursor(p.serial, none, 0, 0)!
}

// release destroys the pointer object: the client is done with it. No events
// arrive afterwards, and the state is cleared.
pub fn (mut p Pointer) release() ! {
	p.proxy.release()!
	p.inside = false
	p.buttons = []
}

// PointerSink keeps a Pointer up to date. It is installed by `Pointer.new()` and
// is not part of the public API.
struct PointerSink {
mut:
	pointer &Pointer
}

fn (mut sink PointerSink) enter(_proxy wl.WlPointer, serial u32, _surface wl.WlSurface, surface_x f64, surface_y f64) {
	mut p := sink.pointer
	p.inside = true
	p.serial = serial
	p.fx = surface_x
	p.fy = surface_y
	p.x = to_pixels(surface_x)
	p.y = to_pixels(surface_y)
}

fn (mut sink PointerSink) leave(_proxy wl.WlPointer, _serial u32, _surface wl.WlSurface) {
	mut p := sink.pointer
	p.inside = false
	// While a button is held the compositor keeps sending events to the surface
	// the press happened on, so a leave means no button is down any more.
	p.buttons = []
}

fn (mut sink PointerSink) motion(_proxy wl.WlPointer, _time u32, surface_x f64, surface_y f64) {
	mut p := sink.pointer
	p.motion_dx += to_pixels(surface_x - p.fx)
	p.motion_dy += to_pixels(surface_y - p.fy)
	p.moved = true
	p.fx = surface_x
	p.fy = surface_y
	p.x = to_pixels(surface_x)
	p.y = to_pixels(surface_y)
}

fn (mut sink PointerSink) button(_proxy wl.WlPointer, serial u32, _time u32, button u32, state u32) {
	mut p := sink.pointer
	p.serial = serial
	if state == wl.wl_pointer_button_state_pressed {
		if button !in p.buttons {
			p.buttons << button
		}
	} else {
		p.buttons = p.buttons.filter(it != button)
	}
}

fn (mut sink PointerSink) axis(_proxy wl.WlPointer, _time u32, axis u32, value_ f64) {
	mut p := sink.pointer
	match axis {
		wl.wl_pointer_axis_vertical_scroll {
			p.scroll_y += value_
		}
		wl.wl_pointer_axis_horizontal_scroll {
			p.scroll_x += value_
		}
		else {
			// Other axes are left for the versions of the protocol that define
			// them: an unknown axis is not a reason to fail.
		}
	}
	p.scrolled = true
}

fn (mut sink PointerSink) axis_source(_proxy wl.WlPointer, axis_source u32) {
	sink.pointer.scroll_source = axis_source
}

fn (mut sink PointerSink) axis_stop(_proxy wl.WlPointer, _time u32, _axis u32) {
	sink.pointer.scroll_stopped = true
}

fn (mut sink PointerSink) axis_discrete(_proxy wl.WlPointer, axis u32, discrete i32) {
	mut p := sink.pointer
	match axis {
		wl.wl_pointer_axis_vertical_scroll {
			p.scroll_steps_y += discrete
		}
		wl.wl_pointer_axis_horizontal_scroll {
			p.scroll_steps_x += discrete
		}
		else {}
	}
	p.scrolled = true
}

fn (mut sink PointerSink) axis_value120(_proxy wl.WlPointer, axis u32, value120 i32) {
	mut p := sink.pointer
	// 120 is one wheel step, so the high resolution values of a modern wheel
	// count as a step once they add up to one.
	steps := value120 / 120
	match axis {
		wl.wl_pointer_axis_vertical_scroll {
			p.scroll_steps_y += steps
		}
		wl.wl_pointer_axis_horizontal_scroll {
			p.scroll_steps_x += steps
		}
		else {}
	}
	p.scrolled = true
}

fn (mut sink PointerSink) axis_relative_direction(_proxy wl.WlPointer, _axis u32, _direction u32) {
	// Only clients that transform scroll input themselves need this; the values
	// and the steps above already carry the scroll.
}

fn (mut sink PointerSink) warp(_proxy wl.WlPointer, surface_x f64, surface_y f64) {
	mut p := sink.pointer
	// A warp moves the pointer without the user moving it, so there is no motion
	// to report: only the position changes.
	p.inside = true
	p.fx = surface_x
	p.fy = surface_y
	p.x = to_pixels(surface_x)
	p.y = to_pixels(surface_y)
}

fn (mut sink PointerSink) frame(_proxy wl.WlPointer) {
	sink.pointer.frame_ready = true
}

// to_pixels rounds a position to the whole pixel a client draws at.
fn to_pixels(value f64) int {
	rounded := if value < 0 { value - 0.5 } else { value + 0.5 }
	return int(rounded)
}
