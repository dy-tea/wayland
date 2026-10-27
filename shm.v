module wayland

import os
import rand
import wayland.protocols.wayland as wl

// Shared memory buffers.
//
// A client hands pixels to the compositor through a file descriptor both sides
// map: the client fills a `wl_buffer` backed by that memory and attaches it to
// a surface, the compositor composites it. This file wraps that whole dance -
// the shared memory file, the mapping, the pool, the buffer and the release
// bookkeeping - in one type, so that a window is drawn by writing bytes.

// ShmBuffer is a wl_buffer backed by a mapped shared memory file.
//
// Pixels are written through `pixels()`, a byte view of the mapping laid out
// the way the protocol format requires (for the 32 bit formats that is four
// bytes per pixel, little endian). `busy` tracks the compositor: `attach()`
// sets it, the wl_buffer.release the compositor sends later clears it, so a
// client never draws into a buffer that is still being read.
@[heap]
pub struct ShmBuffer {
pub mut:
	// object is the wl_buffer to attach to a surface.
	object wl.WlBuffer
	// width is the buffer width in pixels.
	width int
	// height is the buffer height in pixels.
	height int
	// stride is the length of one row in bytes.
	stride int
	// format is the wl_shm format the pixels are stored in.
	format u32
	// busy is true while the compositor may still be reading the pixels.
	busy bool
mut:
	pool    wl.WlShmPool
	fd      int
	mapping &os.Mmap = unsafe { nil }
}

// new creates a wl_buffer of `width` x `height` pixels in `format`, backed by a
// fresh shared memory file. The file is unlinked as soon as the compositor has
// a descriptor for it: it stays alive for as long as the mapping, the
// descriptor and the compositor's copy of it exist.
pub fn ShmBuffer.new(shm wl.WlShm, width int, height int, format u32) !&ShmBuffer {
	if width <= 0 || height <= 0 {
		return error('a shared memory buffer needs a positive size, got ${width}x${height}')
	}
	if !is_32_bit_shm_format(format) {
		return error('wl_shm format ${format} is not a 32 bit format; use wl_shm_format_xrgb8888 or wl_shm_format_argb8888')
	}
	stride := width * 4
	size := stride * height
	path := shm_file_path()
	mapping := os.mmap_create(path, u64(size)) or { return err }
	file := os.open_file(path, 'r+') or {
		mapping.close()
		os.rm(path) or {}
		return err
	}
	fd := file.fd
	os.rm(path) or {}
	mut pool := shm.create_pool(fd, i32(size)) or {
		os.fd_close(fd)
		mapping.close()
		return err
	}
	buffer := pool.create_buffer(0, i32(width), i32(height), i32(stride), format) or {
		pool.destroy() or {}
		os.fd_close(fd)
		mapping.close()
		return err
	}
	mut object := &ShmBuffer{
		object:  buffer
		width:   width
		height:  height
		stride:  stride
		format:  format
		pool:    pool
		fd:      fd
		mapping: mapping
	}
	object.object.set_listener(&ShmReleaseListener{
		buffer: object
	})!
	return object
}

// pixels returns the mapped memory as bytes, `stride * height` long. Writing to
// it writes to the buffer: the compositor sees the changes when the buffer is
// attached and committed. The view is empty after `destroy()`.
pub fn (b &ShmBuffer) pixels() []u8 {
	return unsafe { b.mapping.bytes() }
}

// size returns the buffer size in bytes.
pub fn (b &ShmBuffer) size() int {
	return b.stride * b.height
}

// attach attaches the buffer to a surface and damages all of it. The buffer
// becomes busy until the compositor releases it; commit the surface to present
// it.
pub fn (mut b ShmBuffer) attach(surface wl.WlSurface) ! {
	surface.attach(b.object, 0, 0)!
	surface.damage(0, 0, i32(b.width), i32(b.height))!
	b.busy = true
}

// destroy destroys the buffer and its pool and releases the mapping and the
// shared memory file. It is harmless to call it twice, or after the connection
// was closed.
pub fn (mut b ShmBuffer) destroy() {
	if b.fd < 0 {
		return
	}
	b.object.destroy() or {}
	b.pool.destroy() or {}
	b.mapping.close()
	os.fd_close(b.fd)
	b.fd = -1
	b.busy = false
}

// ShmReleaseListener clears the busy flag of the buffer the compositor is done
// with. It is installed by `ShmBuffer.new()` and is not part of the public API.
struct ShmReleaseListener {
mut:
	buffer &ShmBuffer
}

fn (mut listener ShmReleaseListener) release(_ wl.WlBuffer) {
	listener.buffer.busy = false
}

// shm_file_path returns the name of a shared memory file to create: next to the
// compositor socket when there is a runtime directory, in the system temporary
// directory otherwise.
fn shm_file_path() string {
	runtime := os.getenv('XDG_RUNTIME_DIR')
	dir := if runtime != '' { runtime } else { os.temp_dir() }
	return os.join_path(dir, 'wl-shm-${os.getpid()}-${rand.u64():x}')
}

// is_32_bit_shm_format reports whether the pixels of a wl_shm format are four
// bytes each, which is the layout `ShmBuffer.new()` allocates for.
fn is_32_bit_shm_format(format u32) bool {
	return format in [
		wl.wl_shm_format_argb8888,
		wl.wl_shm_format_xrgb8888,
		wl.wl_shm_format_xbgr8888,
		wl.wl_shm_format_abgr8888,
		wl.wl_shm_format_rgbx8888,
		wl.wl_shm_format_bgrx8888,
		wl.wl_shm_format_rgba8888,
		wl.wl_shm_format_bgra8888,
	]
}
