module gen

import strings

// Turns a protocol description into V source.
//
// The generated module contains, for every interface:
//
//   * an `IfaceDesc` constant describing the wire layout
//   * a proxy struct embedding `wayland.Object`
//   * a `<Name>Listener` interface plus a no-op implementation
//   * a typed `set_listener` method
//   * one method per request, with typed arguments and return values
//   * a sink that decodes events and calls the listener
//   * named constants for the protocol enums
//
// and, for interfaces the compositor advertises as globals, a `bind_*` helper.

// ExternIface locates an interface that is referenced but not defined by the
// protocol being generated.
pub struct ExternIface {
pub:
	// module is the name the module is referenced by, which differs from its
	// import path when it needs an alias (see `alias_for_module`).
	module string
	// path is the full import path.
	path string
}

// EmitOptions configures one generated module.
pub struct EmitOptions {
pub mut:
	// module_name overrides the module name derived from the protocol name.
	module_name string
	// externs maps referenced interface names to where they are defined.
	externs map[string]ExternIface = {}
}

// emit_module generates the V source of a protocol module.
pub fn emit_module(protocol &Protocol, options EmitOptions) !string {
	mut emitter := Emitter{
		protocol: protocol
		module:   if options.module_name != '' {
			options.module_name
		} else {
			module_name(protocol.name)
		}
		externs:  options.externs
		locals:   map[string]bool{}
		imports:  map[string]string{}
	}
	for iface in protocol.interfaces {
		if emitter.locals[iface.name] {
			return error('protocol ${protocol.name} defines interface ${iface.name} twice')
		}
		emitter.locals[iface.name] = true
	}
	for iface in protocol.interfaces {
		emitter.emit_interface(iface)
	}
	for iface in emitter.global_interfaces() {
		emitter.emit_binder(iface)
	}
	return emitter.assemble()
}

// Emitter accumulates the generated body and the imports it needs.
struct Emitter {
mut:
	body     strings.Builder
	protocol &Protocol
	module   string
	externs  map[string]ExternIface
	locals   map[string]bool
	imports  map[string]string
	missing  []string
}

fn (mut e Emitter) line(text string) {
	e.body.writeln(text)
}

fn (mut e Emitter) blank() {
	e.body.writeln('')
}

// --- type resolution --------------------------------------------------------

fn (mut e Emitter) is_typed(iface string) bool {
	if iface == '' {
		return false
	}
	return e.locals[iface] || iface in e.externs
}

// type_for returns the V type name to use for a referenced interface.
fn (mut e Emitter) type_for(iface string) string {
	if e.locals[iface] {
		return type_name(iface)
	}
	if external := e.externs[iface] {
		e.imports[external.module] = external.path
		return '${external.module}.${type_name(iface)}'
	}
	if iface !in e.missing {
		e.missing << iface
	}
	return '${root_module}.Object'
}

// desc_for returns an expression yielding the descriptor of an interface.
fn (mut e Emitter) desc_for(iface string) string {
	if e.locals[iface] {
		return '&${iface}_desc'
	}
	if external := e.externs[iface] {
		e.imports[external.module] = external.path
		return '&${external.module}.${iface}_desc'
	}
	if iface != '' && iface !in e.missing {
		e.missing << iface
	}
	return '&${root_module}.opaque_iface'
}

// proxy_for returns an expression building a typed proxy for an object id.
fn (mut e Emitter) proxy_for(iface string, conn string, id string) string {
	if e.locals[iface] {
		return '${proxy_fn(iface)}(${conn}, ${id})'
	}
	if external := e.externs[iface] {
		e.imports[external.module] = external.path
		return '${external.module}.${proxy_fn(iface)}(${conn}, ${id})'
	}
	return "${root_module}.Object{ id: ${id}, conn: ${conn}, iface: '${iface}' }"
}

// qualified_proxy_fn returns the proxy constructor of an interface, qualified
// when it lives in another module.
fn (mut e Emitter) qualified_proxy_fn(iface string) string {
	if e.locals[iface] {
		return proxy_fn(iface)
	}
	if external := e.externs[iface] {
		e.imports[external.module] = external.path
		return '${external.module}.${proxy_fn(iface)}'
	}
	return proxy_fn(iface)
}

