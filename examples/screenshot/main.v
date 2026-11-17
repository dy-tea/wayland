module main

import os
import rand
import wayland
import wayland.protocols.ext_image_capture_source_v1 as capture_source
import wayland.protocols.ext_image_copy_capture_v1 as copy_capture
import wayland.protocols.wayland as wl
import wayland.protocols.wlr_screencopy_unstable_v1 as screencopy

// Takes a screenshot of an output and writes it as a PPM image.
//
//	v run examples/screenshot
//	v run examples/screenshot -- --output DP-1 --out /tmp/shot.ppm --cursor
//
// There are two protocols that hand out the pixels of an output. The one to
// prefer is ext-image-copy-capture-v1 (with ext-image-capture-source-v1 for
// the source): the client opens a session for an output, the session
// describes its constraints (buffer size and the formats it accepts), and
// every frame is captured by attaching a buffer and calling capture(). The
// older wlr-screencopy-v1 does the same in one round trip, but it is frozen
// - it cannot describe what it supports, so the client guesses a format -
// and this example only falls back to it when the compositor has nothing
// newer. That is also how grim, the reference screen shotter, picks.
//
// The buffer is allocated by hand instead of through `ShmBuffer` for one
// reason: with screencopy the stride is chosen by the compositor, and it is
// allowed to pad rows. The pool still comes from the same file descriptor
// dance `ShmBuffer` wraps: a memory mapped file is created, its descriptor
// is sent with the create_pool request, and the file is unlinked as soon as
// the compositor holds a copy of it. The bytes the ready event reports are
// the same bytes this process mapped.
//
// The output is the PPM (P6) format: a text header and raw RGB, which every
// image tool reads - `convert shot.ppm shot.png`, GIMP, or `feh`. Writing
// PNG by hand would be a project of its own, so conversion is left to them.

const usage = 'usage: v run examples/screenshot [--output <connector>] [--out <file.ppm>] [--cursor]'

// Capture is the result either capture path reports back: the shape of the
// buffer to allocate, and how it ended. The paths agree on these fields;
// their own bookkeeping lives in their listeners. It is heap allocated,
// because the listeners outlive the frame that hands it over.
@[heap]
struct Capture {
mut:
	// The shape the compositor asked for.
	width  u32
	height u32
	stride u32
	format u32
	// has_format is set once one of the shm formats the session offered
	// was picked, and committed once the constraint batch ended with done.
	has_format bool
	committed  bool
	// ready and has_failed end the capture; exactly one arrives.
	ready         bool
	has_failed    bool
	failed_reason string
	// y_invert says the rows arrive bottom up, from the flags of the older
	// protocol.
	y_invert bool
	// shaped and buffer_done gate the copy of the older protocol: the
	// buffer shape, then the end of the batch that described it.
	shaped      bool
	buffer_done bool
}

// SessionListener follows an ext-image-copy-capture session. The session
// opens with a batch of constraint events: one buffer_size, every shm
// format it could copy into, the dmabuf equivalents, and done.
struct SessionListener {
mut:
	state &Capture
}

fn (mut listener SessionListener) buffer_size(_ copy_capture.ExtImageCopyCaptureSessionV1, width u32, height u32) {
	listener.state.width = width
	listener.state.height = height
}

fn (mut listener SessionListener) shm_format(_ copy_capture.ExtImageCopyCaptureSessionV1, format u32) {
	// The formats arrive in no particular order; keep the first one this
	// program can read. The stride of every format here is width * 4.
	if !listener.state.has_format && supported_shm_format(format) {
		listener.state.format = format
		listener.state.has_format = true
	}
}

fn (mut listener SessionListener) dmabuf_device(_ copy_capture.ExtImageCopyCaptureSessionV1, _device []u8) {
	// GPU buffers would need DRM code; the shm formats are enough.
}

fn (mut listener SessionListener) dmabuf_format(_ copy_capture.ExtImageCopyCaptureSessionV1, _format u32, _modifiers []u8) {
}

