module wayland

// ProtocolError is raised when the compositor reports a protocol error, and when
// the library detects that a message violates the protocol.
pub struct ProtocolError {
pub:
	// object_id is the object the error refers to.
	object_id u32
	// code is the error code from wl_display.error, or 0 for errors detected
	// locally by the library.
	code u32
	// message is the human readable description.
	message string
}

// msg implements the IError interface.
pub fn (e ProtocolError) msg() string {
	if e.code == 0 {
		return 'wayland protocol error on object ${e.object_id}: ${e.message}'
	}
	return 'wayland protocol error ${e.code} on object ${e.object_id}: ${e.message}'
}

// code implements the IError interface.
pub fn (e ProtocolError) code() int {
	return int(e.code)
}
