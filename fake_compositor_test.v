module wayland

import os
import wayland.protocols.wayland
import wayland.protocols.xdg_shell

// End to end tests against a compositor implemented in this file.
//
// `socketpair()` gives us two connected unix sockets: the client side is a real
// `Connection`, the other side plays the compositor. Both directions are
// checked at the byte level, which makes these tests cover the wire format, the
// object table, generated listener dispatch and file descriptor passing without
// needing a running compositor.

// socketpair(2) fills an array of C ints, so the declaration must use i32: V's
// int is a machine word, twice as wide on 64 bit systems.
fn C.socketpair(domain int, typ int, protocol int, sv &i32) int

// pwrite lets the fake compositor write through the shared memory descriptors
// the client sends, which is how the tests check that both sides really look at
// the same memory.
fn C.pwrite(fd int, buf voidptr, count u64, offset i64) i64

fn new_pair() !(&Connection, int) {
	mut pair := [2]i32{}
	if C.socketpair(int(C.AF_UNIX), int(C.SOCK_STREAM), 0, &pair[0]) != 0 {
		return error('could not create a socket pair')
	}
	client := connection_from_fd(int(pair[0]))!
	return client, int(pair[1])
}

// V compiles each _test.v file on its own, so the helpers a test file needs are
// defined in it rather than shared with the other test files of the module.
fn event_bytes(object_id u32, opcode int, args []ArgValue) ([]u8, []int) {
	mut encoder := new_encoder(object_id, opcode)
	encoder.args(args)
	return encoder.message(), encoder.fds
}

fn join_bytes(parts [][]u8) []u8 {
	mut joined := []u8{}
	for part in parts {
		joined << part
	}
	return joined
}

fn server_write(fd int, data []u8, fds []int) ! {
	mut sent := 0
	mut first := true
	for sent < data.len {
		pending := if first { fds } else { []int{} }
		written := send_bytes(fd, data[sent..], pending)!
		if written <= 0 {
			return error('fake compositor: write failed')
		}
		sent += written
		first = false
	}
}

fn server_read(fd int, count int) !Received {
	mut data := []u8{}
	mut fds := []int{}
	for data.len < count {
		chunk := receive_bytes(fd, count - data.len, false)!
		if chunk.n == 0 {
			return error('fake compositor: the client closed the connection')
		}
		data << chunk.data
		fds << chunk.fds
	}
	return Received{
		n:    count
		data: data
		fds:  fds
	}
}

fn split_messages(data []u8) [][]u8 {
	mut messages := [][]u8{}
	mut offset := 0
	for offset + wire_header_size <= data.len {
		size := int(get_u32_at(data, offset + 4) >> 16)
		if size < wire_header_size || offset + size > data.len {
			break
		}
		messages << data[offset..offset + size].clone()
		offset += size
	}
	return messages
}

fn test_globals_snapshot() {
	mut client, server_fd := new_pair()!
	defer {
		client.close()
		os.fd_close(server_fd)
	}
	// A fresh connection allocates the registry as id 2 and the roundtrip
	// callback as id 3, so the compositor can answer before the client asks.
	compositor, _ := event_bytes(u32(2), 0, [
		ArgValue(u32(1)),
		ArgValue('wl_compositor'),
		ArgValue(u32(6)),
	])
	shm, _ := event_bytes(u32(2), 0, [ArgValue(u32(2)), ArgValue('wl_shm'), ArgValue(u32(1))])
	done, _ := event_bytes(u32(3), 0, [ArgValue(u32(7))])
	server_write(server_fd, join_bytes([compositor, shm, done]), [])!

	globals := client.globals()!
	assert globals.len == 2
	assert globals[0].name == 1
	assert globals[0].interface == 'wl_compositor'
	assert globals[0].version == 6
	assert globals[1].interface == 'wl_shm'
	assert globals.find('wl_compositor')?.version == 6
	assert globals.find_all('wl_shm').len == 1
	if _ := globals.find('wl_seat') {
		assert false, 'wl_seat was not advertised by the fake compositor'
	}

	// The client must have sent exactly get_registry(2) and sync(3): the registry
	// protocol has no destroy request, so the registry stays for the lifetime of
	// the connection.
	sent := server_read(server_fd, 24)!
	messages := split_messages(sent.data)
	assert messages.len == 2
	assert get_u32_at(messages[0], 0) == 1
	assert int(get_u32_at(messages[0], 4) & 0xffff) == 1
	assert get_u32_at(messages[0], 8) == 2
	assert get_u32_at(messages[1], 0) == 1
	assert int(get_u32_at(messages[1], 4) & 0xffff) == 0
	assert get_u32_at(messages[1], 8) == 3

	// A global that goes away is dropped from the snapshot, a new one is added,
	// and asking again does not need another get_registry: the client keeps one
	// registry and accumulates what it has seen.
	removed, _ := event_bytes(u32(2), 1, [ArgValue(u32(1))])
	added, _ := event_bytes(u32(2), 0, [ArgValue(u32(3)), ArgValue('wl_output'), ArgValue(u32(4))])
	second_done, _ := event_bytes(u32(4), 0, [ArgValue(u32(8))])
	server_write(server_fd, join_bytes([removed, added, second_done]), [])!
	updated := client.globals()!
	assert updated.len == 2
	assert updated[0].name == 2
	assert updated[0].interface == 'wl_shm'
	assert updated[1].name == 3
	assert updated[1].interface == 'wl_output'
	assert updated[1].version == 4
	if _ := updated.find('wl_compositor') {
		assert false, 'wl_compositor was removed by the fake compositor'
	}
	second_sent := server_read(server_fd, 12)!
	assert get_u32_at(second_sent.data, 0) == 1
	assert int(get_u32_at(second_sent.data, 4) & 0xffff) == 0 // only a sync
	assert get_u32_at(second_sent.data, 8) == 4
}

