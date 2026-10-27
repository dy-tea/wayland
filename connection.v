module wayland

import os

// The connection owns the compositor socket, the object id table and the
// pending read/write buffers. It is the only stateful part of the library;
// generated protocol proxies hold a reference to it and are cheap value types.

// EventSink receives the decoded events of one object. Generated protocol
// modules provide an implementation per interface; it is what makes `match`-free
// typed listener dispatch possible without any unsafe code.
pub interface EventSink {
mut:
	on_event(msg &Message) !bool
}

// NoopSink is the default sink of a fresh object: it drops every event.
struct NoopSink {}

fn (mut s NoopSink) on_event(_ &Message) !bool {
	return false
}

// object_entry is one slot of the id table.
struct ObjectEntry {
mut:
	iface     string
	desc      &IfaceDesc = unsafe { nil }
	sink      EventSink  = NoopSink{}
	in_use    bool
	destroyed bool
}

// Connection is a connection to a Wayland compositor.
//
// Connection is a connection to a Wayland compositor.
//
// It is created with `connect()` and drives the protocol with `dispatch()`,
// `dispatch_pending()`, `roundtrip()` and `flush()`. Request methods generated
// from protocol XML files (for example `WlSurface.attach`) marshal and queue
// their message on this connection.
//
// Connections are always heap allocated: generated protocol proxies keep a
// reference to them, so their address must stay valid while any proxy is used.
@[heap]
pub struct Connection {
pub:
	// display_id is the id of the wl_display object, always 1.
	display_id u32 = 1
pub mut:
	// fd is the compositor socket. Do not close it directly, use `close()`.
	fd int = -1
	// debug prints unhandled events and protocol oddities to stderr.
	debug bool
mut:
	objects       []ObjectEntry
	free_ids      []u32
	next_id       u32 = 2
	registry_id   u32
	globals_cache []Global
	out_buf       []u8
	out_fds       []int
	recv_buf      []u8
	recv_pos      int
	in_fds        []int
	closed        bool
}

// --- core protocol descriptions ---------------------------------------------
//
// wl_display, wl_registry and wl_callback are needed by the library itself (for
// roundtrips and global discovery), so they are described here rather than in
// generated code. The generated `wayland` module describes them again with full
// type information for applications that want typed listeners.

const wl_display_iface = IfaceDesc{
	name:     'wl_display'
	version:  1
	requests: [
		MsgDesc{
			name:   'sync'
			opcode: 0
			args:   [
				ArgDesc{
					name:  'callback'
					kind:  .new_id
					iface: 'wl_callback'
				},
			]
		},
		MsgDesc{
			name:   'get_registry'
			opcode: 1
			args:   [
				ArgDesc{
					name:  'registry'
					kind:  .new_id
					iface: 'wl_registry'
				},
			]
		},
	]
	events:   [
		MsgDesc{
			name:   'error'
			opcode: 0
			args:   [
				ArgDesc{
					name: 'object_id'
					kind: .obj
				},
				ArgDesc{
					name: 'code'
					kind: .uint
				},
				ArgDesc{
					name: 'message'
					kind: .str
				},
			]
		},
		MsgDesc{
			name:   'delete_id'
			opcode: 1
			args:   [
				ArgDesc{
					name: 'id'
					kind: .uint
				},
			]
		},
	]
}

const wl_callback_iface = IfaceDesc{
	name:    'wl_callback'
	version: 1
	events:  [
		MsgDesc{
			name:   'done'
			opcode: 0
			args:   [
				ArgDesc{
					name: 'callback_data'
					kind: .uint
				},
			]
		},
	]
}

const wl_registry_iface = IfaceDesc{
	name:     'wl_registry'
	version:  1
	requests: [
		MsgDesc{
			name:   'bind'
			opcode: 0
			args:   [
				ArgDesc{
					name: 'name'
					kind: .uint
				},
				ArgDesc{
					name: 'interface'
					kind: .str
				},
				ArgDesc{
					name: 'version'
					kind: .uint
				},
				ArgDesc{
					name: 'id'
					kind: .new_id
				},
			]
		},
	]
	events:   [
		MsgDesc{
			name:   'global'
			opcode: 0
			args:   [
				ArgDesc{
					name: 'name'
					kind: .uint
				},
				ArgDesc{
					name: 'interface'
					kind: .str
				},
				ArgDesc{
					name: 'version'
					kind: .uint
				},
			]
		},
		MsgDesc{
			name:   'global_remove'
			opcode: 1
			args:   [
				ArgDesc{
					name: 'name'
					kind: .uint
				},
			]
		},
	]
}