fn (mut listener SessionListener) done(_ copy_capture.ExtImageCopyCaptureSessionV1) {
	listener.state.committed = true
}

fn (mut listener SessionListener) stopped(_ copy_capture.ExtImageCopyCaptureSessionV1) {
	// The compositor ended the session - the output went away, typically.
	listener.state.has_failed = true
	listener.state.failed_reason = 'the capture session was stopped by the compositor'
}

// ExtFrameListener follows one capture of the session.
struct ExtFrameListener {
mut:
	state &Capture
}

fn (mut listener ExtFrameListener) transform(_ copy_capture.ExtImageCopyCaptureFrameV1, _transform u32) {
	// The orientation of the pixels: wl_output transform values. The
	// example writes the raw buffer, so the image of a rotated or flipped
	// screen comes out rotated or flipped.
}

fn (mut listener ExtFrameListener) damage(_ copy_capture.ExtImageCopyCaptureFrameV1, _x i32, _y i32, _width i32, _height i32) {
}

fn (mut listener ExtFrameListener) presentation_time(_ copy_capture.ExtImageCopyCaptureFrameV1, _tv_sec_hi u32, _tv_sec_lo u32, _tv_nsec u32) {
}

fn (mut listener ExtFrameListener) ready(_ copy_capture.ExtImageCopyCaptureFrameV1) {
	listener.state.ready = true
}

fn (mut listener ExtFrameListener) failed(_proxy copy_capture.ExtImageCopyCaptureFrameV1, reason u32) {
	listener.state.has_failed = true
	listener.state.failed_reason = match reason {
		copy_capture.ext_image_copy_capture_frame_v1_failure_reason_buffer_constraints {
			'the buffer does not match the session constraints'
		}
		copy_capture.ext_image_copy_capture_frame_v1_failure_reason_stopped {
			'the session was stopped mid-capture'
		}
		else {
			'unknown runtime error'
		}
	}
}

// ScreencopyFrameListener follows the negotiation of one wlr-screencopy
// frame: buffer (the shm shape), buffer_done (end of the batch), and the
// copy outcome.
struct ScreencopyFrameListener {
mut:
	state &Capture
}

fn (mut listener ScreencopyFrameListener) buffer(_ screencopy.ZwlrScreencopyFrameV1, format u32, width u32, height u32, stride u32) {
	listener.state.format = format
	listener.state.width = width
	listener.state.height = height
	listener.state.stride = stride
	listener.state.shaped = true
}

fn (mut listener ScreencopyFrameListener) flags(_ screencopy.ZwlrScreencopyFrameV1, flags u32) {
	// y_invert says the rows arrive bottom up; write_ppm flips them back.
	listener.state.y_invert = flags & screencopy.zwlr_screencopy_frame_v1_flags_y_invert != 0
}

fn (mut listener ScreencopyFrameListener) ready(_ screencopy.ZwlrScreencopyFrameV1, _tv_sec_hi u32, _tv_sec_lo u32, _tv_nsec u32) {
	listener.state.ready = true
}

fn (mut listener ScreencopyFrameListener) failed(_ screencopy.ZwlrScreencopyFrameV1) {
	listener.state.has_failed = true
	listener.state.failed_reason = 'the compositor could not copy the frame'
}

fn (mut listener ScreencopyFrameListener) damage(_ screencopy.ZwlrScreencopyFrameV1, _x u32, _y u32, _width u32, _height u32) {
}

fn (mut listener ScreencopyFrameListener) linux_dmabuf(_ screencopy.ZwlrScreencopyFrameV1, _format u32, _width u32, _height u32) {
	// A dmabuf buffer would need GPU code; this waits for the shm variant
	// of the buffer event, which every compositor sends.
}

fn (mut listener ScreencopyFrameListener) buffer_done(_ screencopy.ZwlrScreencopyFrameV1) {
	listener.state.buffer_done = true
}

