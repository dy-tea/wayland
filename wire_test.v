module wayland

// Unit tests for the wire codec, message framing and the object id table.

fn event_bytes(object_id u32, opcode int, args []ArgValue) ([]u8, []int) {
	mut encoder := new_encoder(object_id, opcode)
	encoder.args(args)
	return encoder.message(), encoder.fds
}

fn test_transport_structure_layout() {
	// These mirror `struct msghdr`, `struct cmsghdr`, `struct iovec` and
	// `struct sockaddr_un` on 64 bit unix. The kernel rejects a control message
	// whose header is not exactly 16 bytes, so a wrongly sized field here would
	// break file descriptor passing instead of failing to compile.
	assert sizeof(MsgHdr) == 56
	assert sizeof(MsgCmsgHdr) == 16
	assert sizeof(IOVec) == 16
	assert sizeof(SockAddrUn) == 110
	assert cmsg_len(0) == 16
	assert cmsg_len(4) == 20
	assert cmsg_space(4) == 24
	assert cmsg_space(0) == 16
	assert cmsg_align(20) == 24
	assert cmsg_align(16) == 16
}

fn test_fixed_point_conversion() {
	assert Fixed.new(1.5) == 384
	assert Fixed(384).f64() == 1.5
	assert Fixed.new(-2.25).f64() == -2.25
	assert Fixed(0).f64() == 0.0
	assert Fixed.new(-1.0) == -256
}

fn test_padding_helper() {
	assert pad_to_4(0) == 0
	assert pad_to_4(1) == 4
	assert pad_to_4(3) == 4
	assert pad_to_4(4) == 4
	assert pad_to_4(5) == 8
}

fn test_encode_message_layout() {
	mut encoder := new_encoder(u32(7), 3)
	encoder.args([
		ArgValue(u32(0x11223344)),
		ArgValue(i32(-2)),
		ArgValue(Fixed.new(2.5)),
		ArgValue('hi'),
		ArgValue([u8(1), u8(2), u8(3)]),
		ArgValue(ObjectRef{
			id: 9
		}),
		ArgValue(Fd{
			fd: 42
		}),
	])
	raw := encoder.message()
	// The file descriptor travels out of band, so it adds no bytes.
	assert encoder.fds == [42]
	assert raw.len == wire_header_size + 4 + 4 + 4 + 8 + 8 + 4
	assert get_u32_at(raw, 0) == 7
	// size in the upper 16 bits, opcode in the lower 16 bits
	assert int(get_u32_at(raw, 4) >> 16) == raw.len
	assert int(get_u32_at(raw, 4) & 0xffff) == 3
}

fn test_encode_empty_string_and_array() {
	mut encoder := new_encoder(u32(1), 0)
	encoder.args([ArgValue(''), ArgValue([]u8{})])
	raw := encoder.message()
	// An empty string is a length of 1 (the NUL byte) plus padding, an empty
	// array is just a zero length.
	assert raw.len == wire_header_size + 8 + 4
}

fn test_decode_args_roundtrip() {
	desc := MsgDesc{
		name:   'everything'
		opcode: 0
		args:   [
			ArgDesc{
				name: 'a'
				kind: .uint
			},
			ArgDesc{
				name: 'b'
				kind: .int
			},
			ArgDesc{
				name: 'c'
				kind: .fixed
			},
			ArgDesc{
				name: 'd'
				kind: .str
			},
			ArgDesc{
				name: 'e'
				kind: .array
			},
			ArgDesc{
				name: 'f'
				kind: .obj
			},
			ArgDesc{
				name: 'g'
				kind: .new_id
			},
			ArgDesc{
				name: 'h'
				kind: .fd
			},
		]
	}
	mut encoder := new_encoder(u32(5), 0)
	encoder.args([
		ArgValue(u32(0x11223344)),
		ArgValue(i32(-2)),
		ArgValue(Fixed.new(2.5)),
		ArgValue('hi'),
		ArgValue([u8(1), u8(2), u8(3)]),
		ArgValue(ObjectRef{
			id: 9
		}),
		ArgValue(ObjectRef{
			id: 10
		}),
		ArgValue(Fd{
			fd: 42
		}),
	])
	raw := encoder.message()
	args := decode_args(&desc, raw[wire_header_size..], encoder.fds)!
	message := Message{
		object_id: 5
		opcode:    0
		iface:     'everything'
		args:      args
	}
	assert message.arg_u32(0)! == 0x11223344
	assert message.arg_i32(1)! == -2
	assert message.arg_int(1)! == -2
	assert message.arg_fixed(2)! == Fixed.new(2.5)
	assert message.arg_string(3)! == 'hi'
	assert message.arg_array(4)! == [u8(1), u8(2), u8(3)]
	assert message.arg_id(5)! == 9
	assert message.arg_id(6)! == 10
	assert message.arg_fd(7)! == 42
}

