module main

import os
import wayland
import wayland.protocols.wayland as wl
import wayland.protocols.wlr_layer_shell_unstable_v1 as layer_shell

// Draws a top panel as a layer surface, the way bars and desktop widgets do on
// compositors that implement the wlroots layer shell protocol.
//
//	v run examples/layer_shell
//	v run examples/layer_shell -- --frames 120   # draw 120 frames, then exit
//
// A layer surface is a wl_surface with the zwlr_layer_surface_v1 role. The first
// commit carries no buffer and asks the compositor for a configure event; only
// after ack_configure, a buffer and another commit does the surface map. The
// anchors and the exclusive zone reserve the top of the output for the panel, so
// maximized windows do not cover it.

const bar_height = 32

const layer_namespace = 'dev.wayland.layer_shell'

const usage = 'usage: v run examples/layer_shell [--frames <count>]'

// State is what the listeners report back to the frame loop.
struct State {
mut:
	configured     bool
	pending_serial u32
	width          u32
	height         u32
	redraw         bool
	frames         int
	closed         bool
}

struct LayerSurfaceListener {
mut:
	state &State
}

fn (mut listener LayerSurfaceListener) configure(_ layer_shell.ZwlrLayerSurfaceV1, serial u32, width u32, height u32) {
	listener.state.pending_serial = serial
	listener.state.width = width
	listener.state.height = height
	listener.state.configured = true
	listener.state.redraw = true
}

fn (mut listener LayerSurfaceListener) closed(_ layer_shell.ZwlrLayerSurfaceV1) {
	listener.state.closed = true
}

struct FrameListener {
mut:
	state &State
}

fn (mut listener FrameListener) done(_ wl.WlCallback, _callback_data u32) {
	listener.state.redraw = true
}

// paint draws the panel: a dark bar with a bright block moving with the frame
// number, so the frame loop is visible. xrgb8888 stores four bytes per pixel,
// blue first.
fn paint(buffer &wayland.ShmBuffer, frame int) {
	mut pixels := buffer.pixels()
	stride := buffer.stride
	for y in 0 .. buffer.height {
		row := y * stride
		level := u8(10 + (y * 18) / buffer.height)
		for x in 0 .. buffer.width {
			offset := row + x * 4
			pixels[offset] = level
			pixels[offset + 1] = u8(int(level) / 2)
			pixels[offset + 2] = u8(int(level) / 4)
			pixels[offset + 3] = u8(0)
		}
	}
	block := buffer.height - 12
	span := buffer.width - block
	if span <= 0 {
		return
	}
	travel := (frame * 4) % (2 * span)
	x := if travel < span { travel } else { 2 * span - travel }
	y := 6
	for dy in 0 .. block {
		row := (y + dy) * stride
		for dx in 0 .. block {
			offset := row + (x + dx) * 4
			pixels[offset] = u8(0x40)
			pixels[offset + 1] = u8(0xc0)
			pixels[offset + 2] = u8(0xff)
			pixels[offset + 3] = u8(0)
		}
	}
}

// frame_limit reads the optional --frames option: the number of frames to draw
// before exiting. Zero means "until the compositor closes the surface".
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
	shell_global := globals.find('zwlr_layer_shell_v1') or {
		eprintln('this compositor does not advertise zwlr_layer_shell_v1 (wlr-layer-shell)')
		return
	}
	compositor := wl.bind_wl_compositor(conn, compositor_global)!
	shm := wl.bind_wl_shm(conn, shm_global)!
	shell := layer_shell.bind_zwlr_layer_shell_v1(conn, shell_global)!

	// The role: a surface, then the layer surface on top of it. A null output
	// lets the compositor pick the output; the namespace names the purpose.
	surface := compositor.create_surface()!
	layer_surface := shell.get_layer_surface(surface, none,
		layer_shell.zwlr_layer_shell_v1_layer_top, layer_namespace)!
	// Width zero plus the left and right anchors: the compositor assigns the
	// width of the output. The height is fixed and the exclusive zone reserves
	// the same 32 pixels, so other windows are placed below the panel.
	layer_surface.set_size(0, bar_height)!
	anchor := layer_shell.zwlr_layer_surface_v1_anchor_top |
		layer_shell.zwlr_layer_surface_v1_anchor_left |
		layer_shell.zwlr_layer_surface_v1_anchor_right
	layer_surface.set_anchor(anchor)!
	layer_surface.set_exclusive_zone(bar_height)!
	layer_surface.set_keyboard_interactivity(layer_shell.zwlr_layer_surface_v1_keyboard_interactivity_none)!

	mut state := State{}
	layer_surface.set_listener(&LayerSurfaceListener{
		state: &state
	})!
	mut frame_listener := FrameListener{
		state: &state
	}

	// The first commit carries no buffer: it asks for the configure event, and
	// the surface is not mapped until that has been acked and a frame committed.
	surface.commit()!
	for !state.configured && !state.closed {
		conn.roundtrip()!
	}
	if state.closed {
		layer_surface.destroy() or {}
		surface.destroy() or {}
		return
	}
	width := if state.width > 0 { int(state.width) } else { 800 }
	height := if state.height > 0 { int(state.height) } else { bar_height }
	mut buffer := wayland.ShmBuffer.new(shm, width, height, wl.wl_shm_format_xrgb8888)!
	println('layer shell: ${buffer.width}x${buffer.height} panel anchored to the top edge')

	for !state.closed {
		if state.pending_serial != 0 {
			layer_surface.ack_configure(state.pending_serial)!
			state.pending_serial = 0
		}
		// A panel anchored to both sides is as wide as the output, so a resize
		// is the normal case when the output changes.
		if state.width > 0 && state.height > 0 && !buffer.busy
			&& (int(state.width) != buffer.width || int(state.height) != buffer.height) {
			buffer.destroy()
			buffer = wayland.ShmBuffer.new(shm, int(state.width), int(state.height), wl.wl_shm_format_xrgb8888)!
			state.redraw = true
		}
		if state.redraw && !buffer.busy {
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
			continue
		}
		conn.dispatch()!
	}
	buffer.destroy()
	layer_surface.destroy() or {}
	surface.destroy() or {}
	println('layer shell: closed after ${state.frames} frames')
}