fn test_roundtrip() {
	mut client, server_fd := new_pair()!
	defer {
		client.close()
		os.fd_close(server_fd)
	}
	done, _ := event_bytes(u32(2), 0, [ArgValue(u32(1))])
	server_write(server_fd, done, [])!
	client.roundtrip()!
	sent := server_read(server_fd, 12)!
	assert get_u32_at(sent.data, 0) == 1
	assert int(get_u32_at(sent.data, 4) & 0xffff) == 0
	assert get_u32_at(sent.data, 8) == 2
}

fn test_bind_global() {
	mut client, server_fd := new_pair()!
	defer {
		client.close()
		os.fd_close(server_fd)
	}
	global := Global{
		name:      4
		interface: 'wl_compositor'
		version:   6
	}
	object := client.bind_global(global, 'wl_compositor', 6, &wayland.wl_compositor_desc)!
	assert object.id == 3 // 2 is the connection's registry
	assert object.iface == 'wl_compositor'
	assert object.is_alive()
	// get_registry(2) and bind(name 4, version 6, id 3). The bind message is 40
	// bytes: header, name, interface string, version and the new id.
	sent := server_read(server_fd, 52)!
	messages := split_messages(sent.data)
	assert messages.len == 2
	bind := messages[1]
	string_bytes := pad_to_4('wl_compositor'.len + 1)
	assert get_u32_at(bind, 0) == 2 // the registry
	assert int(get_u32_at(bind, 4) & 0xffff) == 0 // wl_registry.bind
	assert get_u32_at(bind, 8) == 4 // name
	assert get_u32_at(bind, 12) == 14 // interface string length, including NUL
	assert get_u32_at(bind, 12 + 4 + string_bytes) == 6 // version
	assert get_u32_at(bind, 12 + 8 + string_bytes) == 3 // the new object id
}

fn test_bind_global_reuses_one_registry() {
	mut client, server_fd := new_pair()!
	defer {
		client.close()
		os.fd_close(server_fd)
	}
	compositor := Global{
		name:      1
		interface: 'wl_compositor'
		version:   6
	}
	shm := Global{
		name:      2
		interface: 'wl_shm'
		version:   1
	}
	first := client.bind_global(compositor, 'wl_compositor', 6, &wayland.wl_compositor_desc)!
	second := client.bind_global(shm, 'wl_shm', 1, &wayland.wl_shm_desc)!
	assert first.id == 3
	assert second.id == 4
	// Only one get_registry is sent for both binds: 12 bytes of get_registry, then
	// a 40 byte bind for wl_compositor and a 32 byte bind for wl_shm.
	sent := server_read(server_fd, 12 + 40 + 32)!
	messages := split_messages(sent.data)
	assert messages.len == 3
	assert get_u32_at(messages[0], 0) == 1
	assert int(get_u32_at(messages[0], 4) & 0xffff) == 1 // wl_display.get_registry
	assert int(get_u32_at(messages[1], 4) & 0xffff) == 0 // wl_registry.bind
	assert int(get_u32_at(messages[2], 4) & 0xffff) == 0 // wl_registry.bind
	assert get_u32_at(messages[1], 8) == 1 // first global name
	assert get_u32_at(messages[2], 8) == 2 // second global name
	assert get_u32_at(messages[2], 0) == 2 // both binds use registry 2
}

struct KeymapListener {
mut:
	got    bool
	format u32
	fd     int
	size   u32
}

