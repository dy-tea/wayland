# wayland

A Wayland client library for [V](https://vlang.io), written in pure V.

* **No libwayland.** The wire protocol, the object id table, version negotiation and event dispatch are implemented here, in V.
* **No C glue** beyond the descriptor calls V does not expose.
* **No `unsafe` in the API you use.** Marshalling, listening, id bookkeeping and file descriptor passing are all handled by the library.

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

## Status

What works today:

* connecting over `WAYLAND_SOCKET`, `WAYLAND_DISPLAY` or `XDG_RUNTIME_DIR`
* global discovery, binding with version negotiation, untyped and typed binding
* generated proxies for the core protocol, `xdg-shell`, `viewporter`,
  `presentation-time`, `xdg-output`, `xdg-decoration`, `cursor-shape`,
  `fractional-scale`, `pointer-gestures`, `wlr-layer-shell-v1` and
  `wlr-screencopy-v1`, plus whatever else you point the generator at
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
* a real window: `examples/window` opens an xdg-shell toplevel, follows its
  configure events and animates it from a frame loop until it is closed or
  Escape is pressed
* layer shell: `examples/layer_shell` gives a surface the `zwlr_layer_surface_v1`
  role, anchors it to the top edge of the output and maps it after the
  configure/ack handshake
* keyboard input: seat capabilities, `wl_keyboard` key events as raw evdev key
  codes with names for the common ones, and `read_keymap()` for the xkb keymap
  the compositor sends as a file descriptor
* pointer input: `Pointer` keeps the position, the buttons and the serial the
  grabs need, hands out the motion and the scroll of a frame, and sets a cursor
  image; `examples/window` drags itself with the left button and changes speed
  when scrolled

What is not here yet:

* the server side (implementing a compositor), and protocol *helpers* above the
  generated layer: a reusable window type, and the rest of the input side
  (touch, clipboard, cursor themes - the cursor is an image you draw, since
  reading the Xcursor files of a theme is a file format of its own)
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
v run examples/outputs            # wl_output plus xdg-output: logical position, mode, scale
v run examples/seat                # bind a seat and print its events
v run examples/window              # a window: close it, press Escape, drag it, scroll
v run examples/window -- --frames 60   # present 60 frames, then exit
v run examples/layer_shell         # a top panel: anchored, with an exclusive zone
v run examples/layer_shell -- --frames 120   # draw 120 frames, then exit
v test .                           # unit, generator and end to end tests
```

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

**Fixed point.** Coordinates and scroll distances travel as 24.8 fixed point:
256 counts per unit, signed. Generated listeners and requests work with plain
`f64` values - the decoder divides, and a request multiplies through
`Fixed.new()`, the equivalent of `wl_fixed_from_double()` - so application code
never sees the encoding. `Fixed` itself is the raw value, for the cases where a
protocol wants it as it is.

**Version negotiation.** `bind_<iface>()` binds `min(global.version,
interface.version)`, so a client never asks for more than the compositor
supports, and `bind_global()` refuses a version the compositor did not
advertise.

**Events you do not decode.** Objects registered with `opaque_iface` (for
example a global whose protocol module you did not generate) drop their events
instead of failing, so a partial protocol set keeps working.
