module gen

import os

// Tests for the XML parser, the intermediate representation and the emitter.
// They read the protocol XML files vendored in `protocols/xml`, so they also
// guard the build against upstream protocol changes.

fn protocol_path(name string) string {
	return os.join_path(@DIR, '..', 'protocols', 'xml', name)
}

fn find_interface(protocol &Protocol, name string) &Interface {
	for iface in protocol.interfaces {
		if iface.name == name {
			return iface
		}
	}
	panic('protocol ${protocol.name} has no interface ${name}')
}

fn find_message(messages []Message, name string) &Message {
	for message in messages {
		if message.name == name {
			return message
		}
	}
	panic('no message named ${name}')
}

fn find_enum(enums []EnumType, name string) &EnumType {
	for enum_type in enums {
		if enum_type.name == name {
			return enum_type
		}
	}
	panic('no enum named ${name}')
}

fn test_names() {
	assert type_name('wl_surface') == 'WlSurface'
	assert type_name('zwp_linux_dmabuf_v1') == 'ZwpLinuxDmabufV1'
	assert type_name('xdg-shell') == 'XdgShell'
	assert type_name('wl_shm_pool') == 'WlShmPool'
	assert module_name('xdg-shell') == 'xdg_shell'
	assert module_name('presentation-time') == 'presentation_time'
	assert v_ident('interface') == 'interface_'
	assert v_ident('type') == 'type_'
	assert v_ident('conn') == 'conn_'
	assert v_ident('mods_depressed') == 'mods_depressed'
	assert v_ident('90') == 'num_90'
	assert v_ident('') == 'unnamed'
	assert ident_fragment('90') == 'num_90'
	assert ident_fragment('flipped-90') == 'flipped_90'
	assert ident_fragment('bottom_left') == 'bottom_left'
	assert kind_member('string') == 'str'
	assert kind_member('object') == 'obj'
	assert kind_member('array') == 'array'
	assert kind_member('new_id') == 'new_id'
	assert proxy_fn('wl_surface') == 'wl_surface_proxy'
	// Descriptions keep their full text: long text continues on the next
	// comment line instead of being cut off.
	assert comment_lines('one two three') == ['one two three']
	assert comment_lines('multi\nline\ntext') == ['multi line text']
	mut long := ''
	for i in 0 .. 40 {
		long += 'word '
	}
	lines := comment_lines(long)
	assert lines.len > 1
	for line in lines {
		assert line.len <= comment_width
	}
	// The core protocol module is named after the library module, so it gets an
	// alias: a V file cannot import two modules under the same name.
	assert alias_for_module('wayland') == 'wl'
	assert alias_for_module('xdg_shell') == 'xdg_shell'
}