fn (mut listener KeymapListener) keymap(_ wayland.WlKeyboard, format u32, fd int, size u32) {
	listener.got = true
	listener.format = format
	listener.fd = fd
	listener.size = size
}

fn (mut listener KeymapListener) enter(_ wayland.WlKeyboard, _ u32, _ wayland.WlSurface, _ []u8) {
}

fn (mut listener KeymapListener) leave(_ wayland.WlKeyboard, _ u32, _ wayland.WlSurface) {
}

fn (mut listener KeymapListener) key(_ wayland.WlKeyboard, _ u32, _ u32, _ u32, _ u32) {
}

fn (mut listener KeymapListener) modifiers(_ wayland.WlKeyboard, _ u32, _ u32, _ u32, _ u32, _ u32) {
}

fn (mut listener KeymapListener) repeat_info(_ wayland.WlKeyboard, _ i32, _ i32) {
}

fn test_event_with_file_descriptor() {
	mut client, server_fd := new_pair()!
	defer {
		client.close()
		os.fd_close(server_fd)
	}
	// Register a wl_keyboard object the way a generated bind helper would.
	keyboard_id := client.alloc_id()!
	client.register_object(keyboard_id, 'wl_keyboard', &wayland.wl_keyboard_desc)!
	mut keyboard := wayland.wl_keyboard_proxy(client, keyboard_id)
	mut listener := KeymapListener{}
	keyboard.set_listener(&listener)!

	// The compositor sends a keymap event carrying a file descriptor. Sending the
	// other end of the socket pair doubles as a check that the descriptor the
	// client received is a working duplicate.
	event, fds := event_bytes(keyboard_id, 0, [
		ArgValue(u32(1)),
		ArgValue(Fd{
			fd: server_fd
		}),
		ArgValue(u32(4096)),
	])
	server_write(server_fd, event, fds)!

	assert client.dispatch_pending()! == 1
	assert listener.got
	assert listener.format == 1
	assert listener.size == 4096
	assert listener.fd > 0
	assert send_bytes(listener.fd, 'ping'.bytes(), [])! > 0
	echoed := receive_bytes(client.fd, 16, false)!
	assert echoed.data.bytestr() == 'ping'
	os.fd_close(listener.fd)
}

fn test_request_with_file_descriptor() {
	mut client, server_fd := new_pair()!
	defer {
		client.close()
		os.fd_close(server_fd)
	}
	shm_id := client.alloc_id()!
	client.register_object(shm_id, 'wl_shm', &wayland.wl_shm_desc)!
	mut shm := wayland.wl_shm_proxy(client, shm_id)
	// Passing the client's own socket as the pool descriptor keeps the test
	// self contained: the compositor side can write to it and be heard.
	pool := shm.create_pool(client.fd, 4096)!
	client.flush()!
	assert pool.id == 3
	assert pool.iface == 'wl_shm_pool'

	sent := server_read(server_fd, 16)!
	assert sent.fds.len == 1
	assert get_u32_at(sent.data, 0) == 2
	assert int(get_u32_at(sent.data, 4) & 0xffff) == 0 // wl_shm.create_pool
	assert get_u32_at(sent.data, 8) == 3 // the new pool id
	assert get_u32_at(sent.data, 12) == 4096
	assert send_bytes(sent.fds[0], 'data'.bytes(), [])! > 0
	echoed := receive_bytes(server_fd, 16, false)!
	assert echoed.data.bytestr() == 'data'
	os.fd_close(sent.fds[0])
}

fn test_typed_request_and_listener_roundtrip() {
	mut client, server_fd := new_pair()!
	defer {
		client.close()
		os.fd_close(server_fd)
	}
	compositor_id := client.alloc_id()!
	client.register_object(compositor_id, 'wl_compositor', &wayland.wl_compositor_desc)!
	mut compositor := wayland.wl_compositor_proxy(client, compositor_id)
	surface := compositor.create_surface()!
	client.flush()!
	assert surface.id == 3
	assert surface.iface == 'wl_surface'

	sent := server_read(server_fd, 12)!
	assert get_u32_at(sent.data, 0) == 2
	assert int(get_u32_at(sent.data, 4) & 0xffff) == 0 // wl_compositor.create_surface
	assert get_u32_at(sent.data, 8) == 3

	// Now the compositor drives the surface: a configure-less event is not part
	// of wl_surface, so use enter, which takes an output object.
	output_id := client.alloc_id()!
	client.register_object(output_id, 'wl_output', &wayland.wl_output_desc)!
	enter, _ := event_bytes(3, 0, [ArgValue(ObjectRef{
		id: output_id
	})])
	server_write(server_fd, enter, [])!
	assert client.dispatch_pending()! == 1

	// Destroying the surface must be queued as a destructor request.
	surface.destroy()!
	client.flush()!
	destroy := server_read(server_fd, 8)!
	assert get_u32_at(destroy.data, 0) == 3
	assert int(get_u32_at(destroy.data, 4) & 0xffff) == 0
	assert !surface.is_alive()
	if _ := surface.attach(none, 0, 0) {
		assert false, 'requests on destroyed objects must fail'
	}
}

