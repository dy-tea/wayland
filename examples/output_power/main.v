module main

import os
import wayland
import wayland.protocols.wayland as wl
import wayland.protocols.wlr_output_power_management_unstable_v1 as power

// Reports - and optionally changes - the DPMS power state of every output.
//
//	v run examples/output_power            # what is on, what is off
//	v run examples/output_power -- --off   # blank every output
//	v run examples/output_power -- --on    # wake every output
//
// wlr-output-power-management-v1 lets a client switch an output between on
// and off the way the power daemon does, per wl_output. Each control object
// answers with its mode event as soon as it is created, so a plain report
// needs nothing but a bind and a roundtrip; a set_mode is confirmed by a
// second mode event, which the report prints when it arrives.
//
// The control is exclusive: a compositor hands it out to one client at a
// time, and reports failed to everyone else - a running swayidle or a
// laptop's power manager may hold it, in which case this program says so and
// goes on with the outputs it did get.
//
// An output that is switched off comes back as soon as the user touches
// input: the compositor turns it on and says so through the same event.

const usage = 'usage: v run examples/output_power [--on | --off]'

// requested_mode parses the optional mode flag; -1 means "only report".
fn requested_mode() int {
	args := os.args[1..]
	mut index := 0
	mut mode := -1
	for index < args.len {
		match args[index] {
			'--' {}
			'--on' {
				if mode >= 0 {
					eprintln('--on and --off cannot be combined')
					exit(2)
				}
				mode = int(power.zwlr_output_power_v1_mode_on)
			}
			'--off' {
				if mode >= 0 {
					eprintln('--on and --off cannot be combined')
					exit(2)
				}
				mode = int(power.zwlr_output_power_v1_mode_off)
			}
			'-h', '--help' {
				println(usage)
				exit(0)
			}
			else {
				eprintln('unknown option ${args[index]}')
				println(usage)
				exit(2)
			}
		}
		index++
	}
	return mode
}

// Output collects the facts of one output: the label from wl_output.name,
// and whether its power control was refused.
struct Output {
mut:
	// label is the connector name, the "DP-1" of /sys, when wl_output is
	// recent enough to send names; the global's ordinal otherwise.
	label string
	// failed is set when the compositor refused the control for this output,
	// which happens when another client already holds it. A control that
	// failed is inert: it takes no more requests.
	failed bool
}

// OutputListener stores the label of the wl_output.
struct OutputListener {
mut:
	output &Output
}

fn (mut listener OutputListener) geometry(_ wl.WlOutput, _ i32, _ i32, _ i32, _ i32, _ i32, _ string, _ string, _ i32) {
}

fn (mut listener OutputListener) mode(_ wl.WlOutput, _ u32, _ i32, _ i32, _ i32) {
}

fn (mut listener OutputListener) done(_ wl.WlOutput) {
}

fn (mut listener OutputListener) scale(_ wl.WlOutput, _ i32) {
}

fn (mut listener OutputListener) name(_ wl.WlOutput, name string) {
	listener.output.label = name
}

fn (mut listener OutputListener) description(_ wl.WlOutput, _ string) {
}

// PowerListener stores the power state of one control object.
struct PowerListener {
mut:
	output &Output
}

fn (mut listener PowerListener) mode(_ power.ZwlrOutputPowerV1, mode u32) {
	println('${listener.output.label}: ${mode_name(mode)}')
}

fn (mut listener PowerListener) failed(_ power.ZwlrOutputPowerV1) {
	listener.output.failed = true
	println('${listener.output.label}: the compositor refused power control (is another client holding it?)')
}

fn mode_name(mode u32) string {
	return match mode {
		power.zwlr_output_power_v1_mode_off { 'off' }
		power.zwlr_output_power_v1_mode_on { 'on' }
		else { 'mode ${mode}' }
	}
}

fn main() {
	mode := requested_mode()
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
	manager_global := globals.find('zwlr_output_power_manager_v1') or {
		eprintln('this compositor does not speak wlr-output-power-management-v1')
		return
	}
	manager := power.bind_zwlr_output_power_manager_v1(conn, manager_global)!

	// One wl_output and one power control per output, both reporting into the
	// same Output. The listeners are allocated on the heap, where the sinks
	// of the connection can point at them for as long as the connection
	// lives.
	mut outputs := []&Output{}
	mut output_listeners := []&OutputListener{}
	mut proxies := []wl.WlOutput{}
	for global in output_globals {
		output := &Output{
			label: 'output ${global.name}'
		}
		proxy := wl.bind_wl_output(conn, global)!
		output_listeners << &OutputListener{
			output: output
		}
		proxy.set_listener(output_listeners.last())!
		proxies << proxy
		outputs << output
	}
	// The connector names arrive as events on bind; one roundtrip drains them.
	conn.roundtrip()!

	// The controls answer with their mode event as soon as they are created,
	// and the listener prints the report from it: a plain run is a bind and
	// two roundtrips.
	mut controls := []power.ZwlrOutputPowerV1{}
	mut power_listeners := []&PowerListener{}
	for i, proxy in proxies {
		control := manager.get_output_power(proxy)!
		power_listeners << &PowerListener{
			output: outputs[i]
		}
		control.set_listener(power_listeners.last())!
		controls << control
	}
	conn.roundtrip()!

	if mode < 0 {
		return
	}

	// The requested mode goes to every control; each one confirms with its
	// own mode event, which the listener prints. The roundtrips below wait
	// for the confirmations; a compositor that is busy rescheduling might
	// need another one.
	requested := u32(mode)
	println('output_power: switching every output to ${mode_name(requested)}')
	for i, control in controls {
		if outputs[i].failed {
			continue
		}
		control.set_mode(requested) or {
			eprintln('output_power: ${err.msg()}')
			continue
		}
	}
	conn.roundtrip()!
	conn.roundtrip()!
}