fn test_parse_wayland_xml() {
	protocol := load_protocol(protocol_path('wayland.xml'))!
	assert protocol.name == 'wayland'
	assert protocol.interfaces.len == 23
	assert protocol.copyright.contains('Permission is hereby granted')

	display := find_interface(protocol, 'wl_display')
	assert display.name == 'wl_display'
	// Requests keep their wire order, which is what the opcode is.
	assert display.requests.len == 2
	assert display.requests[0].name == 'sync'
	assert display.requests[0].opcode == 0
	assert display.requests[0].args[0].kind == 'new_id'
	assert display.requests[0].args[0].iface == 'wl_callback'
	assert display.requests[1].name == 'get_registry'
	assert display.requests[1].opcode == 1
	assert display.events[0].name == 'error'
	assert display.events[0].args.len == 3
	assert display.events[1].name == 'delete_id'

	registry := find_interface(protocol, 'wl_registry')
	// The registry has exactly one request on the wire: the XML documents bind
	// with two arguments, the real signature is "usun".
	assert registry.requests.len == 1
	bind := registry.requests[0]
	assert bind.name == 'bind'
	assert bind.args.len == 4
	assert bind.args[0].kind == 'uint'
	assert bind.args[1].kind == 'string'
	assert bind.args[2].kind == 'uint'
	assert bind.args[3].kind == 'new_id'
	assert bind.args[3].iface == ''
	assert !bind.destructor
	// `global` announces name, interface and version: three arguments on the
	// wire, no new_id.
	assert registry.events[0].name == 'global'
	assert registry.events[0].args.len == 3
	assert registry.events[1].name == 'global_remove'

	surface := find_interface(protocol, 'wl_surface')
	assert surface.requests[0].name == 'destroy'
	assert surface.requests[0].destructor
	attach := find_message(surface.requests, 'attach')
	assert attach.args[0].kind == 'object'
	assert attach.args[0].iface == 'wl_buffer'
	// wl_surface.attach takes a nullable buffer.
	assert attach.args[0].nullable
	assert !attach.args[1].nullable
	assert attach.summary != ''

	// Enums keep their entries, including names that are not V identifiers.
	transform := find_enum(find_interface(protocol, 'wl_output').enums, 'transform')
	assert transform.entries.len == 8
	assert transform.entries[0].name == 'normal'
	assert transform.entries[0].value == 0
	assert transform.entries[1].name == '90'
	assert transform.entries[1].value == 1
	assert !transform.bitfield
	surface_error := find_enum(surface.enums, 'error')
	assert surface_error.entries.len == 6
	assert surface_error.entries[0].name == 'invalid_scale'
	capability := find_enum(find_interface(protocol, 'wl_seat').enums, 'capability')
	assert capability.bitfield
	assert capability.entries.len == 3
	assert capability.entries[0].name == 'pointer'
	assert capability.entries[2].name == 'touch'
	assert capability.entries[2].value == 4

	// File descriptors and arrays are recognised.
	keyboard := find_interface(protocol, 'wl_keyboard')
	keymap := find_message(keyboard.events, 'keymap')
	assert keymap.args.len == 3
	assert keymap.args[1].kind == 'fd'
	assert keymap.args[2].kind == 'uint'
	enter := find_message(keyboard.events, 'enter')
	assert enter.args[2].kind == 'array'
}

fn test_parse_xdg_shell_xml() {
	protocol := load_protocol(protocol_path('xdg-shell.xml'))!
	// The protocol name is the one in the XML, which differs from the file name.
	assert protocol.name == 'xdg_shell'
	shell := find_interface(protocol, 'xdg_wm_base')
	assert shell.requests[0].name == 'destroy'
	assert shell.requests[1].name == 'create_positioner'
	assert shell.requests[2].name == 'get_xdg_surface'
	ping := find_message(shell.events, 'ping')
	assert ping.args.len == 1
	assert ping.args[0].kind == 'uint'

	toplevel := find_interface(protocol, 'xdg_toplevel')
	configure := find_message(toplevel.events, 'configure')
	assert configure.args.len == 3
	assert configure.args[0].kind == 'int'
	assert configure.args[2].kind == 'array'
	close := find_message(toplevel.events, 'close')
	assert close.args.len == 0
	// Interface versions are read from the XML.
	assert shell.version >= 1
	assert find_interface(protocol, 'xdg_surface').requests[0].name == 'destroy'
}

fn test_parse_viewporter_and_presentation_time() {
	viewporter := load_protocol(protocol_path('viewporter.xml'))!
	assert viewporter.name == 'viewporter'
	assert find_interface(viewporter, 'wp_viewporter').requests[0].name == 'destroy'
	assert find_interface(viewporter, 'wp_viewport').requests[0].name == 'destroy'

	presentation := load_protocol(protocol_path('presentation-time.xml'))!
	assert presentation.name == 'presentation_time'
	presentation_iface := find_interface(presentation, 'wp_presentation')
	// The supported clock ids are an event here, not an enum.
	assert find_message(presentation_iface.events, 'clock_id').args.len == 1
	assert find_message(presentation_iface.events, 'clock_id').args[0].kind == 'uint'
	presentation_error := find_enum(presentation_iface.enums, 'error')
	assert presentation_error.entries[0].name == 'invalid_timestamp'
	kind := find_enum(find_interface(presentation, 'wp_presentation_feedback').enums, 'kind')
	assert kind.bitfield
	assert kind.entries[0].name == 'vsync'
	assert kind.entries[0].value == 1
}