fn test_dispatch_blocks_until_an_event_arrives() {
	mut client, server_fd := new_pair()!
	defer {
		client.close()
		os.fd_close(server_fd)
	}
	keyboard_id := client.alloc_id()!
	client.register_object(keyboard_id, 'wl_keyboard', &wayland.wl_keyboard_desc)!
	mut keyboard := wayland.wl_keyboard_proxy(client, keyboard_id)
	mut listener := KeymapListener{}
	keyboard.set_listener(&listener)!
	// A single message split over two writes must still be reassembled.
	event, _ := event_bytes(keyboard_id, 0, [ArgValue(u32(0)), ArgValue(Fd{
		fd: server_fd
	}), ArgValue(u32(64))])
	server_write(server_fd, event[..10], [])!
	server_write(server_fd, event[10..], [server_fd])!
	client.dispatch()!
	assert listener.got
	assert listener.fd > 0
	os.fd_close(listener.fd)
}

// server_read_available blocks until the client writes something, then drains
// everything it has already sent, descriptors included. The flow test below
// knows how many messages each step produces, but not how the socket splits
// them, so it collects and then splits them itself.
fn server_read_available(fd int) !Received {
	first := receive_bytes(fd, 65536, false)!
	mut data := first.data
	mut fds := first.fds.clone()
	for {
		more := receive_bytes(fd, 65536, true)!
		if more.n == 0 {
			break
		}
		data << more.data
		fds << more.fds
	}
	return Received{
		n:    data.len
		data: data
		fds:  fds
	}
}

// --- the window flow ---------------------------------------------------------
//
// The tests below follow `examples/window` step by step: an xdg_toplevel is
// created, configured, acked and presented from a shared memory buffer, the
// compositor releases the buffer, and finally it asks for the window to close.

// FlowState is what the listeners report back to the loop that drives the flow,
// the same way the window example does.
struct FlowState {
mut:
	configured bool
	serial     u32
	frames     int
	closed     bool
}

struct FlowSurfaceListener {
mut:
	state &FlowState
}

fn (mut listener FlowSurfaceListener) configure(_ xdg_shell.XdgSurface, serial u32) {
	listener.state.serial = serial
	listener.state.configured = true
}

struct FlowToplevelListener {
mut:
	state &FlowState
}

fn (mut listener FlowToplevelListener) configure(_ xdg_shell.XdgToplevel, width i32, height i32, states []u8) {
	// The fake compositor leaves the size to the client and sends no states.
	assert width == 0
	assert height == 0
	assert states.len == 0
}

fn (mut listener FlowToplevelListener) close(_ xdg_shell.XdgToplevel) {
	listener.state.closed = true
}

fn (mut listener FlowToplevelListener) configure_bounds(_ xdg_shell.XdgToplevel, _width i32, _height i32) {
}

fn (mut listener FlowToplevelListener) wm_capabilities(_ xdg_shell.XdgToplevel, _capabilities []u8) {
}

struct FlowCallbackListener {
mut:
	state &FlowState
}

fn (mut listener FlowCallbackListener) done(_ wayland.WlCallback, _callback_data u32) {
	listener.state.frames++
}

fn test_shm_buffer_rejects_bad_arguments() {
	mut client, server_fd := new_pair()!
	defer {
		client.close()
		os.fd_close(server_fd)
	}
	shm_id := client.alloc_id()!
	client.register_object(shm_id, 'wl_shm', &wayland.wl_shm_desc)!
	shm := wayland.wl_shm_proxy(client, shm_id)
	if _ := ShmBuffer.new(shm, 0, 64, wayland.wl_shm_format_xrgb8888) {
		assert false, 'a buffer with a zero width must be rejected'
	} else {
		assert err.msg().contains('positive size')
	}
	if _ := ShmBuffer.new(shm, 64, 64, wayland.wl_shm_format_yuyv) {
		assert false, 'a format that is not 32 bits per pixel must be rejected'
	} else {
		assert err.msg().contains('32 bit')
	}
}