// global_interfaces returns the interfaces that look like compositor globals:
// the ones no request or event creates. wl_display is excluded because it is the
// connection itself.
fn (e &Emitter) global_interfaces() []Interface {
	mut created := map[string]bool{}
	for iface in e.protocol.interfaces {
		for request in iface.requests {
			for arg in request.args {
				if arg.kind == 'new_id' && arg.iface != '' {
					created[arg.iface] = true
				}
			}
		}
		for event in iface.events {
			for arg in event.args {
				if arg.kind == 'new_id' && arg.iface != '' {
					created[arg.iface] = true
				}
			}
		}
	}
	mut globals := []Interface{}
	for iface in e.protocol.interfaces {
		if iface.name == 'wl_display' || created[iface.name] {
			continue
		}
		globals << iface
	}
	return globals
}

// --- interface emission -----------------------------------------------------

fn (mut e Emitter) emit_interface(iface &Interface) {
	e.line('// --- ${iface.name} ---')
	e.blank()
	e.emit_descriptor(iface)
	e.emit_proxy(iface)
	if iface.events.len > 0 {
		e.emit_listener(iface)
		e.emit_sink(iface)
	}
	for request in iface.requests {
		e.emit_request(iface, request)
	}
	e.emit_enums(iface)
}

fn (mut e Emitter) emit_descriptor(iface &Interface) {
	e.line('// ${iface.name}_desc is the wire description of ${iface.name}.')
	e.line('pub const ${iface.name}_desc = wayland.IfaceDesc{')
	e.line("\tname:    '${iface.name}'")
	e.line('\tversion: ${iface.version}')
	if iface.requests.len > 0 {
		e.line('\trequests: [')
		for request in iface.requests {
			e.emit_message_description(1, request)
		}
		e.line('\t]')
	}
	if iface.events.len > 0 {
		e.line('\tevents: [')
		for event in iface.events {
			e.emit_message_description(1, event)
		}
		e.line('\t]')
	}
	e.line('}')
	e.blank()
}

fn (mut e Emitter) emit_message_description(depth int, message &Message) {
	pad := '\t'.repeat(depth)
	e.line('${pad}wayland.MsgDesc{')
	e.line("${pad}\tname:   '${message.name}'")
	e.line('${pad}\topcode: ${message.opcode}')
	if message.since > 1 {
		e.line('${pad}\tsince:  ${message.since}')
	}
	if message.destructor {
		e.line('${pad}\tdestructor: true')
	}
	if message.args.len > 0 {
		e.line('${pad}\targs:   [')
		for arg in message.args {
			e.emit_arg_description(depth + 2, arg)
		}
		e.line('${pad}\t]')
	}
	e.line('${pad}},')
}

fn (mut e Emitter) emit_arg_description(depth int, arg &Arg) {
	pad := '\t'.repeat(depth)
	e.line('${pad}wayland.ArgDesc{')
	e.line("${pad}\tname: '${arg.name}'")
	e.line('${pad}\tkind: .${kind_member(arg.kind)}')
	if arg.iface != '' {
		e.line("${pad}\tiface: '${arg.iface}'")
	}
	if arg.nullable {
		e.line('${pad}\tnullable: true')
	}
	if arg.enum_name != '' {
		e.line("${pad}\tenum_name: '${arg.enum_name}'")
	}
	e.line('${pad}},')
}

fn (mut e Emitter) emit_proxy(iface &Interface) {
	name := type_name(iface.name)
	if iface.summary != '' {
		e.line('// ${name} is a client side proxy for ${iface.name}. ${comment_line(iface.summary)}')
	} else {
		e.line('// ${name} is a client side proxy for ${iface.name}.')
	}
	e.line('pub struct ${name} {')
	e.line('\twayland.Object')
	e.line('}')
	e.blank()
	e.line('// ${proxy_fn(iface.name)} wraps an object id in a ${name} proxy.')
	e.line('pub fn ${proxy_fn(iface.name)}(conn &wayland.Connection, id u32) ${name} {')
	e.line('\treturn ${name}{')
	e.line('\t\tObject: wayland.Object{')
	e.line('\t\t\tid:    id')
	e.line('\t\t\tconn:  conn')
	e.line("\t\t\tiface: '${iface.name}'")
	e.line('\t\t}')
	e.line('\t}')
	e.line('}')
	e.blank()
}

