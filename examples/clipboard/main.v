module main

import os
import wayland
import wayland.protocols.wayland as wl
import wayland.protocols.wlr_data_control_unstable_v1 as data_control

// Watches the clipboard and the primary selection, prints their MIME types
// and dumps the text they carry - or puts text on the clipboard.
//
//	v run examples/clipboard                  # watch both selections
//	v run examples/clipboard -- --set hello   # put 'hello' on the clipboard
//
// wlr-data-control-v1 is the privileged protocol behind clipboard managers
// and clipboard commands (wl-copy, wl-paste). Every seat gets one
// zwlr_data_control_device_v1, which announces the selections as offers: a
// data_offer event introduces the offer object, one offer event per MIME
// type describes what it carries, and the selection or primary_selection
// event completes it - all three in one batch, so the MIME types are known
// by the time the main loop sees the selection.
//
// The data itself never travels through the compositor. An offer.receive
// names a MIME type and hands over one end of a pipe; the compositor passes
// that end to the client that owns the data, which writes into it and
// closes it, and the receiver reads the other end until EOF. The example
// receives through os.pipe(), which is the same file descriptor passing the
// wl_shm pool creation uses - only in the other direction.
//
// With --set the example becomes the source side: it creates a data source,
// offers the text MIME types and hands the source to set_selection. From
// then on the compositor answers paste requests by sending the send event
// with a descriptor to write into. A selection source stays alive for as
// long as it is the selection, so the program keeps running until another
// selection replaces it (the cancelled event) - Ctrl-C leaves the text on
// the clipboard either way.

// text_mimes lists the MIME types this example reads, in order of
// preference. Every toolkit offers the first; UTF8_STRING is the X11 name
// some older clients still use.
const text_mimes = ['text/plain;charset=utf-8', 'text/plain', 'UTF8_STRING']

const usage = 'usage: v run examples/clipboard [--set <text>]'

// State is what the listeners report back to the main loop, plus the text
// that --set hands out.
struct State {
mut:
	// offers maps an offer object id to the MIME types it announced. The
	// map is how an offer and its types find each other: the data_offer
	// event introduces the object, the offer events on it name the types.
	offers map[u32][]string
	// selection_arrived and primary_arrived are set by the device events;
	// selection_offer and primary_offer carry the new offer, or nothing
	// when the selection was cleared.
	selection_arrived bool
	selection_offer   ?data_control.ZwlrDataControlOfferV1
	primary_arrived   bool
	primary_offer     ?data_control.ZwlrDataControlOfferV1
	// text is what --set hands out.
	text string
	// done is set when the data source was replaced and --set is over.
	done bool
}

// DeviceListener follows the selections of the seat.
struct DeviceListener {
mut:
	state &State
}

fn (mut listener DeviceListener) data_offer(_ data_control.ZwlrDataControlDeviceV1, offer data_control.ZwlrDataControlOfferV1) {
	// The types of the offer arrive as offer events before the selection
	// that uses it; give the object a listener to catch them.
	listener.state.offers[offer.id] = []
	offer.set_listener(&OfferListener{
		state: listener.state
	}) or {
		eprintln('clipboard: could not listen to an offer: ${err.msg()}')
	}
}

fn (mut listener DeviceListener) selection(_ data_control.ZwlrDataControlDeviceV1, offer ?data_control.ZwlrDataControlOfferV1) {
	// The offer of the previous selection is dead protocol matter: the
	// protocol asks the client to destroy it as soon as the new one arrives.
	if mut old := listener.state.selection_offer {
		old.destroy() or {}
	}
	listener.state.selection_arrived = true
	listener.state.selection_offer = offer
}

fn (mut listener DeviceListener) primary_selection(_ data_control.ZwlrDataControlDeviceV1, offer ?data_control.ZwlrDataControlOfferV1) {
	if mut old := listener.state.primary_offer {
		old.destroy() or {}
	}
	listener.state.primary_arrived = true
	listener.state.primary_offer = offer
}

fn (mut listener DeviceListener) finished(_ data_control.ZwlrDataControlDeviceV1) {
	eprintln('clipboard: the compositor retired this data device')
	listener.state.done = true
}

// OfferListener collects the MIME types of one offer.
struct OfferListener {
mut:
	state &State
}

fn (mut listener OfferListener) offer(proxy data_control.ZwlrDataControlOfferV1, mime_type string) {
	listener.state.offers[proxy.id] << mime_type
}

// SourceListener answers the paste requests for the --set text.
struct SourceListener {
mut:
	state &State
}

