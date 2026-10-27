# wayland

A Wayland client library for [V](https://vlang.io), written in pure V.

* **No libwayland.** The wire protocol, the object id table, version negotiation and event dispatch are implemented here, in V.
* **No C glue** beyond the socket calls that carry file descriptors. The only  file that talks to the C library is `transport.v`, and everything it exposes is wrapped in safe helpers.
* **No `unsafe` in the API you use.** Marshalling, listening, id bookkeeping and file descriptor passing are all handled by the library.
* **Generated from the protocol XML.** Interfaces, requests, events, enums, listeners and version negotiation are generated from the official XML files, so adding a protocol is one command. Generated code is `v fmt` clean.

```v
import wayland
import wayland.protocols.wayland

struct SeatListener {
mut:
	capabilities u32
	name         string
}

fn (mut listener SeatListener) capabilities(proxy wayland.WlSeat, capabilities u32) {
	listener.capabilities = capabilities
}

fn (mut listener SeatListener) name(proxy wayland.WlSeat, name string) {
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
	mut seat := wayland.bind_wl_seat(conn, seat_global)!
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

What is not here yet:

* the server side (implementing a compositor), and protocol *helpers* above the
  generated layer: a `Window` type, an shm buffer allocator, clipboard helpers
* an event loop: the application owns its main loop. Use `dispatch_pending()`
  with `Connection.fd` in your own poll/select, or `roundtrip()` for a blocking
  client
* multi-threaded use of one `Connection`: a connection is used from one thread
  at a time

## Running the examples and tests

```sh
v run examples/list_globals        # every global the compositor advertises
v run examples/seat                # bind a seat and print its events
v test .                           # unit, generator and end to end tests
```

The tests in `live_compositor_test.v` talk to the running compositor and are
skipped when there is no Wayland session.

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
* [`gen/emit.v`](gen/emit.v) — what a generated module looks like, and why
* [`examples/seat`](examples/seat) — listeners end to end

## Protocol files and license

`protocols/xml` contains the protocol descriptions (the core `wayland.xml` and
the stable wayland-protocols files), each under its original license and
copyright, kept unchanged from the upstream releases. The generated modules in
`protocols/*` derive from those files.