fn test_xdg_toplevel_window_flow() {
	mut client, server_fd := new_pair()!
	defer {
		client.close()
		os.fd_close(server_fd)
	}
	// A compositor with the three globals a window needs.
	compositor_global, _ := event_bytes(u32(2), 0, [
		ArgValue(u32(1)),
		ArgValue('wl_compositor'),
		ArgValue(u32(6)),
	])
	shm_global, _ := event_bytes(u32(2), 0, [ArgValue(u32(2)), ArgValue('wl_shm'), ArgValue(u32(3))])
	wm_base_global, _ := event_bytes(u32(2), 0, [
		ArgValue(u32(3)),
		ArgValue('xdg_wm_base'),
		ArgValue(u32(6)),
	])
	done, _ := event_bytes(u32(3), 0, [ArgValue(u32(1))])
	server_write(server_fd, join_bytes([compositor_global, shm_global, wm_base_global, done]), [])!

	// --- the client learns the globals and binds them ---
	globals := client.globals()!
	assert globals.len == 3
	startup := split_messages(server_read(server_fd, 24)!.data)
	assert startup.len == 2 // wl_display.get_registry and wl_display.sync
	compositor := wayland.bind_wl_compositor(client, globals.find('wl_compositor')!)!
	shm := wayland.bind_wl_shm(client, globals.find('wl_shm')!)!
	wm_base := xdg_shell.bind_xdg_wm_base(client, globals.find('xdg_wm_base')!)!
	binds := split_messages(server_read(server_fd, 108)!.data)
	assert binds.len == 3
	assert get_u32_at(binds[0], 0) == 2 // one registry carries all the binds
	assert get_u32_at(binds[0], 8) == 1 // the name of the wl_compositor global
	assert get_u32_at(binds[2], 8) == 3 // the name of the xdg_wm_base global

	// --- the client creates the toplevel and asks for a configure ---
	surface := compositor.create_surface()!
	xdg_surface := wm_base.get_xdg_surface(surface)!
	toplevel := xdg_surface.get_toplevel()!
	toplevel.set_title('test window')!
	toplevel.set_app_id('dev.wayland.test')!
	mut state := FlowState{}
	mut surface_listener := FlowSurfaceListener{
		state: &state
	}
	xdg_surface.set_listener(&surface_listener)!
	mut toplevel_listener := FlowToplevelListener{
		state: &state
	}
	toplevel.set_listener(&toplevel_listener)!
	surface.commit()!
	client.flush()!
	setup := split_messages(server_read_available(server_fd)!.data)
	assert setup.len == 6
	assert get_u32_at(setup[0], 0) == compositor.id
	assert int(get_u32_at(setup[0], 4) & 0xffff) == 0 // wl_compositor.create_surface
	assert get_u32_at(setup[1], 0) == wm_base.id
	assert int(get_u32_at(setup[1], 4) & 0xffff) == 2 // xdg_wm_base.get_xdg_surface
	assert get_u32_at(setup[1], 12) == surface.id
	assert get_u32_at(setup[2], 0) == xdg_surface.id
	assert int(get_u32_at(setup[2], 4) & 0xffff) == 1 // xdg_surface.get_toplevel
	assert get_u32_at(setup[5], 0) == surface.id
	assert int(get_u32_at(setup[5], 4) & 0xffff) == 6 // wl_surface.commit
	assert setup[5].len == 8 // the first commit carries no buffer

	// --- the compositor configures the window ---
	toplevel_configure, _ := event_bytes(toplevel.id, 0, [ArgValue(i32(0)), ArgValue(i32(0)),
		ArgValue([]u8{})])
	surface_configure, _ := event_bytes(xdg_surface.id, 0, [ArgValue(u32(7))])
	server_write(server_fd, join_bytes([toplevel_configure, surface_configure]), [])!
	assert client.dispatch_pending()! == 2
	assert state.configured
	assert state.serial == 7

	// --- the client acks the configure and presents a frame ---
	xdg_surface.ack_configure(state.serial)!
	buffer := ShmBuffer.new(shm, 64, 32, wayland.wl_shm_format_xrgb8888)!
	mut pixels := buffer.pixels()
	for i in 0 .. pixels.len {
		pixels[i] = u8(i & 0x7f)
	}
	assert !buffer.busy
	buffer.attach(surface)!
	assert buffer.busy
	mut callback_listener := FlowCallbackListener{
		state: &state
	}
	callback := surface.frame()!
	callback.set_listener(&callback_listener)!
	surface.commit()!
	client.flush()!
	present := server_read_available(server_fd)!
	assert present.fds.len == 1

	// The ack, the pool and buffer creation, the attach, the damage, the frame
	// callback and the commit arrive together.
	acked := split_messages(present.data)
	assert acked.len == 7
	assert get_u32_at(acked[0], 0) == xdg_surface.id
	assert int(get_u32_at(acked[0], 4) & 0xffff) == 4 // xdg_surface.ack_configure
	assert get_u32_at(acked[0], 8) == 7
	// wl_shm.create_pool: the new pool id and the size it covers; the descriptor
	// travels out of band and is checked below.
	assert get_u32_at(acked[1], 0) == shm.id
	assert int(get_u32_at(acked[1], 4) & 0xffff) == 0 // wl_shm.create_pool
	assert acked[1].len == 16
	assert get_u32_at(acked[1], 12) == u32(64 * 4 * 32)
	// wl_shm_pool.create_buffer: offset, width, height, stride and format.
	assert int(get_u32_at(acked[2], 4) & 0xffff) == 0 // wl_shm_pool.create_buffer
	assert acked[2].len == 32
	assert get_u32_at(acked[2], 12) == 0 // offset
	assert get_u32_at(acked[2], 16) == 64 // width
	assert get_u32_at(acked[2], 20) == 32 // height
	assert get_u32_at(acked[2], 24) == 256 // stride
	assert get_u32_at(acked[2], 28) == wayland.wl_shm_format_xrgb8888
	// wl_surface.attach, damage, frame and commit.
	assert get_u32_at(acked[3], 0) == surface.id
	assert int(get_u32_at(acked[3], 4) & 0xffff) == 1 // wl_surface.attach
	assert get_u32_at(acked[3], 8) == buffer.object.id
	assert int(get_u32_at(acked[4], 4) & 0xffff) == 2 // wl_surface.damage
	assert get_u32_at(acked[4], 16) == 64 // width
	assert get_u32_at(acked[4], 20) == 32 // height
	assert int(get_u32_at(acked[5], 4) & 0xffff) == 3 // wl_surface.frame
	assert get_u32_at(acked[5], 8) == callback.id
	assert int(get_u32_at(acked[6], 4) & 0xffff) == 6 // wl_surface.commit

	// The descriptor the compositor received is the memory the client maps:
	// writing through it changes the client's pixels.
	probe := [u8(9), u8(8), u8(7), u8(6)]
	C.pwrite(present.fds[0], probe.data, u64(4), i64(0))
	assert buffer.pixels()[0] == u8(9)
	assert buffer.pixels()[1] == u8(8)
	assert buffer.pixels()[2] == u8(7)
	assert buffer.pixels()[3] == u8(6)
	assert buffer.pixels()[4] == u8(4) // the rest of the mapping is untouched
	os.fd_close(present.fds[0])

	// --- the compositor releases the buffer and asks for the next frame ---
	release, _ := event_bytes(buffer.object.id, 0, [])
	callback_done, _ := event_bytes(callback.id, 0, [ArgValue(u32(0))])
	server_write(server_fd, join_bytes([release, callback_done]), [])!
	assert client.dispatch_pending()! == 2
	assert !buffer.busy
	assert state.frames == 1

	// --- the compositor closes the window ---
	close_event, _ := event_bytes(toplevel.id, 1, [])
	server_write(server_fd, close_event, [])!
	assert client.dispatch_pending()! == 1
	assert state.closed

	// Destroying the buffer gives the pool and the shared memory back.
	buffer.destroy()
	client.flush()!
	destroyed := split_messages(server_read_available(server_fd)!.data)
	assert destroyed.len == 2
	assert get_u32_at(destroyed[0], 0) == buffer.object.id
	assert int(get_u32_at(destroyed[0], 4) & 0xffff) == 0 // wl_buffer.destroy
	assert int(get_u32_at(destroyed[1], 4) & 0xffff) == 1 // wl_shm_pool.destroy
}