fn (mut e Emitter) emit_listener(iface &Interface) {
	name := type_name(iface.name)
	e.line('// ${name}Listener receives the events of a ${iface.name} object.')
	e.line('pub interface ${name}Listener {')
	e.line('mut:')
	for event in iface.events {
		if event.summary != '' {
			e.line('\t// ${comment_line(event.summary)}')
		}
		params := e.signature_params(event, false, true)
		args := if params == '' { '' } else { ', ${params}' }
		e.line('\t${v_method(event.name)}(proxy ${name}${args})')
	}
	e.line('}')
	e.blank()
	noop := 'Noop${name}Listener'
	e.line('// ${noop} ignores every ${iface.name} event. It is the default listener, so')
	e.line('// objects without a listener never fail on incoming events.')
	e.line('pub struct ${noop} {}')
	e.blank()
	for event in iface.events {
		params := e.signature_params(event, true, true)
		args := if params == '' { '' } else { ', ${params}' }
		e.line('pub fn (mut listener ${noop}) ${v_method(event.name)}(_proxy ${name}${args}) {')
		e.line('}')
		e.blank()
	}
}

fn (mut e Emitter) emit_sink(iface &Interface) {
	name := type_name(iface.name)
	e.line('struct ${name}Sink {')
	e.line('mut:')
	e.line('\tproxy    ${name}')
	e.line('\tlistener ${name}Listener = Noop${name}Listener{}')
	e.line('}')
	e.blank()
	e.line('fn (mut s ${name}Sink) on_event(msg &wayland.Message) !bool {')
	e.line('\tmatch msg.opcode {')
	for event in iface.events {
		e.line('\t\t${event.opcode} {')
		for index, arg in event.args {
			e.emit_event_arg_decode(arg, index)
		}
		e.line('\t\t\ts.listener.${v_method(event.name)}(s.proxy${e.sink_call_args(event)})')
		e.line('\t\t}')
	}
	e.line('\t\telse {')
	e.line('\t\t\treturn false')
	e.line('\t\t}')
	e.line('\t}')
	e.line('\treturn true')
	e.line('}')
	e.blank()
	e.line('// set_listener registers the handler that receives ${iface.name} events.')
	e.line('pub fn (proxy &${name}) set_listener(listener ${name}Listener) ! {')
	e.line('\tproxy.conn.set_sink(proxy.id, ${name}Sink{')
	e.line('\t\tproxy:    *proxy')
	e.line('\t\tlistener: listener')
	e.line('\t})!')
	e.line('}')
	e.blank()
}

// emit_event_arg_decode writes the statements decoding one event argument into a
// local variable named after it.
fn (mut e Emitter) emit_event_arg_decode(arg &Arg, index int) {
	name := v_ident(arg.name)
	match arg.kind {
		'int', 'string', 'array', 'fd' {
			e.line('\t\t\t${name} := msg.arg_${arg.kind}(${index})!')
		}
		'fixed' {
			// The wire carries 24.8 fixed point; listeners see plain numbers, and
			// a bare `Fixed` would be converted bit for bit (no division) because V
			// widens it to the f64 parameter without complaining.
			e.line('\t\t\t${name} := msg.arg_fixed(${index})!.f64()')
		}
		'uint' {
			e.line('\t\t\t${name} := msg.arg_u32(${index})!')
		}
		'object' {
			e.line('\t\t\t${name}_id := msg.arg_id(${index})!')
			if e.is_typed(arg.iface) {
				if arg.nullable {
					typed := e.type_for(arg.iface)
					proxy := e.proxy_for(arg.iface, 's.proxy.conn', '${name}_id')
					e.line('\t\t\tmut ${name} := ?${typed}(none)')
					e.line('\t\t\tif ${name}_id != 0 {')
					e.line('\t\t\t\t${name} = ${proxy}')
					e.line('\t\t\t}')
				} else {
					proxy := e.proxy_for(arg.iface, 's.proxy.conn', '${name}_id')
					e.line('\t\t\t${name} := ${proxy}')
				}
			} else {
				object := "wayland.Object{ id: ${name}_id, conn: s.proxy.conn, iface: '${arg.iface}' }"
				if arg.nullable {
					e.line('\t\t\tmut ${name} := ?wayland.Object(none)')
					e.line('\t\t\tif ${name}_id != 0 {')
					e.line('\t\t\t\t${name} = ${object}')
					e.line('\t\t\t}')
				} else {
					e.line('\t\t\t${name} := ${object}')
				}
			}
		}
		'new_id' {
			// A new_id event argument is an object the compositor created: take
			// over its id before wrapping it in a typed proxy.
			e.line('\t\t\t${name}_id := msg.arg_id(${index})!')
			e.line("\t\t\ts.proxy.conn.register_object(${name}_id, '${arg.iface}', ${e.desc_for(arg.iface)})!")
			proxy := e.proxy_for(arg.iface, 's.proxy.conn', '${name}_id')
			e.line('\t\t\t${name} := ${proxy}')
		}
		else {}
	}
}

