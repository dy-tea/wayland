module main

import os
import time
import wayland
import wayland.protocols.ext_idle_notify_v1 as idle
import wayland.protocols.wayland as wl

// Watches a seat and prints when the user goes idle and comes back.
//
//	v run examples/idle_notify
//	v run examples/idle_notify -- --timeout 1000   # fire after one second
//
// ext-idle-notify-v1 is the compositor's idle detection as a protocol: the
// client asks for a notification with a timeout in milliseconds, and the
// compositor answers with idled when the seat has been inactive for that
// long and with resumed when the user came back. Nothing is needed from the
// client in between - in particular there is no surface and no frame loop,
// which makes this the smallest program that receives events from the
// compositor for more than a roundtrip.
//
// The idle state belongs to the compositor, not to the client: it turns on
// screen blanking, keyboard grab policies and notification suppression when
// it decides to, and idle inhibitors (idle-inhibit-v1) ask it not to. A
// client that only wants to know asks here.
//
// Version 2 of the protocol added get_input_idle_notification(), which
// ignores internal idleness and only watches input devices; the manager is
// bound at the version the compositor advertised, and both requests are
// available.

const usage = 'usage: v run examples/idle_notify [--timeout <msec>]'

// idle_timeout reads the optional --timeout option, in milliseconds.
fn idle_timeout() u32 {
	args := os.args[1..]
	mut index := 0
	for index < args.len {
		match args[index] {
			'--' {}
			'--timeout' {
				if index + 1 >= args.len {
					eprintln('--timeout needs a number of milliseconds')
					exit(2)
				}
				value := args[index + 1]
				if !value.is_int() || value.int() < 0 {
					eprintln('--timeout needs a number of milliseconds, got ${value}')
					exit(2)
				}
				return u32(value.int())
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
	return 5000
}

// IdleListener prints the transitions; the elapsed time needs the start.
struct IdleListener {
	start i64
}

fn (mut listener IdleListener) idled(_ idle.ExtIdleNotificationV1) {
	println('[+${elapsed(listener.start):.1f}s] the user went idle')
}

fn (mut listener IdleListener) resumed(_ idle.ExtIdleNotificationV1) {
	println('[+${elapsed(listener.start):.1f}s] the user came back')
}

// elapsed is the time since the program started, in seconds.
fn elapsed(start i64) f64 {
	return f64(time.ticks() - start) / 1000.0
}

fn main() {
	timeout := idle_timeout()
	start := time.ticks()
	mut conn := wayland.connect()!
	defer {
		conn.close()
	}
	globals := conn.globals()!
	seat_global := globals.find('wl_seat') or {
		eprintln('this compositor does not advertise wl_seat')
		return
	}
	manager_global := globals.find('ext_idle_notifier_v1') or {
		eprintln('this compositor does not speak ext-idle-notify-v1')
		return
	}
	seat := wl.bind_wl_seat(conn, seat_global)!
	manager := idle.bind_ext_idle_notifier_v1(conn, manager_global)!

	// The notification fires once per transition: idled, then resumed, then
	// idled again. The listener prints, and the program keeps dispatching
	// until it is interrupted.
	mut notification := manager.get_idle_notification(timeout, seat)!
	mut listener := IdleListener{
		start: start
	}
	notification.set_listener(&listener)!
	println('idle_notify: watching the seat, ${timeout} ms timeout - press Ctrl-C to quit')
	for {
		conn.dispatch()!
	}
}