// --- keyboard input ----------------------------------------------------------
//
// The input test follows the seat part of `examples/window`: the seat reports
// its capabilities, the keyboard is created from them, the keymap arrives as a
// file descriptor and Escape closes the window.

// InputState is what the input listeners report to the test.
struct InputState {
mut:
	keyboard_created bool
	keyboard_id      u32
	keymap           string
	keymap_fd        int = -1
	focused          bool
	closed           bool
	last_key         string
}

struct InputSeatListener {
mut:
	state &InputState
}

fn (mut listener InputSeatListener) capabilities(seat wayland.WlSeat, capabilities u32) {
	if listener.state.keyboard_created || capabilities & wayland.wl_seat_capability_keyboard == 0 {
		return
	}
	keyboard := seat.get_keyboard() or { return }
	listener.state.keyboard_id = keyboard.id
	listener.state.keyboard_created = true
	keyboard.set_listener(&InputKeyboardListener{
		state: listener.state
	})!
}

fn (mut listener InputSeatListener) name(_ wayland.WlSeat, _name string) {
}

struct InputKeyboardListener {
mut:
	state &InputState
}

fn (mut listener InputKeyboardListener) keymap(_ wayland.WlKeyboard, format u32, fd int, size u32) {
	listener.state.keymap_fd = fd
	listener.state.keymap = read_keymap(format, fd, size) or { '' }
}

