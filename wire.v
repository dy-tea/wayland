module wayland

// The Wayland wire format.
//
// Every message is a header of two 32 bit words followed by the arguments:
//
//   word 0: object id
//   word 1: size in the upper 16 bits, opcode in the lower 16 bits
//
// Integers, object ids and fixed point numbers take 4 bytes, strings and arrays
// carry a 32 bit length ("including the NUL byte" for strings) followed by their
// content padded to a multiple of 4. File descriptors occupy no bytes at all and
// instead travel in the ancillary data of the socket message.

// wire_header_size is the size of the fixed part of every message.
const wire_header_size = 8

@[inline]
fn put_u32_at(mut b []u8, offset int, v u32) {
	b[offset] = u8(v & 0xff)
	b[offset + 1] = u8((v >> 8) & 0xff)
	b[offset + 2] = u8((v >> 16) & 0xff)
	b[offset + 3] = u8((v >> 24) & 0xff)
}

@[inline]
fn get_u32_at(b []u8, offset int) u32 {
	return u32(b[offset]) | (u32(b[offset + 1]) << 8) | (u32(b[offset + 2]) << 16) | (u32(b[offset + 3]) << 24)
}

@[inline]
fn get_i32_at(b []u8, offset int) i32 {
	return i32(get_u32_at(b, offset))
}

@[inline]
fn get_u64_at(b []u8, offset int) u64 {
	mut v := u64(0)
	for i in 0 .. 8 {
		v |= u64(b[offset + i]) << (u64(i) * 8)
	}
	return v
}

// pad_to_4 returns the length rounded up to a multiple of 4.
@[inline]
fn pad_to_4(length int) int {
	return (length + 3) & ~3
}

// --- encoding ---------------------------------------------------------------

struct Encoder {
mut:
	buf    []u8
	fds    []int
	opcode int
}

fn new_encoder(object_id u32, opcode int) Encoder {
	mut e := Encoder{
		buf:    []u8{len: wire_header_size}
		opcode: opcode
	}
	put_u32_at(mut e.buf, 0, object_id)
	return e
}

fn (mut e Encoder) args(values []ArgValue) {
	for v in values {
		match v {
			Fd {
				e.fds << v.fd
			}
			ObjectRef {
				e.put_u32(v.id)
			}
			[]u8 {
				e.put_array(v)
			}
			Fixed {
				e.put_i32(Fixed.new(v))
			}
			i32 {
				e.put_i32(v)
			}
			string {
				e.put_string(v)
			}
			u32 {
				e.put_u32(v)
			}
		}
	}
}

fn (mut e Encoder) put_u32(v u32) {
	mut off := e.buf.len
	e.buf << []u8{len: 4}
	put_u32_at(mut e.buf, off, v)
}

fn (mut e Encoder) put_i32(v i32) {
	mut off := e.buf.len
	e.buf << []u8{len: 4}
	put_u32_at(mut e.buf, off, u32(v))
}

fn (mut e Encoder) put_string(s string) {
	bytes := s.bytes()
	mut off := e.buf.len
	e.buf << []u8{len: 4}
	put_u32_at(mut e.buf, off, u32(bytes.len + 1)) // length includes the NUL byte
	e.buf << bytes
	e.buf << u8(0)
	for e.buf.len % 4 != 0 {
		e.buf << u8(0)
	}
}

fn (mut e Encoder) put_array(bytes []u8) {
	mut off := e.buf.len
	e.buf << []u8{len: 4}
	put_u32_at(mut e.buf, off, u32(bytes.len))
	e.buf << bytes
	for e.buf.len % 4 != 0 {
		e.buf << u8(0)
	}
}

// message returns the encoded message with the size field patched in.
fn (mut e Encoder) message() []u8 {
	size := e.buf.len
	put_u32_at(mut e.buf, 4, (u32(size) << 16) | u32(e.opcode))
	return e.buf
}

// --- decoding ---------------------------------------------------------------

struct Decoder {
mut:
	data   []u8
	pos    int
	fds    []int
	fd_pos int
}

fn (d &Decoder) remaining() int {
	return d.data.len - d.pos
}

fn (mut d Decoder) need(bytes int) ! {
	if d.remaining() < bytes {
		return error('truncated message: ${bytes} bytes needed, ${d.remaining()} available')
	}
}

fn (mut d Decoder) u32() !u32 {
	d.need(4)!
	v := get_u32_at(d.data, d.pos)
	d.pos += 4
	return v
}

fn (mut d Decoder) i32() !i32 {
	d.need(4)!
	v := get_i32_at(d.data, d.pos)
	d.pos += 4
	return v
}

fn (mut d Decoder) fixed() !Fixed {
	return Fixed(d.i32()!)
}

fn (mut d Decoder) string() !string {
	length := int(d.u32()!)
	if length == 0 {
		return '' // null string
	}
	d.need(length)!
	body := d.data[d.pos..d.pos + length - 1].bytestr()
	d.pos += pad_to_4(length)
	return body
}

fn (mut d Decoder) array() ![]u8 {
	length := int(d.u32()!)
	d.need(length)!
	body := d.data[d.pos..d.pos + length].clone()
	d.pos += pad_to_4(length)
	return body
}

fn (mut d Decoder) fd() !int {
	if d.fd_pos >= d.fds.len {
		return error('message needs a file descriptor but none was received')
	}
	fd := d.fds[d.fd_pos]
	d.fd_pos++
	return fd
}

// decode_args decodes the arguments of a message using its descriptor.
fn decode_args(desc &MsgDesc, data []u8, fds []int) ![]ArgValue {
	mut d := Decoder{
		data: data
		fds:  fds
	}
	mut args := []ArgValue{cap: desc.args.len}
	for a in desc.args {
		value := match a.kind {
			.int {
				ArgValue(d.i32()!)
			}
			.uint {
				ArgValue(d.u32()!)
			}
			.fixed {
				ArgValue(d.fixed()!)
			}
			.str {
				ArgValue(d.string()!)
			}
			.obj {
				ArgValue(ObjectRef{
					id: d.u32()!
				})
			}
			.new_id {
				ArgValue(ObjectRef{
					id: d.u32()!
				})
			}
			.array {
				ArgValue(d.array()!)
			}
			.fd {
				ArgValue(Fd{
					fd: d.fd()!
				})
			}
		}
		args << value
	}
	return args
}

// decode_event builds a Message from raw bytes and the interface descriptor.
fn decode_event(iface string, desc &IfaceDesc, object_id u32, opcode int, data []u8, fds []int) !Message {
	event := desc.event(opcode) or {
		return error('unknown event ${opcode} for interface ${iface}')
	}
	return Message{
		object_id: object_id
		opcode:    opcode
		iface:     iface
		args:      decode_args(event, data, fds)!
	}
}
