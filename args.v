module wayland

// A decoded argument value. The variant tells the wire representation:
//
// i32      -- int
// u32      -- uint
// Fixed    -- fixed
// string   -- str
// []u8     -- array
// Fd       -- fd
// ObjectRef -- object and new_id (both are just an object id on the wire)
pub type ArgValue = Fd | ObjectRef | []u8 | Fixed | i32 | string | u32

// Fd is a file descriptor received with a message. The receiver owns it and is
// responsible for closing it.
pub struct Fd {
pub:
	fd int
}

// ObjectRef is the id of an object referenced by a message.
pub struct ObjectRef {
pub:
	id u32
}

// Message is one decoded protocol message.
pub struct Message {
pub:
	// object_id is the object the message is addressed to.
	object_id u32
	// opcode is the event opcode inside the interface.
	opcode int
	// iface is the interface name of the receiving object, empty when the object
	// is unknown to the library.
	iface string
	// args are the decoded arguments in wire order.
	args []ArgValue
}

// arg returns the raw argument at `index`.
pub fn (m &Message) arg(index int) !ArgValue {
	if index < 0 || index >= m.args.len {
		return error('missing argument ${index} for ${m.iface} event ${m.opcode}')
	}
	return m.args[index]
}

fn (m &Message) wrong_type(index int, want string) IError {
	got := if index >= 0 && index < m.args.len { typeof(m.args[index]).name } else { 'nothing' }
	return error('argument ${index} of ${m.iface} event ${m.opcode} is ${got}, expected ${want}')
}

// arg_u32 returns argument `index` as an unsigned integer.
pub fn (m &Message) arg_u32(index int) !u32 {
	a := m.arg(index)!
	if a is u32 {
		return a
	}
	return m.wrong_type(index, 'uint')
}

// arg_i32 returns argument `index` as a signed integer.
pub fn (m &Message) arg_i32(index int) !i32 {
	a := m.arg(index)!
	if a is i32 {
		return a
	}
	return m.wrong_type(index, 'int')
}

// arg_int returns argument `index` as a V int.
pub fn (m &Message) arg_int(index int) !int {
	a := m.arg(index)!
	if a is i32 {
		return int(a)
	}
	if a is u32 {
		return int(a)
	}
	return m.wrong_type(index, 'int')
}

// arg_fixed returns argument `index` as a Fixed.
pub fn (m &Message) arg_fixed(index int) !Fixed {
	a := m.arg(index)!
	if a is Fixed {
		return a
	}
	return m.wrong_type(index, 'fixed')
}

// arg_string returns argument `index` as a string.
pub fn (m &Message) arg_string(index int) !string {
	a := m.arg(index)!
	if a is string {
		return a
	}
	return m.wrong_type(index, 'string')
}

// arg_array returns argument `index` as a byte array.
pub fn (m &Message) arg_array(index int) ![]u8 {
	a := m.arg(index)!
	if a is []u8 {
		return a
	}
	return m.wrong_type(index, 'array')
}

// arg_fd returns argument `index` as a file descriptor.
pub fn (m &Message) arg_fd(index int) !int {
	a := m.arg(index)!
	if a is Fd {
		return a.fd
	}
	return m.wrong_type(index, 'fd')
}

// arg_id returns argument `index` as an object id, for both object and new_id
// arguments.
pub fn (m &Message) arg_id(index int) !u32 {
	a := m.arg(index)!
	if a is ObjectRef {
		return a.id
	}
	return m.wrong_type(index, 'object')
}
