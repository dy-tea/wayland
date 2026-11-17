module main

import os
import wayland
import wayland.protocols.ext_foreign_toplevel_list_v1 as foreign

// Lists the open windows of the session, as the compositor sees them, and
// keeps the list up to date until Ctrl-C.
//
//	v run examples/toplevels           # watch the windows come and go
//	v run examples/toplevels -- --once # print the current list and exit
//
// ext-foreign-toplevel-list-v1 is a read only view of the toplevels: every
// window the compositor shows - mapped or not, from any client, without
// needing anything privileged - arrives as a `toplevel` event carrying a new
// handle object, and the handle then describes itself with title, app_id and
// a stable identifier, terminated by done. There is no request to list
// anything: binding the manager global is the whole subscription, and the
// initial batch of events arrives right after the bind.
//
// The identifier is the interesting part: unlike title and app_id, which
// change with what a window is called and what it is, it stays the same for
// as long as the toplevel exists. It is what tools use to follow a window
// across title changes, and what ext-transient-seat-v1 hands a seat to.
//
// closed retires a handle; the compositor may also retire the whole list
// with finished, which ends the example.

const usage = 'usage: v run examples/toplevels [--once]'

// State is what the listeners report back to the main loop.
struct State {
mut:
	// windows maps a handle object id to what it has said so far. The map is
	// how a handle finds its row between events, exactly like the offers of
	// the clipboard example; the values are references, so an event can fill
	// in a field of its window directly.
	windows map[u32]&Window
	// finished is set when the compositor retired the whole list.
	finished bool
}

// Window collects the facts of one toplevel until its done arrives.
struct Window {
mut:
	title      string
	app_id     string
	identifier string
}

// ListListener introduces the handles as they arrive.
struct ListListener {
mut:
	state &State
}

fn (mut listener ListListener) toplevel(_ foreign.ExtForeignToplevelListV1, handle foreign.ExtForeignToplevelHandleV1) {
	listener.state.windows[handle.id] = &Window{}
	handle.set_listener(&HandleListener{
		state: listener.state
	}) or {
		eprintln('toplevels: could not listen to a handle: ${err.msg()}')
	}
}

fn (mut listener ListListener) finished(_ foreign.ExtForeignToplevelListV1) {
	// The list is gone - usually because the compositor shut down or the
	// protocol was removed from under us. Nothing left to watch.
	listener.state.finished = true
}

// HandleListener collects the facts of one toplevel and prints the row when
// the batch is complete.
struct HandleListener {
mut:
	state &State
}

fn (mut listener HandleListener) title(proxy foreign.ExtForeignToplevelHandleV1, title string) {
	mut window := listener.state.windows[proxy.id] or { return }
	window.title = title
}

fn (mut listener HandleListener) app_id(proxy foreign.ExtForeignToplevelHandleV1, app_id string) {
	mut window := listener.state.windows[proxy.id] or { return }
	window.app_id = app_id
}

fn (mut listener HandleListener) identifier(proxy foreign.ExtForeignToplevelHandleV1, identifier string) {
	mut window := listener.state.windows[proxy.id] or { return }
	window.identifier = identifier
}

fn (mut listener HandleListener) done(proxy foreign.ExtForeignToplevelHandleV1) {
	window := listener.state.windows[proxy.id] or { return }
	println('${window.identifier:-38} ${window.app_id:-24} ${window.title}')
}

fn (mut listener HandleListener) closed(proxy foreign.ExtForeignToplevelHandleV1) {
	window := listener.state.windows[proxy.id] or {
		eprintln('toplevels: a window vanished that was never described')
		proxy.destroy() or {}
		return
	}
	println('${window.identifier:-38} ${window.app_id:-24} ${window.title}  [closed]')
	listener.state.windows.delete(proxy.id)
	// The handle is dead protocol matter after closed: destroy it, like the
	// clipboard example destroys a replaced offer.
	proxy.destroy() or {}
}

fn main() {
	mut once := false
	args := os.args[1..]
	for arg in args {
		match arg {
			'--' {}
			'--once' {
				once = true
			}
			'-h', '--help' {
				println(usage)
				exit(0)
			}
			else {
				eprintln('unknown option ${arg}')
				println(usage)
				exit(2)
			}
		}
	}
	mut conn := wayland.connect()!
	defer {
		conn.close()
	}
	globals := conn.globals()!
	list_global := globals.find('ext_foreign_toplevel_list_v1') or {
		eprintln('this compositor does not speak ext-foreign-toplevel-list-v1')
		return
	}

	// Binding the manager is the subscription: the handles arrive as events,
	// there is no request that asks for them.
	list := foreign.bind_ext_foreign_toplevel_list_v1(conn, list_global)!
	mut state := State{}
	list.set_listener(&ListListener{
		state: &state
	})!

	if once {
		// One roundtrip delivers the whole initial batch, done events
		// included, and the rows were printed by the listeners.
		conn.roundtrip()!
		println('${state.windows.len} toplevel(s)')
		return
	}

	println('toplevels: identifier / app_id / title, Ctrl-C quits')
	for !state.finished {
		conn.dispatch()!
	}
	println('toplevels: the compositor retired the list')
}
