module wayland

// Object is the identity of a Wayland object: the connection it lives on, its id
// and the name of the interface it implements. Every generated protocol proxy
// embeds one of these, which is what lets listeners, descriptors and the object
// table work without any unsafe code at the call site.

// Object identifies an object on a connection. The zero value (id 0) is the null
// object, which is how Wayland spells "no object" for nullable arguments.
pub struct Object {
pub:
	// id is the object id inside the connection.
	id u32
	// conn is the connection the object lives on.
	conn &Connection = unsafe { nil }
	// iface is the interface name, e.g. "wl_surface".
	iface string
}

// is_null reports whether this is the null object.
pub fn (o Object) is_null() bool {
	return o.id == 0
}

// is_alive reports whether the object still exists on a live connection.
pub fn (o Object) is_alive() bool {
	if o.id == 0 || o.conn == unsafe { nil } || o.conn.is_closed() {
		return false
	}
	return !o.conn.object_destroyed(o.id)
}

// str returns a debugging friendly description like "wl_surface#7".
pub fn (o Object) str() string {
	if o.iface == '' {
		return 'object#${o.id}'
	}
	return '${o.iface}#${o.id}'
}