fn (e &Emitter) sink_call_args(event &Message) string {
	if event.args.len == 0 {
		return ''
	}
	mut parts := []string{}
	for arg in event.args {
		parts << v_ident(arg.name)
	}
	return ', ' + parts.join(', ')
}

// emit_request writes the method for one request.
fn (mut e Emitter) emit_request(iface &Interface, request &Message) {
	if request.summary != '' {
		e.line('// ${comment_line(request.summary)}')
	}
	params := e.signature_params(request, false, false)
	return_type := e.request_return_type(request)
	e.line('pub fn (proxy &${type_name(iface.name)}) ${v_method(request.name)}(${params}) ${return_type} {')
	mut new_ids := []Arg{}
	for arg in request.args {
		if arg.kind == 'new_id' {
			new_ids << arg
		}
	}
	for arg in request.args {
		if arg.kind == 'object' && arg.nullable {
			name := v_ident(arg.name)
			e.line('\t${name}_id := if value := ${name} { value.id } else { u32(0) }')
		}
	}
	for arg in new_ids {
		name := v_ident(arg.name)
		e.line('\t${name}_id := proxy.conn.alloc_id()!')
		e.line('\t${name}_object := wayland.Object{')
		e.line('\t\tid:    ${name}_id')
		e.line('\t\tconn:  proxy.conn')
		e.line("\t\tiface: '${arg.iface}'")
		e.line('\t}')
		e.line("\tproxy.conn.register_object(${name}_id, '${arg.iface}', ${e.desc_for(arg.iface)})!")
	}
	mut encoded := []string{}
	for arg in request.args {
		name := v_ident(arg.name)
		match arg.kind {
			'int', 'uint', 'string', 'array' {
				encoded << 'wayland.ArgValue(${name})'
			}
			'fixed' {
				// Requests take plain numbers as well, and the wire needs the 24.8
				// value: without this the conversion truncates the number to a whole
				// fixed value, which is a 1/256 of a unit on the wire.
				encoded << 'wayland.ArgValue(wayland.Fixed.new(${name}))'
			}
			'fd' {
				encoded << 'wayland.ArgValue(wayland.Fd{ fd: ${name} })'
			}
			'object' {
				if arg.nullable {
					encoded << 'wayland.ArgValue(wayland.ObjectRef{ id: ${name}_id })'
				} else {
					encoded << 'wayland.ArgValue(wayland.ObjectRef{ id: ${name}.id })'
				}
			}
			'new_id' {
				encoded << 'wayland.ArgValue(wayland.ObjectRef{ id: ${name}_id })'
			}
			else {}
		}
	}
	args := if encoded.len == 0 { '[]wayland.ArgValue{}' } else { '[${encoded.join(', ')}]' }
	e.line('\tproxy.conn.request(proxy.id, ${request.opcode}, ${args})!')
	if request.destructor {
		e.line('\tproxy.conn.destroy_object(proxy.id)')
	}
	if new_ids.len == 1 {
		arg := new_ids[0]
		name := v_ident(arg.name)
		if e.is_typed(arg.iface) {
			e.line('\treturn ${type_name(arg.iface)}{')
			e.line('\t\tObject: ${name}_object')
			e.line('\t}')
		} else {
			e.line('\treturn ${name}_object')
		}
	} else if new_ids.len > 1 {
		mut objects := []string{}
		for arg in new_ids {
			objects << '${v_ident(arg.name)}_object'
		}
		e.line('\treturn [${objects.join(', ')}]')
	}
	e.line('}')
	e.blank()
}

// request_return_type returns the return type of a generated request method.
fn (e &Emitter) request_return_type(request &Message) string {
	mut count := 0
	for arg in request.args {
		if arg.kind == 'new_id' {
			count++
		}
	}
	if count == 0 {
		return '!'
	}
	if count == 1 {
		for arg in request.args {
			if arg.kind == 'new_id' {
				if e.locals[arg.iface] {
					return '!${type_name(arg.iface)}'
				}
				if external := e.externs[arg.iface] {
					return '!${external.module}.${type_name(arg.iface)}'
				}
				return '!wayland.Object'
			}
		}
	}
	return '![]wayland.Object'
}

