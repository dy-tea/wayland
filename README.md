# wayland

A Wayland client library for [V](https://vlang.io), written in pure V.

* **No libwayland.** The wire protocol, the object id table, version negotiation and event dispatch are implemented here, in V.
* **No C glue** beyond the descriptor calls V does not expose. The only file that declares C functions is `transport.v` — `sendmsg`/`recvmsg` to pass descriptors, `lseek` to rewind one — and everything it exposes is wrapped in safe helpers; shared memory is mapped through the standard library's `os.mmap`.
* **No `unsafe` in the API you use.** Marshalling, listening, id bookkeeping and file descriptor passing are all handled by the library.
* **Generated from the protocol XML.** Interfaces, requests, events, enums, listeners and version negotiation are generated from the official XML files, so adding a protocol is one command. Generated code is `v fmt` clean.

```v
import wayland
import wayland.protocols.wayland as wl

struct SeatListener {
mut:
	capabilities u32
	name         string
}

fn (mut listener SeatListener) capabilities(proxy wl.WlSeat, capabilities u32) {
	listener.capabilities = capabilities
}

fn (mut listener SeatListener) name(proxy wl.WlSeat, name string) {
	listener.name = name
}

fn main() {
	mut conn := wayland.connect()!
	defer {
		conn.close()
	}
	globals := conn.globals()!
	seat_global := globals.find('wl_seat') or {
		eprintln('this compositor has no seat')
		return
	}
	mut seat := wl.bind_wl_seat(conn, seat_global)!
	mut listener := SeatListener{}
	seat.set_listener(&listener)!
	conn.roundtrip()! // the compositor sends capabilities and name on bind
	println('${listener.name}: capabilities ${listener.capabilities}')
}
```

The `as wl` is not decoration: the core protocol module is called `wayland`
like the library itself, and a V file cannot import two modules with the same
name. The generated modules import it the same way, so the two spellings are
everywhere: `wayland.` for the library, `wl.` for the core protocol.

## Status

What works today:

* connecting over `WAYLAND_SOCKET`, `WAYLAND_DISPLAY` or `XDG_RUNTIME_DIR`
* global discovery, binding with version negotiation, untyped and typed binding
* generated proxies for the core protocol, `xdg-shell`, `viewporter` and
  `presentation-time`, plus whatever else you point the generator at
* request marshalling with typed arguments, including `new_id` arguments (which
  return a proxy for the object the compositor creates)
* event decoding and dispatch to `mut` listener methods, including nullable
  objects, arrays, fixed point numbers, strings and file descriptors
* file descriptor passing in both directions (SCM_RIGHTS) for `wl_shm`,
  `wl_keyboard` keymaps and friends
* destructor tracking: after `destroy()` the proxy rejects further requests and
  the id is recycled once the compositor confirms it with `wl_display.delete_id`
* shared memory buffers: `ShmBuffer` bundles the memory file, the mapping, the
  pool, the buffer and the compositor release tracking, so drawing is writing
  bytes into a slice
* a real window: `examples/window` opens an xdg-shell toplevel, follows its configure events and animates it from a frame loop until it is closed or Escape is pressed
* keyboard input: seat capabilities, `wl_keyboard` key events as raw evdev key codes with names for the common ones, and `read_keymap()` for the xkb keymap the compositor sends as a file descriptor

What is not here yet:

* the server side (implementing a compositor), and protocol *helpers* above the
  generated layer: a reusable window type, and the rest of the input side
  (pointer, touch, clipboard, cursors)
* text: turning a key code into a character needs xkb state, which lives in
  `libxkbcommon`. `read_keymap()` hands over the keymap text; interpreting it is
  a different library's job, and doing it in V would be a project of its own
* an event loop: the application owns its main loop. Use `dispatch_pending()`
  with `Connection.fd` in your own poll/select, or `roundtrip()` for a blocking
  client
* multi-threaded use of one `Connection`: a connection is used from one thread
  at a time

## Running the examples and tests

```sh
v run examples/list_globals        # every global the compositor advertises
v run examples/seat                # bind a seat and print its events
v run examples/window              # a real xdg-shell window, close it or press Escape
v run examples/window -- --frames 60   # present 60 frames, then exit
v test .                           # unit, generator and end to end tests
```

`fake_compositor_test.v` implements a compositor in the test file and drives a
whole window through it: configure, ack, a shared memory buffer built from the
descriptor the fake compositor receives, the frame callback, the close request
and the teardown. It also drives the keyboard: capabilities, the keymap
arriving as a descriptor whose offset is already at the end (the way a
compositor that wrote through the same descriptor leaves it), focus, key
presses and releases. The tests in `live_compositor_test.v` talk to the running
compositor and are skipped when there is no Wayland session; they never attach a
buffer, so they do not put a window on the screen.

## Shared memory buffers

`wayland.ShmBuffer` wraps the whole shared memory path: the file (created in
`XDG_RUNTIME_DIR`, or the temporary directory, and unlinked right away), the
mapping, the `wl_shm` pool and the `wl_buffer` on top of it. Pixels are a byte
view of the mapping, so drawing is writing bytes; `attach()` attaches the buffer
to a surface and damages all of it, and `busy` stays true until the compositor
sends `wl_buffer.release`, which is what keeps a frame loop from drawing into a
buffer that is still being read:

```v
mut buffer := wayland.ShmBuffer.new(shm, width, height, wl.wl_shm_format_xrgb8888)!
mut pixels := buffer.pixels()
pixels[0] = u8(0x40) // xrgb8888 stores four bytes per pixel, blue first
buffer.attach(surface)!
surface.commit()!
```

The helper accepts the 32 bit `wl_shm` formats, which is what every compositor
supports. `examples/window` is the full version of the loop.

## Keyboard input

`wl_seat` reports what it has — keyboard, pointer, touch — and the keyboard it
hands out sends **raw Linux evdev key codes**. Those name physical keys, not
letters: key 1 is Escape whatever the layout is. `wayland.key_name()` names the
common ones, and `wayland.read_keymap()` reads the xkb keymap the compositor
sends as a file descriptor, which is what mapping a code to a keysym needs:

```v
fn (mut listener KeyboardListener) key(_proxy wl.WlKeyboard, _serial u32, _time u32, key u32, state u32) {
	if state != wl.wl_keyboard_key_state_pressed {
		return
	}
	if key == wayland.key_escape {
		listener.close_requested = true
	}
}
```

`read_keymap()` takes the `format`, `fd` and `size` of the keymap event, owns
the descriptor (it closes it) and returns the text without its terminating NUL.
Two things about that descriptor are worth knowing, because libwayland hides
both by mapping the file instead of reading it:

* it shares **one file offset** with the compositor and with every other client
  that received the same keymap, so a plain `read()` can start at the end and
  return nothing at all. The helper rewinds it first, which is also why it keeps
  working when the compositor sends the same description to client after client.
* the file is usually already unlinked when the client sees it: the compositor
  keeps it alive through the descriptors it sent, so there is no path left to
  reopen (`/proc/self/fd/...` fails with `EACCES`).

`examples/window` puts this together: it binds the seat the compositor
advertises, creates the keyboard from the seat's capabilities, reads the keymap
and closes when Escape is pressed.

## Code generation

`protocols/xml` holds the protocol descriptions; `protocols/<module>` holds the
generated modules that are checked in.

```sh
v run cmd/wayland-gen protocols/xml                 # regenerate everything
v run cmd/wayland-gen protocols/xml/xdg-shell.xml   # one protocol
v run cmd/wayland-gen -o protocols -p wayland.protocols protocols/xml/xdg-shell.xml
```

The tool writes `<out>/<protocol>/<protocol>.v` and formats it with `v fmt`
(set `wayland_GEN_NO_FMT=1` to keep the raw output). Protocols generated in the
same run get fully typed arguments for each other's interfaces; interfaces from
protocols you do not generate are passed as `wayland.Object`, so an incomplete
set still compiles.

Generated modules import the library as `wayland` and every referenced protocol
under its own module name - except the core protocol, which is imported as `wl`,
because both are called `wayland` and a V file cannot import two modules under
the same name. Client code uses the same spelling:

```v
import wayland
import wayland.protocols.wayland as wl
```

For every interface in a protocol the generated module contains:

| Generated | What it is |
| --- | --- |
| `<iface>_desc` | the `IfaceDesc` constant describing the wire layout |
| `<Name>` | a proxy struct embedding `wayland.Object` |
| `<iface>_proxy(conn, id)` | wraps an object id in a proxy |
| `bind_<iface>(conn, global)` | binds a global, negotiating the version |
| `<Name>Listener` | an interface with one `mut` method per event |
| `Noop<Name>Listener` | a listener that ignores everything, the default |
| `<proxy>.set_listener(&listener)` | installs a listener |
| one method per request | typed arguments, `!` on failure, min/max checks |
| `<iface>_<enum>_<entry>` | named constants for the protocol enums |

Two protocol quirks are worth knowing:

* `wl_registry.bind` is documented in the XML with two arguments, but the wire
  message is `usun` (name, interface, version, id). wayland-scanner special
  cases it the same way; the generator restores the wire signature so the
  generated `bind()` is correct.
* `wl_registry` has **no destroy request**: the registry protocol only defines
  `bind` (the request libwayland exposes as `wl_registry_destroy` merely drops
  the client side proxy and sends nothing). The library keeps one registry per
  connection for its own lookups and never sends anything else on it.

## Design notes

**Objects.** Everything on the wire is addressed by a 32 bit object id. A proxy
is a value type holding `wayland.Object` (the connection, the id and the
interface name), so copying it is cheap and it can live in your own structs.
`Object.is_alive()` asks the connection, so it stays correct after a destroy.

**Listeners** are plain V interfaces with `mut` methods: generated code installs
a per interface sink that decodes an event and calls the listener with typed
arguments. There is no `void*` user data, no casts and no opcode `match` in
application code. The default listener ignores events, so you only implement the
events you care about (`Noop<Name>Listener`).

**Globals.** `globals()` keeps a snapshot per connection: the first call does a
registry roundtrip and records every `global` and `global_remove`, so a later
call returns the same list (updated with anything that appeared in the
meantime) and only needs a `wl_display.sync`. When you want to react to devices
and outputs appearing at run time, take your own registry with
`get_registry()` and listen on it with the generated `wl_registry` listener.

**Ids.** Ids start at 2 (`wl_display` is 1). A released id is recycled only
after the compositor sends `wl_display.delete_id` for it, exactly as the
protocol requires, and the free list is checked before the counter grows.

**File descriptors** travel as SCM_RIGHTS ancillary data, which is the one thing
that cannot be expressed in V alone. `transport.v` mirrors `struct msghdr`,
`struct cmsghdr` and `struct iovec` by layout and calls `sendmsg`/`recvmsg`. The
field types matter: `struct cmsghdr` is a `size_t` and two C `int`s, so its
mirror uses `i32` and not V's `int` (which is a machine word); the test suite
asserts the resulting sizes, because a 24 byte control header makes the kernel
reject every descriptor silently.

**Version negotiation.** `bind_<iface>()` binds `min(global.version,
interface.version)`, so a client never asks for more than the compositor
supports, and `bind_global()` refuses a version the compositor did not
advertise.

**Events you do not decode.** Objects registered with `opaque_iface` (for
example a global whose protocol module you did not generate) drop their events
instead of failing, so a partial protocol set keeps working.

## Documentation

* [`wayland.v`](wayland.v) — the module overview and connection helpers
* [`connection.v`](connection.v) — `Connection`: dispatch, ids, requests
* [`registry.v`](registry.v) — globals: discovery and binding
* [`wire.v`](wire.v) and [`args.v`](args.v) — the wire format and argument values
* [`shm.v`](shm.v) — shared memory buffers for drawing
* [`input.v`](input.v) — key codes, names and reading the keymap
* [`gen/emit.v`](gen/emit.v) — what a generated module looks like, and why
* [`examples/seat`](examples/seat) — listeners end to end
* [`examples/window`](examples/window) — a real window: roles, configure, frame loop

## Protocol files and license

`protocols/xml` contains the protocol descriptions (the core `wayland.xml` and
the stable wayland-protocols files), each under its original license and
copyright, kept unchanged from the upstream releases. The generated modules in
`protocols/*` derive from those files.