// opaque_iface marks objects the library has no generated description for. Their
// events are ignored.
pub const opaque_iface = IfaceDesc{
	name:    ''
	version: 1
}

// --- construction -----------------------------------------------------------

fn new_connection(fd int) &Connection {
	// Slot `id - 1` holds object `id`: slot 0 is wl_display (id 1).
	mut objects := []ObjectEntry{len: 2}
	objects[0] = ObjectEntry{
		iface:  'wl_display'
		desc:   &wl_display_iface
		in_use: true
	}
	return &Connection{
		fd:      fd
		objects: objects
	}
}

// connection_from_fd takes ownership of an already connected compositor socket.
// An invalid descriptor (-1) produces an error; the socket is not closed.
pub fn connection_from_fd(fd int) !&Connection {
	if fd < 0 {
		return error('invalid compositor socket descriptor ${fd}')
	}
	return new_connection(fd)
}

// --- state ------------------------------------------------------------------

// is_closed reports whether the connection was closed or the compositor hung up.
pub fn (c &Connection) is_closed() bool {
	return c.closed || c.fd < 0
}

// close releases the socket, every queued file descriptor and the id table.
// Calling it twice is harmless.
pub fn (mut c Connection) close() {
	close_fds(c.in_fds)
	close_fds(c.out_fds)
	c.in_fds = []int{}
	c.out_fds = []int{}
	if c.fd >= 0 {
		os.fd_close(c.fd)
		c.fd = -1
	}
	c.closed = true
	c.objects = []ObjectEntry{}
	c.recv_buf = []u8{}
	c.registry_id = 0
	c.globals_cache = []Global{}
}

fn (c &Connection) entry_index(id u32) ?int {
	if id == 0 || int(id) > c.objects.len {
		return none
	}
	index := int(id) - 1
	if !c.objects[index].in_use {
		return none
	}
	return index
}

fn (mut c Connection) ensure_capacity(id u32) {
	if int(id) > c.objects.len {
		missing := int(id) - c.objects.len
		c.objects << []ObjectEntry{len: missing}
	}
}

// --- object table -----------------------------------------------------------

// alloc_id reserves a fresh object id. Ids are recycled only after the
// compositor confirms their destruction with wl_display.delete_id, exactly as
// the protocol requires.
pub fn (mut c Connection) alloc_id() !u32 {
	if c.closed {
		return error('the connection is closed')
	}
	for c.free_ids.len > 0 {
		id := c.free_ids.pop()
		index := int(id) - 1
		if index < c.objects.len && !c.objects[index].in_use {
			c.objects[index] = ObjectEntry{}
			return id
		}
	}
	id := c.next_id
	c.next_id++
	c.ensure_capacity(id)
	return id
}

// register_object attaches an interface description to an object id, either one
// returned by `alloc_id()` or one the compositor created and announced in an
// event. Registering an id twice is an error.
pub fn (mut c Connection) register_object(id u32, iface string, desc &IfaceDesc) ! {
	if id == 0 {
		return error('object id 0 is the null object')
	}
	if c.closed {
		return error('the connection is closed')
	}
	c.ensure_capacity(id)
	index := int(id) - 1
	if c.objects[index].in_use {
		return error('object id ${id} is already in use')
	}
	c.objects[index] = ObjectEntry{
		iface:  iface
		desc:   desc
		in_use: true
	}
	if id >= c.next_id {
		c.next_id = id + 1
	}
}

// set_sink installs the handler that receives this object's events.
pub fn (mut c Connection) set_sink(id u32, sink EventSink) ! {
	index := c.entry_index(id) or { return error('cannot listen on unknown object ${id}') }
	c.objects[index].sink = sink
}

// destroy_object marks an object as destroyed after its destructor request was
// sent. Further requests on it fail, and the id is recycled once the compositor
// sends wl_display.delete_id.
pub fn (mut c Connection) destroy_object(id u32) {
	index := c.entry_index(id) or { return }
	c.objects[index].destroyed = true
}