// signature_params builds the parameter list of a generated method. new_id
// arguments are excluded: for requests they are the return value, for events they
// are objects created by the compositor.
fn (mut e Emitter) signature_params(message &Message, underscore_names bool, include_new_id bool) string {
	mut parts := []string{}
	for arg in message.args {
		name := if underscore_names { '_${v_ident(arg.name)}' } else { v_ident(arg.name) }
		match arg.kind {
			'int' {
				parts << '${name} i32'
			}
			'uint' {
				parts << '${name} u32'
			}
			'fixed' {
				parts << '${name} f64'
			}
			'string' {
				parts << '${name} string'
			}
			'array' {
				parts << '${name} []u8'
			}
			'fd' {
				parts << '${name} int'
			}
			'object' {
				mut ty := if e.is_typed(arg.iface) {
					e.type_for(arg.iface)
				} else {
					'wayland.Object'
				}
				if arg.nullable {
					ty = '?' + ty
				}
				parts << '${name} ${ty}'
			}
			'new_id' {
				// Only events receive new_id arguments: they are the objects the
				// compositor created. Requests return them instead.
				if include_new_id {
					ty := if e.is_typed(arg.iface) {
						e.type_for(arg.iface)
					} else {
						'wayland.Object'
					}
					parts << '${name} ${ty}'
				}
			}
			else {}
		}
	}
	return parts.join(', ')
}

fn (mut e Emitter) emit_enums(iface &Interface) {
	for enum_type in iface.enums {
		e.line('// ${iface.name}.${enum_type.name}: values of the ${iface.name} protocol enum.')
		for entry in enum_type.entries {
			if entry.summary != '' {
				e.line('// ${comment_line(entry.summary)}')
			}
			name := '${iface.name}_${enum_type.name}_${ident_fragment(entry.name)}'
			literal := if entry.value < 0 { 'i32(${entry.value})' } else { 'u32(${entry.value})' }
			e.line('pub const ${name} = ${literal}')
		}
		e.blank()
	}
}

// emit_binder writes the helper that binds a global to its typed proxy.
fn (mut e Emitter) emit_binder(iface &Interface) {
	name := type_name(iface.name)
	e.line('// bind_${iface.name} binds the ${iface.name} global to a typed proxy.')
	e.line('pub fn bind_${v_ident(iface.name)}(conn &wayland.Connection, global wayland.Global) !${name} {')
	e.line('\tversion := if global.version < ${iface.name}_desc.version {')
	e.line('\t\tglobal.version')
	e.line('\t} else {')
	e.line('\t\t${iface.name}_desc.version')
	e.line('\t}')
	e.line("\tobject := conn.bind_global(global, '${iface.name}', version, &${iface.name}_desc)!")
	e.line('\treturn ${name}{')
	e.line('\t\tObject: object')
	e.line('\t}')
	e.line('}')
	e.blank()
}

// --- module assembly --------------------------------------------------------

fn (mut e Emitter) assemble() string {
	mut header := strings.new_builder(2048)
	header.writeln('// Code generated by wayland-gen from ${e.protocol.source}. DO NOT EDIT.')
	header.writeln('//')
	header.writeln('// Protocol: ${e.protocol.name}')
	if e.protocol.summary != '' {
		header.writeln('// ${comment_line(e.protocol.summary)}')
	}
	if e.protocol.copyright != '' {
		header.writeln('//')
		for line in wrap(e.protocol.copyright, 74) {
			header.writeln('// ${line}')
		}
	}
	header.writeln('module ${e.module}')
	header.writeln('')
	header.writeln('import ${root_module}')
	mut aliases := e.imports.keys()
	aliases.sort()
	for alias in aliases {
		path := e.imports[alias]
		// A module is imported under its own name unless we need another alias.
		if path.all_after_last('.') == alias {
			header.writeln('import ${path}')
		} else {
			header.writeln('import ${path} as ${alias}')
		}
	}
	header.writeln('')
	if e.missing.len > 0 {
		mut names := e.missing.clone()
		names.sort()
		header.writeln('// Note: ${names.join(', ')} are referenced by this protocol but no')
		header.writeln('// generated module for them was given, so those arguments are untyped')
		header.writeln('// wayland.Object values. Generate the protocol that defines them, or')
		header.writeln('// pass it as an extern, for a fully typed API.')
		header.writeln('')
	}
	return header.str() + e.body.str()
}

// wrap breaks text into lines of at most `width` characters.
fn wrap(text string, width int) []string {
	mut lines := []string{}
	mut current := ''
	for word in text.split(' ') {
		if word == '' {
			continue
		}
		if current == '' {
			current = word
		} else if current.len + 1 + word.len <= width {
			current += ' ' + word
		} else {
			lines << current
			current = word
		}
	}
	if current != '' {
		lines << current
	}
	return lines
}