fn (mut listener SourceListener) send(_ data_control.ZwlrDataControlSourceV1, _mime_type string, fd int) {
	// The descriptor is ours to write and to close; the reading end is held
	// by whoever pasted.
	os.fd_write(fd, listener.state.text)
	os.fd_close(fd)
	println('clipboard: handed ${listener.state.text.len} bytes to a reader')
}

fn (mut listener SourceListener) cancelled(_ data_control.ZwlrDataControlSourceV1) {
	// Another selection took our place; the source is dead, and with it the
	// reason to keep running.
	listener.state.done = true
}

// pick_text_mime returns the first offered type this example can read.
fn pick_text_mime(mimes []string) ?string {
	for wanted in text_mimes {
		if wanted in mimes {
			return wanted
		}
	}
	return none
}

// dump_selection prints one selection: its MIME types, and the text it
// carries when there is any.
fn dump_selection(label string, state &State, offer data_control.ZwlrDataControlOfferV1, conn &wayland.Connection) {
	mimes := state.offers[offer.id]
	println('${label}: ${mimes.join(', ')}')
	mime := pick_text_mime(mimes) or { return }

	// The offer answers with the bytes of the MIME type on the descriptor
	// handed to receive: one end of a pipe. The write end travels to the
	// source through the compositor, so the client closes its own copy
	// before reading - otherwise the reader never sees EOF. The close has to
	// wait until after flush(): the descriptor is copied into the outgoing
	// message at sendmsg time, not when receive() queues the request, so
	// closing first would hand the compositor a closed descriptor and end
	// the transfer with a protocol error. A source that died between copying
	// and pasting leaves a broken pipe, which ends the transfer with
	// whatever arrived.
	mut pipe := os.pipe() or {
		eprintln('${label}: could not create a pipe: ${err.msg()}')
		return
	}
	offer.receive(mime, pipe.write_fd) or {
		eprintln('${label}: could not ask for ${mime}: ${err.msg()}')
		pipe.close()
		return
	}
	conn.flush() or {
		pipe.close()
		return
	}
	os.fd_close(pipe.write_fd)
	pipe.write_fd = -1
	mut text := ''
	for {
		chunk, read := os.fd_read(pipe.read_fd, 4096)
		if read <= 0 {
			break
		}
		text += chunk
	}
	pipe.close()
	if text.ends_with('\n') {
		text = text[..text.len - 1]
	}
	println('${label}: "${text}"')
}

fn main() {
	mut text := ''
	mut set := false
	args := os.args[1..]
	mut index := 0
	for index < args.len {
		match args[index] {
			'--' {}
			'--set' {
				if index + 1 >= args.len {
					eprintln('--set needs text')
					exit(2)
				}
				text = args[index + 1]
				set = true
				index++
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
	mut conn := wayland.connect()!
	defer {
		conn.close()
	}
	globals := conn.globals()!
	seat_global := globals.find('wl_seat') or {
		eprintln('this compositor does not advertise wl_seat')
		return
	}
	manager_global := globals.find('zwlr_data_control_manager_v1') or {
		eprintln('this compositor does not speak wlr-data-control-v1')
		return
	}
	seat := wl.bind_wl_seat(conn, seat_global)!
	manager := data_control.bind_zwlr_data_control_manager_v1(conn, manager_global)!
	device := manager.get_data_device(seat)!

	mut state := State{
		text: text
	}
	mut device_listener := DeviceListener{
		state: &state
	}
	device.set_listener(&device_listener)!

	if set {
		// The source side: describe what the selection carries, then hand it
		// to the compositor. The send event answers the paste requests.
		source := manager.create_data_source()!
		source.set_listener(&SourceListener{
			state: &state
		})!
		source.offer('text/plain;charset=utf-8')!
		source.offer('text/plain')!
		device.set_selection(source)!
		conn.flush()!
		println('clipboard: "${text}" is on the clipboard; Ctrl-C quits, or keep this open for pastes')
		// From here the program only waits for paste requests and for the
		// replacement of the selection, both of which the source listener
		// reports.
		for !state.done {
			conn.dispatch()!
		}
		return
	}

	// The watcher: the first selection arrives right after the bind, and
	// every copy anywhere in the session announces itself here. The offers
	// are read in the main loop, after the events that describe them have
	// all been dispatched.
	println('clipboard: watching the selections; Ctrl-C quits')
	for !state.done {
		conn.dispatch()!
		if state.selection_arrived {
			state.selection_arrived = false
			if offer := state.selection_offer {
				dump_selection('clipboard', &state, offer, conn)
			} else {
				println('clipboard: cleared')
			}
		}
		if state.primary_arrived {
			state.primary_arrived = false
			if offer := state.primary_offer {
				dump_selection('primary', &state, offer, conn)
			} else {
				println('primary: cleared')
			}
		}
	}
}