// object_destroyed reports whether an object id is known and already destroyed.
pub fn (c &Connection) object_destroyed(id u32) bool {
	index := c.entry_index(id) or { return true }
	return c.objects[index].destroyed
}

// release_id frees an id confirmed as deleted by the compositor.
fn (mut c Connection) release_id(id u32) {
	if id <= c.display_id || int(id) > c.objects.len {
		return
	}
	index := int(id) - 1
	if !c.objects[index].in_use {
		return
	}
	c.objects[index] = ObjectEntry{}
	c.free_ids << id
}

// --- sending ----------------------------------------------------------------

// request queues one message on an object. The arguments must match the
// interface description in both order and type; the id table is validated so
// that requests on destroyed or unknown objects fail instead of corrupting the
// connection.
pub fn (mut c Connection) request(object_id u32, opcode int, args []ArgValue) ! {
	if c.closed {
		return error('the connection is closed')
	}
	index := c.entry_index(object_id) or { return error('request on unknown object ${object_id}') }
	entry := c.objects[index]
	if entry.destroyed {
		return error('request on destroyed object ${object_id} (${entry.iface})')
	}
	if entry.desc != unsafe { nil } {
		if _ := entry.desc.request(opcode) {
			// ok
		} else {
			return error('unknown request ${opcode} for interface ${entry.iface}')
		}
	}
	mut encoder := new_encoder(object_id, opcode)
	encoder.args(args)
	data := encoder.message()
	if data.len > 0xffff {
		return error('request ${entry.iface}#${opcode} is too large')
	}
	c.out_buf << data
	if encoder.fds.len > 0 {
		c.out_fds << encoder.fds
	}
	if c.out_buf.len >= 4096 {
		c.flush()!
	}
}

// flush writes every queued message to the compositor.
pub fn (mut c Connection) flush() ! {
	if c.out_buf.len == 0 {
		if c.out_fds.len > 0 {
			close_fds(c.out_fds)
			c.out_fds = []int{}
		}
		return
	}
	if c.closed {
		close_fds(c.out_fds)
		c.out_fds = []int{}
		return error('the connection is closed')
	}
	mut sent := 0
	mut first := true
	for sent < c.out_buf.len {
		pending_fds := if first { c.out_fds } else { []int{} }
		written := send_bytes(c.fd, c.out_buf[sent..], pending_fds) or {
			close_fds(c.out_fds)
			c.out_fds = []int{}
			return err
		}
		if written <= 0 {
			close_fds(c.out_fds)
			c.out_fds = []int{}
			return error('could not write to the compositor socket')
		}
		sent += written
		first = false
	}
	c.out_buf = []u8{}
	c.out_fds = []int{}
}

// --- receiving --------------------------------------------------------------

fn (mut c Connection) fill_recv(nonblocking bool) !int {
	if c.closed {
		return error('the connection is closed')
	}
	if c.recv_pos > 0 {
		c.recv_buf = c.recv_buf[c.recv_pos..].clone()
		c.recv_pos = 0
	}
	chunk := receive_bytes(c.fd, recv_chunk, nonblocking)!
	if chunk.n == 0 {
		if nonblocking {
			return 0
		}
		c.closed = true
		return error('the compositor closed the connection')
	}
	c.recv_buf << chunk.data
	if chunk.fds.len > 0 {
		c.in_fds << chunk.fds
	}
	return chunk.n
}

fn (mut c Connection) full_message_ready() bool {
	if c.recv_pos + wire_header_size > c.recv_buf.len {
		return false
	}
	size := int(get_u32_at(c.recv_buf, c.recv_pos + 4) >> 16)
	return c.recv_pos + size <= c.recv_buf.len
}

fn (mut c Connection) take_fds(count int) ![]int {
	if count == 0 {
		return []int{}
	}
	if c.in_fds.len < count {
		return error('message carries ${count} file descriptors but only ${c.in_fds.len} were received')
	}
	mut taken := []int{cap: count}
	for _ in 0 .. count {
		taken << c.in_fds[0]
		c.in_fds.delete(0)
	}
	return taken
}