fn test_emit_wayland_module() {
	protocol := load_protocol(protocol_path('wayland.xml'))!
	source := emit_module(protocol, EmitOptions{})!
	assert source.contains('\nmodule wayland\n')
	assert source.contains('Code generated by wayland-gen')
	// Generated modules always import the library module itself.
	assert source.contains('\nimport wayland\n')
	// Descriptions, proxies, listeners and typed requests.
	assert source.contains('pub const wl_compositor_desc = wayland.IfaceDesc{')
	assert source.contains('pub struct WlSurface {')
	assert source.contains('wayland.Object')
	assert source.contains('pub fn wl_surface_proxy(conn &wayland.Connection, id u32) WlSurface {')
	assert source.contains('pub interface WlSurfaceListener {')
	assert source.contains('pub fn (proxy &WlSurface) attach(buffer ?WlBuffer, x i32, y i32) ! {')
	// wl_registry.bind is special cased to its wire signature.
	assert source.contains('pub fn (proxy &WlRegistry) bind(name u32, interface_ string, version u32) !wayland.Object {')
	assert source.contains('pub fn (proxy &WlSurface) destroy() ! {')
	// Enum constants, sanitised for names that are not V identifiers.
	assert source.contains('pub const wl_output_transform_normal = u32(0)')
	assert source.contains('pub const wl_output_transform_num_90 = u32(1)')
	assert source.contains('pub const wl_seat_capability_keyboard = u32(2)')
	assert source.contains('pub const wl_surface_error_invalid_scale = u32(0)')
	// Global helpers for interfaces the compositor advertises.
	assert source.contains('pub fn bind_wl_compositor(conn &wayland.Connection, global wayland.Global) !WlCompositor {')
	// Every interface in the protocol is emitted once.
	for iface in protocol.interfaces {
		assert source.contains('pub const ${iface.name}_desc = wayland.IfaceDesc{')
	}
}

fn test_emit_fixed_point_arguments() {
	// Fixed point arguments need the 24.8 conversion on both sides, and the
	// emitted code has to ask for it: V widens a `Fixed` to the f64 of an event
	// method without complaining, and it refuses an f64 where a request wants a
	// `Fixed`, so a missing conversion is either wrong at run time or does not
	// compile at all.
	wayland := load_protocol(protocol_path('wayland.xml'))!
	source := emit_module(&wayland, EmitOptions{})!
	assert source.contains('surface_x := msg.arg_fixed(0)!.f64()') // wl_pointer.warp
	assert source.contains('value_ := msg.arg_fixed(2)!.f64()') // wl_pointer.axis
	viewporter := load_protocol(protocol_path('viewporter.xml'))!
	viewport_source := emit_module(&viewporter, EmitOptions{})!
	assert viewport_source.contains('wayland.ArgValue(wayland.Fixed.new(x))')
	assert viewport_source.contains('wayland.ArgValue(wayland.Fixed.new(height))')
}

fn test_emit_uses_externs_for_other_protocols() {
	wayland := load_protocol(protocol_path('wayland.xml'))!
	xdg := load_protocol(protocol_path('xdg-shell.xml'))!
	externs := externs_for([&wayland, &xdg], 'wayland.protocols', 'xdg_shell')
	source := emit_module(&xdg, EmitOptions{
		externs: externs
	})!
	// The core protocol's module name collides with the library module, so the
	// import carries an alias.
	assert source.contains('import wayland.protocols.wayland as wl')
	// Types from other protocols are referenced through their module.
	assert source.contains('wl.WlSurface')
	// The library module itself is imported under its own name.
	assert source.contains('\nimport wayland\n')
	// Without externs the same argument degrades to an opaque object.
	plain := emit_module(&xdg, EmitOptions{})!
	assert plain.contains('wayland.Object')
	assert !plain.contains('wayland.WlSurface')
}

