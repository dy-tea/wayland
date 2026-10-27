module gen

// Turning protocol names into V names.
//
// Protocol XML uses lower_snake_case for interfaces, messages and arguments, but
// enum entries are freer (they include values like "90" and "flipped_90"), and a
// few names collide with V keywords. The helpers here make every generated name
// a valid, predictable V identifier.

// v_keywords cannot be used as identifiers.
const v_keywords = ['as', 'asm', 'assert', 'atomic', 'break', 'const', 'continue', 'defer', 'else',
	'enum', 'false', 'fn', 'for', 'go', 'goto', 'if', 'import', 'in', 'interface', 'is', 'isref',
	'lock', 'match', 'module', 'mut', 'none', 'or', 'pub', 'return', 'rlock', 'select', 'shared',
	'sizeof', 'static', 'struct', 'true', 'type', 'typeof', 'union', 'unlock', 'unsafe', 'volatile']

// reserved_locals are the local variable names the generator itself uses inside
// generated method bodies.
const reserved_locals = ['conn', 'sconn', 'proxy', 'msg', 'listener', 'value', 'obj', 's']

fn is_lower(c u8) bool {
	return c >= u8(97) && c <= u8(122)
}

fn is_upper(c u8) bool {
	return c >= u8(65) && c <= u8(90)
}

fn is_digit(c u8) bool {
	return c >= u8(48) && c <= u8(57)
}

// v_ident turns a protocol name into a valid V identifier, in snake_case.
pub fn v_ident(name string) string {
	mut out := []u8{cap: name.len}
	for c in name.bytes() {
		if is_lower(c) || is_digit(c) || c == u8(95) {
			out << c
		} else if is_upper(c) {
			out << u8(int(c) + 32)
		} else {
			out << u8(95)
		}
	}
	mut result := out.bytestr()
	for result.len > 0 && result[0] == u8(95) {
		result = result[1..]
	}
	if result == '' {
		result = 'unnamed'
	}
	if is_digit(result[0]) {
		result = 'num_' + result
	}
	if result in v_keywords || result in reserved_locals {
		result += '_'
	}
	return result
}

// type_name turns an interface name into a V type name: wl_surface -> WlSurface.
pub fn type_name(iface string) string {
	mut out := []u8{cap: iface.len}
	mut upper := true
	for c in iface.bytes() {
		if c == u8(95) || c == u8(45) || c == u8(46) {
			upper = true
			continue
		}
		if upper {
			out << if is_lower(c) { u8(int(c) - 32) } else { c }
			upper = false
		} else {
			out << c
		}
	}
	mut result := out.bytestr()
	if result == '' {
		result = 'Object'
	}
	if is_digit(result[0]) {
		result = 'V' + result
	}
	return result
}

// module_name turns a protocol name into a V module name: xdg-shell -> xdg_shell.
pub fn module_name(protocol string) string {
	name := v_ident(protocol)
	if name == 'main' {
		// `main` is reserved for executables.
		return 'main_protocol'
	}
	return name
}

// ident_fragment makes an enum entry name usable inside a constant name.
pub fn ident_fragment(name string) string {
	mut out := []u8{cap: name.len}
	for c in name.bytes() {
		if is_lower(c) || is_digit(c) || c == u8(95) {
			out << c
		} else if is_upper(c) {
			out << u8(int(c) + 32)
		} else {
			out << u8(95)
		}
	}
	mut result := out.bytestr()
	for result.len > 0 && result[0] == u8(95) {
		result = result[1..]
	}
	if result == '' {
		result = 'value'
	}
	if is_digit(result[0]) {
		result = 'num_' + result
	}
	return result
}

// proxy_fn is the name of the generated proxy constructor of an interface.
pub fn proxy_fn(iface string) string {
	return '${v_ident(iface)}_proxy'
}

// comment_line collapses text into a single safe V comment line.
pub fn comment_line(text string) string {
	return truncate(clean_text(text))
}

// v_method is the V name of a generated method.
pub fn v_method(name string) string {
	return v_ident(name)
}

// kind_member maps an XML argument type to an ArgKind member name.
pub fn kind_member(kind string) string {
	return match kind {
		'string' { 'str' }
		'object' { 'obj' }
		else { kind }
	}
}
