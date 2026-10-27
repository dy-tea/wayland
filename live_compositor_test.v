module wayland

import os
import wayland.protocols.wayland

// Tests against the real compositor of the current session. They are skipped
// when there is no Wayland session, so `v test .` works on headless machines
// and in CI; run them with a compositor to check the library end to end.

fn live_session_available() bool {
	return os.getenv('WAYLAND_DISPLAY') != '' || os.getenv('WAYLAND_SOCKET') != ''
}

struct LiveSeatListener {
mut:
	capabilities_seen bool
	capabilities      u32
	name_seen         bool
	name              string
}

fn (mut listener LiveSeatListener) capabilities(_ wayland.WlSeat, capabilities u32) {
	listener.capabilities_seen = true
	listener.capabilities = capabilities
}

fn (mut listener LiveSeatListener) name(_ wayland.WlSeat, name string) {
	listener.name_seen = true
	listener.name = name
}

fn test_live_globals_and_surface() {
	if !live_session_available() {
		eprintln('wayland: skipping live compositor test, no Wayland session')
		return
	}
	mut conn := connect()!
	globals := conn.globals()!
	defer {
		conn.close()
	}
	assert globals.len > 0
	compositor_global := globals.find('wl_compositor') or {
		eprintln('wayland: skipping live test, no wl_compositor global')
		return
	}
	// Bind a generated proxy, create a surface and destroy it again. A surface
	// that never gets a buffer is never shown, so this is safe to run anywhere.
	mut compositor := wayland.bind_wl_compositor(conn, compositor_global)!
	surface := compositor.create_surface()!
	assert surface.is_alive()
	assert surface.str().contains('wl_surface')
	surface.destroy()!
	assert !surface.is_alive()
	conn.flush()!
	// Damage and commit on a destroyed surface must fail instead of corrupting
	// the connection.
	if _ := surface.commit() {
		assert false, 'a destroyed surface must reject requests'
	}
}

fn test_live_listener_dispatch() {
	if !live_session_available() {
		eprintln('wayland: skipping live listener test, no Wayland session')
		return
	}
	mut conn := connect()!
	globals := conn.globals()!
	defer {
		conn.close()
	}
	seat_global := globals.find('wl_seat') or {
		eprintln('wayland: skipping live listener test, no wl_seat global')
		return
	}
	mut seat := wayland.bind_wl_seat(conn, seat_global)!
	mut listener := LiveSeatListener{}
	seat.set_listener(&listener)!
	// The compositor sends capabilities and name as soon as the client binds the
	// seat, so a roundtrip is enough to see generated event dispatch in action.
	conn.roundtrip()!
	assert listener.capabilities_seen
	assert listener.name_seen
	assert listener.name != ''
}

fn test_live_shared_memory_pool() {
	if !live_session_available() {
		eprintln('wayland: skipping live shared memory test, no Wayland session')
		return
	}
	mut conn := connect()!
	globals := conn.globals()!
	defer {
		conn.close()
	}
	shm_global := globals.find('wl_shm') or {
		eprintln('wayland: skipping live shared memory test, no wl_shm global')
		return
	}
	// wl_shm takes a file descriptor over the socket, which exercises the whole
	// out of band path against a real compositor.
	path := '/dev/shm/wayland-live-${os.getpid()}'
	defer {
		os.rm(path) or {}
	}
	os.write_file(path, '0'.repeat(4096))!
	// The pool descriptor has to allow mapping, so open it read-write: the
	// descriptor `os.create()` returns only allows writing.
	mut file := os.open_file(path, 'r+')!
	defer {
		file.close()
	}
	mut shm := wayland.bind_wl_shm(conn, shm_global)!
	mut pool := shm.create_pool(file.fd, 4096)!
	// Creating a buffer makes the compositor map the pool, so the descriptor and
	// its size are really usable.
	buffer := pool.create_buffer(0, 4, 4, 16, wayland.wl_shm_format_argb8888)!
	conn.roundtrip()!
	assert buffer.is_alive()
	buffer.destroy()!
	pool.destroy()!
	conn.roundtrip()!
}