fn test_every_vendored_protocol_generates() {
	files := protocol_files([os.join_path(@DIR, '..', 'protocols', 'xml')])!
	assert files.len >= 5
	for file in files {
		protocol := load_protocol(file)!
		assert protocol.interfaces.len > 0
		source := emit_module(protocol, EmitOptions{})!
		assert source.contains('module ${module_name(protocol.name)}')
	}
}

fn test_parse_xml_handles_entities() {
	nodes := parse_xml('<?xml version="1.0"?><a x="1 &amp; 2" y="&lt;b&gt;">less than: &lt;5&quot;</a>', 'inline')!
	assert nodes.len == 1
	assert nodes[0].name == 'a'
	assert nodes[0].attr('x') == '1 & 2'
	assert nodes[0].attr('y') == '<b>'
	assert nodes[0].has_attr('x')
	assert !nodes[0].has_attr('z')
	assert nodes[0].text.contains('less than: <5"')
	assert nodes[0].find_all('b').len == 0
}

fn test_parse_xml_reports_errors() {
	if _ := parse_xml('<protocol><interface name="x">', 'broken') {
		assert false, 'unclosed elements must be reported'
	} else {
		assert err.msg().contains('broken')
	}
}

fn test_parse_wlr_layer_shell_xml() {
	protocol := load_protocol(protocol_path('wlr-layer-shell-unstable-v1.xml'))!
	assert protocol.name == 'wlr_layer_shell_unstable_v1'
	assert protocol.interfaces.len == 2

	shell := find_interface(protocol, 'zwlr_layer_shell_v1')
	assert shell.version == 5
	get_layer_surface := find_message(shell.requests, 'get_layer_surface')
	assert get_layer_surface.opcode == 0
	assert get_layer_surface.args.len == 5
	assert get_layer_surface.args[0].kind == 'new_id'
	assert get_layer_surface.args[0].iface == 'zwlr_layer_surface_v1'
	assert get_layer_surface.args[1].kind == 'object'
	assert get_layer_surface.args[1].iface == 'wl_surface'
	// The output is optional: a client may let the compositor pick one.
	assert get_layer_surface.args[2].iface == 'wl_output'
	assert get_layer_surface.args[2].nullable
	assert get_layer_surface.args[3].kind == 'uint'
	assert get_layer_surface.args[3].enum_name == 'layer'
	assert get_layer_surface.args[4].kind == 'string'
	destroy := find_message(shell.requests, 'destroy')
	assert destroy.destructor
	assert destroy.since == 3
	layer := find_enum(shell.enums, 'layer')
	assert !layer.bitfield
	assert layer.entries.len == 4
	assert layer.entries[2].name == 'top'
	assert layer.entries[2].value == 2

	surface := find_interface(protocol, 'zwlr_layer_surface_v1')
	assert surface.version == 5
	configure := find_message(surface.events, 'configure')
	assert configure.opcode == 0
	assert configure.args.len == 3
	assert configure.args[0].kind == 'uint'
	assert configure.args[1].kind == 'uint'
	assert configure.args[2].kind == 'uint'
	assert find_message(surface.events, 'closed').opcode == 1
	anchor := find_enum(surface.enums, 'anchor')
	assert anchor.bitfield
	assert anchor.entries.len == 4
	assert anchor.entries[0].name == 'top'
	assert anchor.entries[0].value == 1
	assert anchor.entries[3].value == 8
	assert find_message(surface.requests, 'set_layer').since == 2
	assert find_message(surface.requests, 'set_exclusive_edge').since == 5
	assert find_message(surface.requests, 'get_popup').args[0].iface == 'xdg_popup'
}

