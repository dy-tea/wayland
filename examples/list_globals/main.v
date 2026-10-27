module main

import wayland

// Lists every global the running compositor advertises.
//
//	v run examples/list_globals
fn main() {
	mut conn := wayland.connect()!
	defer {
		conn.close()
	}
	globals := conn.globals()!
	println('compositor advertises ${globals.len} globals:')
	for g in globals {
		println('  ${g.interface} v${g.version}  (name ${g.name})')
	}
}
