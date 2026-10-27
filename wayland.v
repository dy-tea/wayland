// wayland is a pure V Wayland client library. It speaks the Wayland wire
// protocol directly: there is no dependency on libwayland and no C glue beyond
// the socket calls that carry file descriptors.
//
// The intended workflow is:
//
//  1. connect to the compositor with `wayland.connect()`
//  2. discover the available globals with `Connection.globals()`
//  3. bind the ones you need through a generated protocol module, for example
//     `wayland.bind_compositor(conn, global)`
//  4. register listeners with the generated `set_listener()` methods, which are
//     plain V interfaces with `mut` methods
//  5. drive the protocol with `Connection.dispatch()`, `dispatch_pending()` and
//     `roundtrip()`
//
// Protocol proxies are value types holding an `Object` (connection + id +
// interface name), so they are cheap to copy and can be stored in your own
// structs. Nothing in the public API requires `unsafe`, and marshalling,
// versioning and id bookkeeping are handled by the library.
//
// Protocol modules under `wayland.protocols` are generated from the XML files in
// `protocols/xml` by the `wayland-gen` tool; see `v run cmd/wayland-gen --help`.
module wayland

import os
import v.vmod

// version is the library version.
pub const version = vmod.decode(@VMOD_FILE)!.version

// connect connects to the compositor described by the environment: it honours
// WAYLAND_SOCKET (an inherited socket), WAYLAND_DISPLAY (a socket name or an
// absolute path, defaulting to "wayland-0") and XDG_RUNTIME_DIR.
pub fn connect() !&Connection {
	inherited := os.getenv('WAYLAND_SOCKET')
	if inherited != '' {
		fd := inherited.int()
		if fd <= 0 {
			return error('WAYLAND_SOCKET is not an inherited socket descriptor: ${inherited}')
		}
		return connection_from_fd(fd)
	}
	display := os.getenv('WAYLAND_DISPLAY')
	name := if display == '' { 'wayland-0' } else { display }
	if name.contains('/') {
		return connect_to(name)
	}
	runtime := os.getenv('XDG_RUNTIME_DIR')
	if runtime == '' {
		return error('neither WAYLAND_SOCKET nor XDG_RUNTIME_DIR is set')
	}
	return connect_to('${runtime}/${name}')
}

// connect_to connects to a compositor socket at `path`.
pub fn connect_to(path string) !&Connection {
	fd := connect_socket(path)!
	return new_connection(fd)
}