// OutputNames collects the connector names of the outputs, keyed by object
// id, so that --output can pick one.
struct OutputNames {
mut:
	names map[u32]string
}

// NameListener fills the map from the wl_output.name events. The event only
// exists from wl_output version 4 on, which is older than every compositor
// in practice.
struct NameListener {
mut:
	state &OutputNames
}

fn (mut listener NameListener) geometry(_ wl.WlOutput, _x i32, _y i32, _physical_width i32, _physical_height i32, _subpixel i32, _make string, _model string, _transform i32) {
}

fn (mut listener NameListener) mode(_ wl.WlOutput, _flags u32, _width i32, _height i32, _refresh i32) {
}

fn (mut listener NameListener) done(_ wl.WlOutput) {
}

fn (mut listener NameListener) scale(_ wl.WlOutput, _factor i32) {
}

fn (mut listener NameListener) name(proxy wl.WlOutput, name string) {
	listener.state.names[proxy.id] = name
}

fn (mut listener NameListener) description(_ wl.WlOutput, _description string) {
}

// ShmPixels is the capture buffer: the wl_buffer to hand to the compositor,
// and the mapping its pixels live in.
struct ShmPixels {
	buffer wl.WlBuffer
mut:
	mapping &os.Mmap
	fd      int
	pool    wl.WlShmPool
}

// allocate_shm creates a wl_buffer of the given shape backed by a fresh
// shared memory file: the file is mapped, its descriptor is sent to the
// compositor as a pool, and the file name is unlinked right away.
fn allocate_shm(shm wl.WlShm, width u32, height u32, stride u32, format u32) !ShmPixels {
	size := u64(stride) * u64(height)
	runtime := os.getenv('XDG_RUNTIME_DIR')
	dir := if runtime != '' { runtime } else { os.temp_dir() }
	path := os.join_path(dir, 'wl-screenshot-${os.getpid()}-${rand.u64():x}')
	mapping := os.mmap_create(path, size)!
	file := os.open_file(path, 'r+') or {
		mapping.close()
		return err
	}
	fd := file.fd
	os.rm(path) or {}
	pool := shm.create_pool(fd, i32(size)) or {
		os.fd_close(fd)
		mapping.close()
		return err
	}
	buffer := pool.create_buffer(0, i32(width), i32(height), i32(stride), format) or {
		pool.destroy() or {}
		os.fd_close(fd)
		mapping.close()
		return err
	}
	return ShmPixels{
		buffer:  buffer
		mapping: mapping
		fd:      fd
		pool:    pool
	}
}

// destroy releases the buffer, the pool, the mapping and the file.
fn (mut capture ShmPixels) destroy() {
	if capture.fd < 0 {
		return
	}
	capture.buffer.destroy() or {}
	capture.pool.destroy() or {}
	capture.mapping.close()
	os.fd_close(capture.fd)
	capture.fd = -1
}

// supported_shm_format reports whether the pixels of a format are four bytes
// each, in an order pixel_rgb() can read. The compositor offers the format
// it renders in, which on most hardware is one of these.
fn supported_shm_format(format u32) bool {
	return format in [
		wl.wl_shm_format_xrgb8888,
		wl.wl_shm_format_argb8888,
		wl.wl_shm_format_xbgr8888,
		wl.wl_shm_format_abgr8888,
	]
}

// pixel_rgb returns the red, green and blue of one pixel. wl_shm formats are
// little endian four character codes: xrgb8888 stores blue first and the
// colour in the low three bytes, xbgr8888 swaps red and blue. The fourth
// byte is padding or alpha, which a screenshot does not keep.
fn pixel_rgb(format u32, bytes []u8, offset int) (u8, u8, u8) {
	match format {
		wl.wl_shm_format_xrgb8888, wl.wl_shm_format_argb8888 {
			return bytes[offset + 2], bytes[offset + 1], bytes[offset]
		}
		wl.wl_shm_format_xbgr8888, wl.wl_shm_format_abgr8888 {
			return bytes[offset], bytes[offset + 1], bytes[offset + 2]
		}
		else {
			return 0, 0, 0
		}
	}
}

