module wayland

import os

// Socket transport with file descriptor passing.
//
// Wayland speaks a unix stream protocol; the only part that cannot be expressed
// in plain V is SCM_RIGHTS ancillary data, needed to send and receive file
// descriptors together with messages. This file is the single place in the
// library that talks to the C library, and it is wrapped in small safe helpers.

#flag -D_GNU_SOURCE
#include <sys/socket.h>
#include <sys/un.h>
#include <sys/uio.h>
#include <unistd.h>
#include <errno.h>

// --- platform structure mirrors ---------------------------------------------
//
// These mirror the layout of the corresponding C structures. They are never
// declared to the C compiler, only passed to it by pointer, so the field order
// and sizes are what matter. The definitions below match glibc/musl on 64 bit
// unix systems (the same layout libwayland relies on).

struct IOVec {
mut:
	base &u8 = unsafe { nil }
	len  u64
}

struct MsgHdr {
mut:
	name       &u8 = unsafe { nil }
	namelen    u32
	iov        &IOVec = unsafe { nil }
	iovlen     u64
	control    &u8 = unsafe { nil }
	controllen u64
	flags      i32
}

// MsgCmsgHdr mirrors `struct cmsghdr`, which is a size_t followed by two C
// ints. The fields must be i32 and not V's `int`: `int` is a machine word, so
// using it here would make the header 24 bytes instead of 16 and the kernel
// would reject every file descriptor we send.
struct MsgCmsgHdr {
mut:
	length u64
	level  i32
	ctype  i32
}

struct SockAddrUn {
mut:
	family u16
	path   [108]u8
}

fn C.socket(domain int, typ int, protocol int) int

fn C.connect(fd int, addr voidptr, len u32) int

fn C.sendmsg(fd int, msg voidptr, flags int) int

fn C.recvmsg(fd int, msg voidptr, flags int) int

const unix_path_max = 108

// max_fds_per_recv bounds how many descriptors a single socket message may
// carry before the control buffer would be truncated.
const max_fds_per_recv = 28

// recv_chunk is the size of a single read from the compositor socket.
const recv_chunk = 16384

// cmsg_align rounds a control message length up to the alignment the kernel uses
// (the size of a pointer on all supported platforms).
fn cmsg_align(length u64) u64 {
	return (length + 7) & ~u64(7)
}

// cmsg_len is the length of a control message header plus its payload.
fn cmsg_len(payload u64) u64 {
	return cmsg_align(u64(sizeof(MsgCmsgHdr))) + payload
}

// cmsg_space is the space a control message occupies including its padding.
fn cmsg_space(payload u64) u64 {
	return cmsg_align(cmsg_len(payload))
}

// connect_socket connects to a unix socket at `path` and returns the socket fd.
fn connect_socket(path string) !int {
	mut addr := SockAddrUn{}
	addr.family = u16(int(C.AF_UNIX))
	bytes := path.bytes()
	if bytes.len >= unix_path_max {
		return error('wayland socket path is too long: ${path}')
	}
	for i, b in bytes {
		addr.path[i] = b
	}
	fd := C.socket(int(C.AF_UNIX), int(C.SOCK_STREAM), 0)
	if fd < 0 {
		return error('could not create a unix socket')
	}
	if C.connect(fd, &addr, u32(sizeof(SockAddrUn))) != 0 {
		os.fd_close(fd)
		return error('could not connect to wayland socket ${path}')
	}
	return fd
}

// send_bytes writes `data` to `fd`, transferring `fds` as ancillary data. It
// returns the number of bytes written, which may be less than `data.len`.
fn send_bytes(fd int, data []u8, fds []int) !int {
	if data.len == 0 {
		return 0
	}
	mut iov := IOVec{
		base: data.data
		len:  u64(data.len)
	}
	mut hdr := MsgHdr{
		iov:    &iov
		iovlen: u64(1)
	}
	mut control := []u8{}
	if fds.len > 0 {
		payload := u64(fds.len * 4)
		control = []u8{len: int(cmsg_space(payload))}
		// cmsg_len is a size_t: writing the low 32 bits is enough, the rest of
		// the zeroed buffer already holds the upper half.
		put_u32_at(mut control, 0, u32(cmsg_len(payload)))
		put_u32_at(mut control, 8, u32(int(C.SOL_SOCKET)))
		put_u32_at(mut control, 12, u32(int(C.SCM_RIGHTS)))
		for i, f in fds {
			put_u32_at(mut control, int(cmsg_len(0)) + i * 4, u32(f))
		}
		hdr.control = control.data
		hdr.controllen = u64(control.len)
	}
	return C.sendmsg(fd, &hdr, 0)
}

// Received holds the result of a single socket read.
struct Received {
mut:
	n    int
	data []u8
	fds  []int
}

// receive_bytes reads at most `max` bytes from `fd`, collecting any descriptors
// that arrived with them. When `nonblocking` is set and no data is available the
// returned `n` is 0; `n == 0` on a blocking read means the peer closed the
// connection.
fn receive_bytes(fd int, max int, nonblocking bool) !Received {
	mut buf := []u8{len: max}
	mut control := []u8{len: int(cmsg_space(u64(max_fds_per_recv * 4)))}
	mut iov := IOVec{
		base: buf.data
		len:  u64(buf.len)
	}
	mut hdr := MsgHdr{
		iov:        &iov
		iovlen:     u64(1)
		control:    control.data
		controllen: u64(control.len)
	}
	flags := if nonblocking { int(C.MSG_DONTWAIT) } else { 0 }
	n := C.recvmsg(fd, &hdr, flags)
	if n < 0 {
		if nonblocking {
			return Received{} // nothing to read right now
		}
		return error('failed to read from the wayland socket')
	}
	if hdr.flags & int(C.MSG_CTRUNC) != 0 {
		return error('too many file descriptors in a single wayland message')
	}
	mut fds := []int{}
	mut off := 0
	for off + int(sizeof(MsgCmsgHdr)) <= int(hdr.controllen) {
		length := int(get_u64_at(control, off))
		if length < int(sizeof(MsgCmsgHdr)) {
			break
		}
		level := get_i32_at(control, off + 8)
		ctype := get_i32_at(control, off + 12)
		if level == int(C.SOL_SOCKET) && ctype == int(C.SCM_RIGHTS) {
			payload_off := off + int(cmsg_len(0))
			mut i := 0
			for i + 4 <= length - int(cmsg_len(0)) {
				fds << int(get_u32_at(control, payload_off + i))
				i += 4
			}
		}
		off += int(cmsg_align(u64(length)))
	}
	return Received{
		n:    n
		data: buf[..n].clone()
		fds:  fds
	}
}

// close_fds closes every descriptor in the slice, ignoring errors.
fn close_fds(fds []int) {
	for fd in fds {
		if fd >= 0 {
			os.fd_close(fd)
		}
	}
}