fn (mut listener InputKeyboardListener) enter(_ wayland.WlKeyboard, _serial u32, _surface wayland.WlSurface, _keys []u8) {
	listener.state.focused = true
}

fn (mut listener InputKeyboardListener) leave(_ wayland.WlKeyboard, _serial u32, _surface wayland.WlSurface) {
	listener.state.focused = false
}

fn (mut listener InputKeyboardListener) key(_ wayland.WlKeyboard, _serial u32, _time u32, key u32, state u32) {
	if state != wayland.wl_keyboard_key_state_pressed {
		return
	}
	listener.state.last_key = key_name(key) or { '' }
	if key == key_escape {
		listener.state.closed = true
	}
}

fn (mut listener InputKeyboardListener) modifiers(_ wayland.WlKeyboard, _serial u32, _mods_depressed u32, _mods_latched u32, _mods_locked u32, _group u32) {
}

fn (mut listener InputKeyboardListener) repeat_info(_ wayland.WlKeyboard, _rate i32, _delay i32) {
}

fn test_read_keymap_validation() {
	// An event without a descriptor has no keymap to read.
	if _ := read_keymap(wayland.wl_keyboard_keymap_format_xkb_v1, -1, 64) {
		assert false, 'a missing keymap descriptor must be rejected'
	} else {
		assert err.msg().contains('no descriptor')
	}
	// A compositor with no keymap sends the no-keymap format: the descriptor is
	// closed and the answer is empty, not an error.
	empty := os.open_file('/dev/null', 'r')!
	assert read_keymap(wayland.wl_keyboard_keymap_format_no_keymap, empty.fd, 0) or {
		assert false, 'the no-keymap format must not fail'
		''
	} == ''
	_, closed := os.fd_read(empty.fd, 1)
	assert closed < 0 // read_keymap owns and closes the descriptor

	// A format that is neither no-keymap nor xkb is not readable.
	unknown := os.open_file('/dev/null', 'r')!
	if _ := read_keymap(99, unknown.fd, 8) {
		assert false, 'an unknown keymap format must be rejected'
	} else {
		assert err.msg().contains('unsupported keyboard keymap format 99')
	}
	_, closed_unknown := os.fd_read(unknown.fd, 1)
	assert closed_unknown < 0

	// The size is the compositor's number, and it is not allowed to become a
	// large allocation.
	absurd := os.open_file('/dev/null', 'r')!
	if _ := read_keymap(wayland.wl_keyboard_keymap_format_xkb_v1, absurd.fd, 64 * 1024 * 1024) {
		assert false, 'an absurd keymap size must be rejected'
	} else {
		assert err.msg().contains('more than')
	}
	_, closed_absurd := os.fd_read(absurd.fd, 1)
	assert closed_absurd < 0

	// A keymap descriptor shares its file offset with the compositor and with
	// every other client that received the same keymap, so it can arrive with
	// the offset already at the end of the file: the text must still come back
	// whole, as it does for the mapping libwayland clients take.
	path := os.join_path(os.temp_dir(), 'wayland-keymap-offset-${os.getpid()}')
	text := 'xkb_keymap { xkb_keycodes "test" { }; };'
	os.write_file(path, text + '\x00')!
	file := os.open_file(path, 'r')!
	os.rm(path) or {}
	_, consumed := os.fd_read(file.fd, text.len + 1)
	assert consumed == text.len + 1
	assert read_keymap(wayland.wl_keyboard_keymap_format_xkb_v1, file.fd, u32(text.len + 1))! == text
	file.close()
}

