module main

import wayland
import wayland.protocols.wayland as wl
import wayland.protocols.xdg_output_unstable_v1 as xdg_output

// Lists the outputs of the compositor, with everything wl_output and
// xdg-output know about each of them.
//
//	v run examples/outputs
//
// wl_output reports the physical facts: mode, position in the layout, physical
// size, subpixel layout and scale. xdg-output reports what a client actually
// positions windows with: the logical position and size, and a stable name and
// description. Both send their properties as a batch, terminated by a done
// event, so the list is printed once every output of this run had its turn.
//
// Both objects live per output global: wl_output is bound from the core
// protocol module, and the zxdg_output_manager_v1 global hands out one
// zxdg_output_v1 per wl_output. The compositor needs the manager global;
// without it, or without any wl_output, the example explains that and exits.

// Output collects the events of one output until its done arrives.
struct Output {
mut:
	// label and summary come from xdg-output. The label is the connector, the
	// "eDP-1", "HDMI-A-2" and friends of /sys.
	label  string
	summary string
	// x, y, logical_width and logical_height are the logical position and size
	// from xdg-output, in compositor coordinates: this is what toplevel
	// windows move in. -1 means "not announced".
	x              i32
	y              i32
	logical_width  i32 = -1
	logical_height i32 = -1
	// mode_width, mode_height and refresh describe the current mode, physical
	// pixels and mHz.
	mode_width  i32
	mode_height i32
	refresh     i32
	preferred   bool
	// scale is the compositor scale from wl_output.scale. The event only
	// exists from wl_output version 2 on, so clients of an older version keep
	// the default of 1.
	scale i32 = 1
	// physical_width and physical_height are the panel size in millimeters,
	// and make, model, subpixel and transform come from wl_output.geometry.
	physical_width  i32
	physical_height i32
	make            string
	model           string
	subpixel        i32
	transform       i32
	// done is set by wl_output.done, which terminates the batch.
	done bool
}

// OutputListener stores the physical facts of wl_output.
struct OutputListener {
mut:
	output &Output
}

fn (mut listener OutputListener) geometry(_ wl.WlOutput, _x i32, _y i32, physical_width i32, physical_height i32, subpixel i32, make string, model string, transform i32) {
	listener.output.physical_width = physical_width
	listener.output.physical_height = physical_height
	listener.output.make = make
	listener.output.model = model
	listener.output.subpixel = subpixel
	listener.output.transform = transform
}

fn (mut listener OutputListener) mode(_ wl.WlOutput, flags u32, width i32, height i32, refresh i32) {
	if flags & wl.wl_output_mode_current == 0 {
		// A compositor may advertise modes it is not using; the current one
		// is what the report is about.
		return
	}
	listener.output.mode_width = width
	listener.output.mode_height = height
	listener.output.refresh = refresh
	listener.output.preferred = flags & wl.wl_output_mode_preferred != 0
}

fn (mut listener OutputListener) done(_ wl.WlOutput) {
	listener.output.done = true
}

fn (mut listener OutputListener) scale(_ wl.WlOutput, factor i32) {
	listener.output.scale = factor
}

// The name and the description events arrived in recent versions of the core
// protocol, but the xdg-output values are what clients match outputs with, so
// they win here: the xdg-output listener receives everything first.

fn (mut listener OutputListener) name(_ wl.WlOutput, _name string) {
}

fn (mut listener OutputListener) description(_ wl.WlOutput, _description string) {
}

// XdgOutputListener stores the logical facts of xdg-output.
struct XdgOutputListener {
mut:
	output &Output
}

fn (mut listener XdgOutputListener) logical_position(_ xdg_output.ZxdgOutputV1, x i32, y i32) {
	listener.output.x = x
	listener.output.y = y
}

fn (mut listener XdgOutputListener) logical_size(_ xdg_output.ZxdgOutputV1, width i32, height i32) {
	listener.output.logical_width = width
	listener.output.logical_height = height
}

fn (mut listener XdgOutputListener) done(_ xdg_output.ZxdgOutputV1) {
	// The done event of xdg-output itself is deprecated since version 3: the
	// wl_output.done terminates the batch now, and that is the one waited for.
}

fn (mut listener XdgOutputListener) name(_ xdg_output.ZxdgOutputV1, name string) {
	listener.output.label = name
}

fn (mut listener XdgOutputListener) description(_ xdg_output.ZxdgOutputV1, description string) {
	listener.output.summary = description
}

fn subpixel_name(subpixel i32) string {
	return match subpixel {
		0 { 'unknown' }
		1 { 'none' }
		2 { 'horizontal rgb' }
		3 { 'horizontal bgr' }
		4 { 'vertical rgb' }
		5 { 'vertical bgr' }
		else { 'subpixel ${subpixel}' }
	}
}

// report prints one collected output.
fn report(output &Output) {
	print('${output.label}')
	if output.summary != '' {
		print(' - ${output.summary}')
	}
	println('')
	if output.logical_width >= 0 {
		println('  logical: ${output.x},${output.y}, ${output.logical_width}x${output.logical_height}')
	}
	if output.mode_width > 0 {
		hz := if output.refresh > 0 { output.refresh / 1000.0 } else { 0.0 }
		preferred := if output.preferred { ', preferred' } else { '' }
		println('  mode: ${output.mode_width}x${output.mode_height}, ${hz:.1f} Hz${preferred}')
	}
	if output.physical_width > 0 {
		println('  panel: ${output.physical_width}x${output.physical_height} mm, ${output.make} ${output.model}')
	}
	println('  scale: ${output.scale}, ${subpixel_name(output.subpixel)}')
	if output.transform != 0 {
		println('  transform: ${output.transform}')
	}
}

fn main() {
	mut conn := wayland.connect()!
	defer {
		conn.close()
	}
	globals := conn.globals()!
	output_globals := globals.find_all('wl_output')
	if output_globals.len == 0 {
		eprintln('this compositor does not advertise any wl_output')
		return
	}
	manager_global := globals.find('zxdg_output_manager_v1') or {
		eprintln('this compositor does not speak xdg-output; running without logical facts')
		return
	}
	mut manager := xdg_output.bind_zxdg_output_manager_v1(conn, manager_global)!

	// One core output and one xdg_output per global, both reporting into the
	// same Output. The listeners are allocated on the heap, where the sinks of
	// the connections can point at them for as long as the connection lives.
	mut outputs := []&Output{}
	mut output_listeners := []&OutputListener{}
	mut xdg_listeners := []&XdgOutputListener{}
	for global in output_globals {
		output := &Output{
			label: 'output ${global.name}'
		}
		proxy := wl.bind_wl_output(conn, global)!
		output_listeners << &OutputListener{
			output: output
		}
		proxy.set_listener(output_listeners.last())!
		xdg := manager.get_xdg_output(proxy) or {
			eprintln('xdg-output: could not describe ${global.name}: ${err.msg()}')
			continue
		}
		xdg_listeners << &XdgOutputListener{
			output: output
		}
		xdg.set_listener(xdg_listeners.last())!
		outputs << output
	}

	// Drain the batches: every output answers with done once it sent
	// everything. A rescheduling compositor could take a few dispatches.
	for {
		conn.dispatch()!
		if outputs.all(it.done) {
			break
		}
	}
	for output in outputs {
		report(output)
	}
}