fn (mut c Connection) parse_message() !Message {
	object_id := get_u32_at(c.recv_buf, c.recv_pos)
	word := get_u32_at(c.recv_buf, c.recv_pos + 4)
	size := int(word >> 16)
	opcode := int(word & 0xffff)
	if size < wire_header_size || size % 4 != 0 {
		return error('malformed wayland message: size ${size}')
	}
	body := c.recv_buf[c.recv_pos + wire_header_size..c.recv_pos + size].clone()
	c.recv_pos += size
	index := c.entry_index(object_id) or {
		return Message{
			object_id: object_id
			opcode:    opcode
		}
	}
	entry := c.objects[index]
	if entry.desc == unsafe { nil } {
		return Message{
			object_id: object_id
			opcode:    opcode
			iface:     entry.iface
		}
	}
	event := entry.desc.event(opcode) or {
		return error('unknown event ${opcode} for interface ${entry.iface}')
	}
	fds := c.take_fds(event.fd_count())!
	return decode_event(entry.iface, entry.desc, object_id, opcode, body, fds)!
}

// next_message reads and decodes one message without dispatching it. It blocks
// until a complete message is available.
pub fn (mut c Connection) next_message() !Message {
	for {
		if c.full_message_ready() {
			return c.parse_message()!
		}
		c.fill_recv(false)!
	}
}

// has_message reports whether a complete message is already buffered.
pub fn (c &Connection) has_message() bool {
	if c.recv_pos + wire_header_size > c.recv_buf.len {
		return false
	}
	size := int(get_u32_at(c.recv_buf, c.recv_pos + 4) >> 16)
	return c.recv_pos + size <= c.recv_buf.len
}

// dispatch_message delivers one message to the object it is addressed to. It
// handles wl_display.error and wl_display.delete_id itself; everything else goes
// to the object's listener.
pub fn (mut c Connection) dispatch_message(msg &Message) ! {
	if msg.object_id == c.display_id {
		match msg.opcode {
			0 {
				// wl_display.error: the compositor refuses to continue.
				code := msg.arg_u32(1) or { u32(0) }
				text := msg.arg_string(2) or { 'unknown error' }
				c.closed = true
				return ProtocolError{
					object_id: msg.arg_u32(0) or { u32(0) }
					code:      code
					message:   text
				}
			}
			1 {
				// wl_display.delete_id: the id is free again.
				if id := msg.arg_u32(0) {
					c.release_id(id)
				}
				return
			}
			else {}
		}
	}
	index := c.entry_index(msg.object_id) or { return }
	if c.objects[index].desc == unsafe { nil } {
		return
	}
	iface_name := c.objects[index].iface
	handled := c.objects[index].sink.on_event(msg)!
	if !handled && c.debug {
		eprintln('wayland: unhandled ${iface_name} event ${msg.opcode}')
	}
}

// dispatch writes pending requests, then blocks until one event arrives and
// delivers it.
pub fn (mut c Connection) dispatch() ! {
	c.flush()!
	msg := c.next_message()!
	c.dispatch_message(msg)!
}

// dispatch_pending delivers every event that is already available without
// blocking, returning how many were delivered.
pub fn (mut c Connection) dispatch_pending() !int {
	c.flush()!
	mut count := 0
	for {
		if !c.full_message_ready() {
			before := c.recv_buf.len
			c.fill_recv(true)!
			if c.recv_buf.len == before {
				break // nothing more to read
			}
		}
		if !c.full_message_ready() {
			continue // partial message, read the rest
		}
		msg := c.parse_message()!
		c.dispatch_message(msg)!
		count++
	}
	return count
}

// sync asks the compositor for a callback that fires when every request sent so
// far has been processed.
pub fn (mut c Connection) sync() !u32 {
	callback := c.alloc_id()!
	c.register_object(callback, 'wl_callback', &wl_callback_iface)!
	c.request(c.display_id, 0, [ArgValue(ObjectRef{
		id: callback
	})])!
	return callback
}

// roundtrip blocks until the compositor has processed every request sent so far,
// delivering the events that arrive in the meantime to their listeners.
pub fn (mut c Connection) roundtrip() ! {
	callback := c.sync()!
	c.flush()!
	for {
		msg := c.next_message()!
		if msg.object_id == callback && msg.opcode == 0 {
			return
		}
		c.dispatch_message(msg)!
	}
}