fn test_wrong_argument_type_is_an_error() {
	desc := MsgDesc{
		name:   'one'
		opcode: 0
		args:   [
			ArgDesc{
				name: 'a'
				kind: .uint
			},
		]
	}
	mut encoder := new_encoder(u32(1), 0)
	encoder.args([ArgValue(u32(3))])
	raw := encoder.message()
	args := decode_args(&desc, raw[wire_header_size..], [])!
	message := Message{
		args: args
	}
	if _ := message.arg_string(0) {
		assert false, 'a uint argument must not decode as a string'
	}
	if _ := message.arg_u32(7) {
		assert false, 'out of range arguments must fail'
	}
}

fn test_missing_file_descriptor_is_an_error() {
	desc := MsgDesc{
		name:   'needs_fd'
		opcode: 0
		args:   [
			ArgDesc{
				name: 'fd'
				kind: .fd
			},
		]
	}
	if _ := decode_args(&desc, []u8{}, []) {
		assert false, 'a message needing an fd must fail without one'
	} else {
		assert err.msg().contains('file descriptor')
	}
}

fn test_message_framing() {
	mut conn := new_connection(-1)
	conn.register_object(2, 'wl_registry', &wl_registry_iface)!
	first, _ := event_bytes(u32(2), 0, [ArgValue(u32(1)), ArgValue('wl_shm'), ArgValue(u32(2))])
	second, _ := event_bytes(u32(2), 1, [ArgValue(u32(1))])
	mut both := first.clone()
	both << second
	conn.recv_buf = both
	assert conn.has_message()
	message := conn.next_message()!
	assert message.object_id == 2
	assert message.opcode == 0
	assert message.iface == 'wl_registry'
	assert message.arg_u32(0)! == 1
	assert message.arg_string(1)! == 'wl_shm'
	assert message.arg_u32(2)! == 2
	assert conn.has_message()
	other := conn.next_message()!
	assert other.opcode == 1
	assert other.arg_u32(0)! == 1
	assert !conn.has_message()
}

fn test_malformed_size_is_rejected() {
	mut conn := new_connection(-1)
	mut bad := []u8{len: 8}
	put_u32_at(mut bad, 0, u32(2))
	put_u32_at(mut bad, 4, u32(0)) // a zero sized message
	conn.recv_buf = bad
	if _ := conn.next_message() {
		assert false, 'size 0 must be rejected'
	} else {
		assert err.msg().contains('malformed')
	}
}

fn test_unknown_event_is_rejected() {
	mut conn := new_connection(-1)
	conn.register_object(2, 'wl_registry', &wl_registry_iface)!
	unknown, _ := event_bytes(u32(2), 9, [])
	conn.recv_buf = unknown
	if _ := conn.next_message() {
		assert false, 'an unknown event opcode must be rejected'
	} else {
		assert err.msg().contains('unknown event')
	}
}

fn test_delete_id_recycles_ids() {
	mut conn := new_connection(-1)
	taken := conn.alloc_id()!
	assert taken == 2
	conn.register_object(taken, 'wl_registry', &wl_registry_iface)!
	next := conn.alloc_id()!
	assert next == 3
	// The compositor confirms the destruction of object 2.
	confirm, _ := event_bytes(conn.display_id, 1, [ArgValue(taken)])
	conn.recv_buf = confirm
	message := conn.next_message()!
	assert message.iface == 'wl_display'
	conn.dispatch_message(&message)!
	assert conn.alloc_id()! == 2
}

fn test_display_error_is_reported() {
	mut conn := new_connection(-1)
	failure, _ := event_bytes(conn.display_id, 0, [
		ArgValue(ObjectRef{
			id: 2
		}),
		ArgValue(u32(1)),
		ArgValue('invalid method'),
	])
	conn.recv_buf = failure
	message := conn.next_message()!
	if _ := conn.dispatch_message(&message) {
		assert false, 'a display error must be reported'
	} else {
		assert err.msg().contains('invalid method')
		assert conn.is_closed()
	}
}

fn test_request_validation() {
	mut conn := new_connection(-1)
	registry := conn.alloc_id()!
	conn.register_object(registry, 'wl_registry', &wl_registry_iface)!
	// Unknown opcode.
	if _ := conn.request(registry, 99, []ArgValue{}) {
		assert false, 'unknown request opcodes must fail'
	}
	// Unknown object.
	if _ := conn.request(42, 0, []ArgValue{}) {
		assert false, 'requests on unknown objects must fail'
	}
	// Requests on destroyed objects.
	conn.destroy_object(registry)
	if _ := conn.request(registry, 0, []ArgValue{}) {
		assert false, 'requests on destroyed objects must fail'
	}
	assert conn.object_destroyed(registry)
	// A valid request is accepted and written in wire order.
	callback := conn.alloc_id()!
	assert callback == 3
	conn.register_object(callback, 'wl_callback', &wl_callback_iface)!
	conn.request(conn.display_id, 0, [ArgValue(ObjectRef{
		id: callback
	})])!
	assert conn.out_buf.len == 12
	assert get_u32_at(conn.out_buf, 0) == 1
	assert int(get_u32_at(conn.out_buf, 4) & 0xffff) == 0
	assert get_u32_at(conn.out_buf, 8) == 3
}

fn test_object_str_and_null() {
	object := Object{
		id:    4
		iface: 'wl_surface'
	}
	assert object.str() == 'wl_surface#4'
	assert !object.is_null()
	assert Object{}.is_null()
}
