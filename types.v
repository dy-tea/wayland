module wayland

// This file describes the *shape* of a Wayland protocol at run time.
//
// A generated protocol module declares one `IfaceDesc` per interface. The
// descriptors are plain data, so the connection can decode incoming events and
// validate outgoing requests without any per-interface code in the core.

// ArgKind is the wire type of one message argument.
//
// The names match the protocol XML `type` attributes, with `str` standing in for
// `string` and `obj` for `object` so that they cannot be confused with the V
// builtin types.
pub enum ArgKind {
	int    // signed 32 bit integer
	uint   // unsigned 32 bit integer
	fixed  // wl_fixed: signed 24.8 fixed point number
	str    // NUL terminated UTF-8 string
	obj    // id of an existing object
	new_id // id of an object created by the message
	array  // length prefixed byte blob
	fd     // file descriptor, transferred out of band
}

// ArgDesc describes a single message argument.
pub struct ArgDesc {
pub:
	// name is the argument name from the protocol XML.
	name string
	// kind is the wire representation.
	kind ArgKind
	// iface is the interface name for object and new_id arguments, empty when
	// the protocol does not constrain it.
	iface string
	// nullable is true when the protocol allows a null object argument.
	nullable bool
	// enum_name is the name of the protocol enum the argument belongs to, if any.
	enum_name string
}

// MsgDesc describes one request or one event of an interface.
pub struct MsgDesc {
pub:
	// name is the message name from the protocol XML.
	name string
	// opcode is the position of the message in the interface, used on the wire.
	opcode int
	// since is the interface version that introduced the message.
	since u32
	// destructor marks requests that destroy the object they are sent to.
	destructor bool
	// args are the message arguments in wire order.
	args []ArgDesc
}

// IfaceDesc describes a Wayland interface: its name, the highest version this
// library implements, and every request and event with its arguments.
//
// Descriptors are declared once per interface (as `pub const` values in the
// generated protocol modules) and referenced by the connection, hence `@[heap]`.
@[heap]
pub struct IfaceDesc {
pub:
	name     string
	version  u32
	requests []MsgDesc
	events   []MsgDesc
}

// request returns the descriptor of the request with the given opcode.
pub fn (d &IfaceDesc) request(opcode int) ?&MsgDesc {
	if opcode < 0 || opcode >= d.requests.len {
		return none
	}
	return &d.requests[opcode]
}

// event returns the descriptor of the event with the given opcode.
pub fn (d &IfaceDesc) event(opcode int) ?&MsgDesc {
	if opcode < 0 || opcode >= d.events.len {
		return none
	}
	return &d.events[opcode]
}

// arg returns the descriptor of argument `index` of this message.
pub fn (m &MsgDesc) arg(index int) ?&ArgDesc {
	if index < 0 || index >= m.args.len {
		return none
	}
	return &m.args[index]
}

// fd_count returns the number of file descriptors the message transfers.
pub fn (m &MsgDesc) fd_count() int {
	mut n := 0
	for a in m.args {
		if a.kind == .fd {
			n++
		}
	}
	return n
}
