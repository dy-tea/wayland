module wayland

import os
import wayland.protocols.wayland

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