fn test_emit_wlr_layer_shell_module() {
	wayland := load_protocol(protocol_path('wayland.xml'))!
	xdg := load_protocol(protocol_path('xdg-shell.xml'))!
	layer := load_protocol(protocol_path('wlr-layer-shell-unstable-v1.xml'))!
	externs := externs_for([&wayland, &xdg, &layer], 'wayland.protocols',
		'wlr_layer_shell_unstable_v1')
	source := emit_module(&layer, EmitOptions{
		externs: externs
	})!
	// The interfaces of the other protocols are typed, including the nullable
	// output and the xdg_popup parent of get_popup.
	assert source.contains('pub fn (proxy &ZwlrLayerShellV1) get_layer_surface(surface wl.WlSurface, output ?wl.WlOutput, layer u32, namespace string) !ZwlrLayerSurfaceV1 {')
	assert source.contains('pub fn (proxy &ZwlrLayerSurfaceV1) get_popup(popup xdg_shell.XdgPopup) ! {')
	// Only the shell is a global: the surface role is created by get_layer_surface.
	assert source.contains('pub fn bind_zwlr_layer_shell_v1(conn &wayland.Connection, global wayland.Global) !ZwlrLayerShellV1 {')
	assert !source.contains('pub fn bind_zwlr_layer_surface_v1(')
}

fn test_parse_xdg_output_and_decoration() {
	xdg_output := load_protocol(protocol_path('xdg-output-unstable-v1.xml'))!
	assert xdg_output.name == 'xdg_output_unstable_v1'
	assert find_interface(xdg_output, 'zxdg_output_manager_v1').version == 3
	assert find_message(find_interface(xdg_output, 'zxdg_output_manager_v1').requests, 'get_xdg_output').args[0].kind == 'new_id'
	assert find_interface(xdg_output, 'zxdg_output_v1').version == 3

	decoration := load_protocol(protocol_path('xdg-decoration-unstable-v1.xml'))!
	assert decoration.name == 'xdg_decoration_unstable_v1'
	assert find_message(find_interface(decoration, 'zxdg_decoration_manager_v1').requests, 'get_toplevel_decoration').args[1].iface == 'xdg_toplevel'
	assert find_message(find_interface(decoration, 'zxdg_toplevel_decoration_v1').events, 'configure').args[0].kind == 'uint'
}

fn test_parse_pointer_gestures_and_fractional_scale() {
	gestures := load_protocol(protocol_path('pointer-gestures-unstable-v1.xml'))!
	assert gestures.name == 'pointer_gestures_unstable_v1'
	assert find_interface(gestures, 'zwp_pointer_gesture_swipe_v1').version == 3
	assert find_message(find_interface(gestures, 'zwp_pointer_gesture_pinch_v1').events, 'update').args[2].kind == 'fixed'

	fractional := load_protocol(protocol_path('fractional-scale-v1.xml'))!
	assert fractional.name == 'fractional_scale_v1'
	assert find_interface(fractional, 'wp_fractional_scale_manager_v1').version == 1
	assert find_message(find_interface(fractional, 'wp_fractional_scale_v1').events, 'preferred_scale').args[0].kind == 'uint'
}

fn test_parse_cursor_shape_and_screencopy() {
	cursor := load_protocol(protocol_path('cursor-shape-v1.xml'))!
	assert cursor.name == 'cursor_shape_v1'
	assert find_interface(cursor, 'wp_cursor_shape_manager_v1').version == 2
	assert find_interface(cursor, 'wp_cursor_shape_device_v1').version == 2

	screencopy := load_protocol(protocol_path('wlr-screencopy-unstable-v1.xml'))!
	assert screencopy.name == 'wlr_screencopy_unstable_v1'
	assert find_interface(screencopy, 'zwlr_screencopy_manager_v1').version == 3
	assert find_message(find_interface(screencopy, 'zwlr_screencopy_frame_v1').events, 'buffer').args[0].kind == 'uint'
	assert find_message(find_interface(screencopy, 'zwlr_screencopy_frame_v1').requests, 'copy').args[0].kind == 'object'
}