fn test_keyboard_input_flow() {
	mut client, server_fd := new_pair()!
	defer {
		client.close()
		os.fd_close(server_fd)
	}
	// A compositor with a seat and a compositor global.
	seat_global, _ := event_bytes(u32(2), 0, [ArgValue(u32(1)), ArgValue('wl_seat'), ArgValue(u32(9))])
	compositor_global, _ := event_bytes(u32(2), 0, [
		ArgValue(u32(2)),
		ArgValue('wl_compositor'),
		ArgValue(u32(6)),
	])
	done, _ := event_bytes(u32(3), 0, [ArgValue(u32(1))])
	server_write(server_fd, join_bytes([seat_global, compositor_global, done]), [])!

	globals := client.globals()!
	seat := wayland.bind_wl_seat(client, globals.find('wl_seat')!)!
	compositor := wayland.bind_wl_compositor(client, globals.find('wl_compositor')!)!
	mut state := InputState{}
	mut seat_listener := InputSeatListener{
		state: &state
	}
	seat.set_listener(&seat_listener)!
	surface := compositor.create_surface()!
	client.flush()!
	server_read_available(server_fd)!
	assert !state.keyboard_created

	// The seat reports its capabilities, and the client answers with
	// wl_seat.get_keyboard.
	capabilities, _ := event_bytes(seat.id, 0, [
		ArgValue(wayland.wl_seat_capability_pointer | wayland.wl_seat_capability_keyboard),
	])
	server_write(server_fd, capabilities, [])!
	assert client.dispatch_pending()! == 1
	assert state.keyboard_created
	// The request was queued while dispatching, after dispatch flushed.
	client.flush()!
	get_keyboard := server_read_available(server_fd)!
	assert get_keyboard.data.len == 12
	assert get_u32_at(get_keyboard.data, 0) == seat.id
	assert int(get_u32_at(get_keyboard.data, 4) & 0xffff) == 1 // wl_seat.get_keyboard
	assert get_u32_at(get_keyboard.data, 8) == state.keyboard_id

	// The keymap travels as a file descriptor and a size, and the descriptor
	// belongs to the client.
	path := os.join_path(os.temp_dir(), 'wayland-keymap-${os.getpid()}')
	keymap_text := 'xkb_keymap {\n  xkb_keycodes "test" { <ESC> = 9; };\n}\n'
	os.write_file(path, keymap_text + '\x00')!
	keymap_file := os.open_file(path, 'r')!
	os.rm(path) or {}
	// The compositor wrote the file through the descriptor it sends, so the
	// offset it shares with the client is already at the end when the event
	// arrives; the reader has to rewind before it can see anything.
	_, written := os.fd_read(keymap_file.fd, keymap_text.len + 1)
	assert written == keymap_text.len + 1
	keymap_event, fds := event_bytes(state.keyboard_id, 0, [
		ArgValue(wayland.wl_keyboard_keymap_format_xkb_v1),
		ArgValue(Fd{
			fd: keymap_file.fd
		}),
		ArgValue(u32(keymap_text.len + 1)),
	])
	server_write(server_fd, keymap_event, fds)!
	assert client.dispatch_pending()! == 1
	assert state.keymap == keymap_text // the helper drops the terminating NUL
	// read_keymap closes the descriptor it was given.
	closed_read, n := os.fd_read(state.keymap_fd, 4)
	assert n < 0
	assert closed_read == ''
	keymap_file.close()

	// Focus, a key that is not Escape, and the Escape release: none of them
	// closes the window.
	enter, _ := event_bytes(state.keyboard_id, 1, [
		ArgValue(u32(5)),
		ArgValue(ObjectRef{
			id: surface.id
		}),
		ArgValue([]u8{}),
	])
	space, _ := event_bytes(state.keyboard_id, 3, [
		ArgValue(u32(6)),
		ArgValue(u32(0)),
		ArgValue(key_space),
		ArgValue(wayland.wl_keyboard_key_state_pressed),
	])
	escape_up, _ := event_bytes(state.keyboard_id, 3, [
		ArgValue(u32(7)),
		ArgValue(u32(0)),
		ArgValue(key_escape),
		ArgValue(wayland.wl_keyboard_key_state_released),
	])
	server_write(server_fd, join_bytes([enter, space, escape_up]), [])!
	assert client.dispatch_pending()! == 3
	assert state.focused
	assert state.last_key == 'Space'
	assert !state.closed

	// The Escape press closes the window, and losing focus is reported too.
	escape_down, _ := event_bytes(state.keyboard_id, 3, [
		ArgValue(u32(8)),
		ArgValue(u32(0)),
		ArgValue(key_escape),
		ArgValue(wayland.wl_keyboard_key_state_pressed),
	])
	leave, _ := event_bytes(state.keyboard_id, 2, [
		ArgValue(u32(9)),
		ArgValue(ObjectRef{
			id: surface.id
		}),
	])
	server_write(server_fd, join_bytes([escape_down, leave]), [])!
	assert client.dispatch_pending()! == 2
	assert state.closed
	assert !state.focused

	// Only the documented key codes have names.
	assert key_name(key_enter)? == 'Enter'
	assert key_name(key_escape)? == 'Escape'
	if _ := key_name(4321) {
		assert false, 'an undocumented key code has no name'
	}
}