// write_ppm writes the pixels as a binary PPM (P6): a text header, then RGB,
// three bytes per pixel, row padding left out.
fn write_ppm(path string, state &Capture, bytes []u8) ! {
	mut data := []u8{}
	data << 'P6\n${state.width} ${state.height}\n255\n'.bytes()
	last_row := int(state.height) - 1
	for row in 0 .. int(state.height) {
		// y_invert (a wlr-screencopy flag) means row 0 of the buffer is the
		// bottom of the picture.
		source := if state.y_invert { last_row - row } else { row }
		base := source * int(state.stride)
		for x in 0 .. int(state.width) {
			r, g, b := pixel_rgb(state.format, bytes, base + x * 4)
			data << r
			data << g
			data << b
		}
	}
	mut file := os.open_file(path, 'w')!
	defer {
		file.close()
	}
	file.write(data)!
}

// Options is the parsed command line.
struct Options {
mut:
	connector string
	out_path  string
	cursor    bool
}

// read_options parses the optional --output, --out and --cursor options.
fn read_options() Options {
	mut options := Options{
		out_path: 'screenshot.ppm'
	}
	args := os.args[1..]
	mut index := 0
	for index < args.len {
		match args[index] {
			'--' {}
			'--output' {
				if index + 1 >= args.len {
					eprintln('--output needs a connector name')
					exit(2)
				}
				options.connector = args[index + 1]
				index++
			}
			'--out' {
				if index + 1 >= args.len {
					eprintln('--out needs a file name')
					exit(2)
				}
				options.out_path = args[index + 1]
				index++
			}
			'--cursor' {
				options.cursor = true
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
	return options
}

// capture_with_ext takes the screenshot through ext-image-copy-capture-v1:
// a session for the output announces what it can copy into, and one frame of
// it fills the buffer this function allocates.
fn capture_with_ext(conn &wayland.Connection, shm wl.WlShm, source_manager_global wayland.Global, capture_manager_global wayland.Global, output wl.WlOutput, cursor bool, mut state Capture) !ShmPixels {
	source_manager := capture_source.bind_ext_output_image_capture_source_manager_v1(conn, source_manager_global)!
	capture_manager := copy_capture.bind_ext_image_copy_capture_manager_v1(conn, capture_manager_global)!

	// The source is the "what to capture" half: an output now, a foreign
	// toplevel in the toplevel flavor of the manager. The session keeps its
	// own reference, so the source object is destroyed here right away.
	source := source_manager.create_source(output)!
	mut options := u32(0)
	if cursor {
		options |= copy_capture.ext_image_copy_capture_manager_v1_options_paint_cursors
	}
	session := capture_manager.create_session(source, options)!
	source.destroy() or {}

	// The constraints arrive as a batch ending in done: the buffer size and
	// the formats the session can copy into.
	session.set_listener(&SessionListener{
		state: &state
	})!
	for !state.committed && !state.has_failed {
		conn.dispatch()!
	}
	if state.has_failed {
		return error(state.failed_reason)
	}
	if !state.has_format {
		return error('the compositor offers no shm format this program can read')
	}

	// One frame of the session: attach the buffer, damage all of it, and
	// ask for the capture. ready or failed ends it.
	stride := state.width * 4
	mut capture := allocate_shm(shm, state.width, state.height, stride, state.format)!
	state.stride = stride
	frame := session.create_frame()!
	frame.set_listener(&ExtFrameListener{
		state: &state
	})!
	frame.attach_buffer(capture.buffer)!
	frame.damage_buffer(0, 0, i32(0x7fffffff), i32(0x7fffffff))!
	frame.capture()!
	for !state.ready && !state.has_failed {
		conn.dispatch()!
	}
	if state.has_failed {
		capture.destroy()
		return error(state.failed_reason)
	}
	return capture
}

// capture_with_screencopy takes the screenshot through the older
// wlr-screencopy-v1, for compositors that do not speak
// ext-image-copy-capture-v1.
fn capture_with_screencopy(conn &wayland.Connection, shm wl.WlShm, manager_global wayland.Global, output wl.WlOutput, cursor bool, mut state Capture) !ShmPixels {
	manager := screencopy.bind_zwlr_screencopy_manager_v1(conn, manager_global)!
	frame := manager.capture_output(if cursor { 1 } else { 0 }, output)!
	frame.set_listener(&ScreencopyFrameListener{
		state: &state
	})!

	// The negotiation runs through the main loop: buffer, then buffer_done,
	// then the buffer can be allocated and copied into. The copy belongs
	// after buffer_done - that event is what tells the client the
	// compositor is done describing the frame and expects the buffer.
	mut capture := ShmPixels{
		buffer:  wl.WlBuffer{}
		pool:    wl.WlShmPool{}
		mapping: unsafe { nil }
		fd:      -1
	}
	mut allocated := false
	for !state.ready && !state.has_failed {
		conn.dispatch()!
		if state.shaped && state.buffer_done && !allocated {
			allocated = true
			capture = allocate_shm(shm, state.width, state.height, state.stride, state.format)!
			frame.copy(capture.buffer)!
		}
	}
	if state.has_failed {
		capture.destroy()
		return error(state.failed_reason)
	}
	return capture
}

fn main() {
	options := read_options()
	mut conn := wayland.connect()!
	defer {
		conn.close()
	}
	globals := conn.globals()!
	shm_global := globals.find('wl_shm') or {
		eprintln('this compositor does not advertise wl_shm')
		return
	}
	output_globals := globals.find_all('wl_output')
	if output_globals.len == 0 {
		eprintln('this compositor does not advertise any output')
		return
	}
	shm := wl.bind_wl_shm(conn, shm_global)!

	// Every output is bound, so that wl_output can report the connector
	// names; the roundtrip delivers them before the capture starts. Without
	// --output the first global is used, which is the main output of most
	// setups.
	mut names := OutputNames{}
	for global in output_globals {
		output := wl.bind_wl_output(conn, global)!
		output.set_listener(&NameListener{
			state: &names
		})!
	}
	conn.roundtrip()!
	mut output := wl.bind_wl_output(conn, output_globals[0])!
	if options.connector != '' {
		mut found := false
		for global in output_globals {
			proxy := wl.bind_wl_output(conn, global)!
			if names.names[proxy.id] == options.connector {
				output = proxy
				found = true
				break
			}
		}
		if !found {
			known := names.names.values().join(', ')
			eprintln('no output named ${options.connector}; the compositor has: ${known}')
			return
		}
	}

	// The preferred protocol first, the frozen one as the fallback - the
	// same order grim picks in.
	mut state := Capture{}
	mut capture := ShmPixels{
		buffer:  wl.WlBuffer{}
		pool:    wl.WlShmPool{}
		mapping: unsafe { nil }
		fd:      -1
	}
	if source_global := globals.find('ext_output_image_capture_source_manager_v1') {
		capture_manager_global := globals.find('ext_image_copy_capture_manager_v1') or {
			eprintln('this compositor advertises an image capture source manager but no ext_image_copy_capture_manager_v1')
			return
		}
		capture = capture_with_ext(conn, shm, source_global, capture_manager_global, output, options.cursor, mut state)!
	} else if screencopy_global := globals.find('zwlr_screencopy_manager_v1') {
		println('screenshot: falling back to wlr-screencopy-v1')
		capture = capture_with_screencopy(conn, shm, screencopy_global, output, options.cursor, mut state)!
	} else {
		eprintln('this compositor supports neither ext-image-copy-capture-v1 nor wlr-screencopy-v1')
		return
	}

	write_ppm(options.out_path, &state, unsafe { capture.mapping.bytes() })!
	capture.destroy()
	println('screenshot: ${state.width}x${state.height} -> ${options.out_path}')
}
