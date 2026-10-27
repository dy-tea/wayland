module gen

import os

// The intermediate representation of a protocol. `gen/emit.v` turns it into V
// source; `wayland-gen` fills it from protocol XML files.

// Protocol is one `<protocol>` element.
@[heap]
pub struct Protocol {
pub mut:
	name       string
	copyright  string
	summary    string
	source     string
	interfaces []Interface
}

// Interface is one `<interface>` element with its requests, events and enums.
pub struct Interface {
pub mut:
	name     string
	version  u32
	summary  string
	requests []Message
	events   []Message
	enums    []EnumType
}

// Message is one request or event.
pub struct Message {
pub mut:
	name       string
	opcode     int
	since      u32
	destructor bool
	summary    string
	args       []Arg
}

// Arg is one message argument.
pub struct Arg {
pub mut:
	name      string
	kind      string
	iface     string
	nullable  bool
	enum_name string
	summary   string
}

// EnumType is one `<enum>` element.
pub struct EnumType {
pub mut:
	name     string
	bitfield bool
	summary  string
	entries  []EnumEntry
}

// EnumEntry is one value of an enum.
pub struct EnumEntry {
pub mut:
	name    string
	value   i64
	summary string
}

// arg_kinds are the argument types the protocol XML may use.
pub const arg_kinds = ['int', 'uint', 'fixed', 'string', 'object', 'new_id', 'array', 'fd']

// load_protocol reads and validates a protocol description.
pub fn load_protocol(path string) !Protocol {
	source := os.read_file(path)!
	roots := parse_xml(source, path)!
	mut root := &XmlNode{}
	mut found := false
	for node in roots {
		if node.name == 'protocol' {
			root = node
			found = true
			break
		}
	}
	if !found {
		return error('${path}: no <protocol> element found')
	}
	name := root.attr('name')
	if name == '' {
		return error('${path}: <protocol> needs a name attribute')
	}
	mut protocol := Protocol{
		name:    name
		summary: summary_of(root)
		source:  os.base(path)
	}
	if copyright := root.find_first('copyright') {
		protocol.copyright = clean_text(copyright.text)
	}
	for node in root.find_all('interface') {
		protocol.interfaces << interface_from_xml(node, path)!
	}
	if protocol.interfaces.len == 0 {
		return error('${path}: protocol ${name} defines no interfaces')
	}
	apply_protocol_quirks(mut protocol)
	return protocol
}

// apply_protocol_quirks restores the wire signature of requests that
// wayland.xml documents differently from what is sent, for the sake of the C
// API.
//
// wl_registry.bind is the only such request. The XML documents it with two
// arguments (name and id), because the client library knows the interface name
// and version from the C arguments it is given. On the wire the request is
// "usun": name, interface name, version and the id of the bound object.
// wayland-scanner special cases it the same way, so the special case is part of
// the protocol rather than a shortcut: without it the generated bind() would
// send a message the compositor cannot parse.
fn apply_protocol_quirks(mut protocol Protocol) {
	if protocol.name != 'wayland' {
		return
	}
	for mut iface in protocol.interfaces {
		if iface.name != 'wl_registry' {
			continue
		}
		for mut request in iface.requests {
			if request.name != 'bind' {
				continue
			}
			request.args = [
				Arg{
					name:    'name'
					kind:    'uint'
					summary: 'unique numeric name of the object'
				},
				Arg{
					name:    'interface'
					kind:    'string'
					summary: 'name of the objects interface'
				},
				Arg{
					name:    'version'
					kind:    'uint'
					summary: 'version of the objects interface'
				},
				Arg{
					name:    'id'
					kind:    'new_id'
					summary: 'bound object'
				},
			]
		}
	}
}

fn interface_from_xml(node &XmlNode, path string) !Interface {
	name := node.attr('name')
	if name == '' {
		return error('${path}: <interface> without a name')
	}
	version := node.attr('version').u32()
	if version == 0 {
		return error('${path}: interface ${name} needs a version')
	}
	mut iface := Interface{
		name:    name
		version: version
		summary: summary_of(node)
	}
	for request in node.find_all('request') {
		iface.requests << message_from_xml(request, iface.requests.len, path, true)!
	}
	for event in node.find_all('event') {
		iface.events << message_from_xml(event, iface.events.len, path, false)!
	}
	for enum_node in node.find_all('enum') {
		iface.enums << enum_from_xml(enum_node, path)!
	}
	return iface
}

fn message_from_xml(node &XmlNode, opcode int, path string, is_request bool) !Message {
	name := node.attr('name')
	if name == '' {
		return error('${path}: message without a name')
	}
	since := node.attr('since').u32()
	mut message := Message{
		name:       name
		opcode:     opcode
		since:      if since == 0 { u32(1) } else { since }
		destructor: is_request && node.attr('type') == 'destructor'
		summary:    summary_of(node)
	}
	for arg_node in node.find_all('arg') {
		message.args << arg_from_xml(arg_node, path)!
	}
	return message
}

fn arg_from_xml(node &XmlNode, path string) !Arg {
	name := node.attr('name')
	kind := node.attr('type')
	if kind == '' {
		return error('${path}: argument ${name} has no type')
	}
	if kind !in arg_kinds {
		return error('${path}: argument ${name} has unsupported type ${kind}')
	}
	return Arg{
		name:      name
		kind:      kind
		iface:     node.attr('interface')
		nullable:  node.attr('allow-null') == 'true'
		enum_name: node.attr('enum')
		summary:   clean_text(node.attr('summary'))
	}
}

fn enum_from_xml(node &XmlNode, path string) !EnumType {
	name := node.attr('name')
	if name == '' {
		return error('${path}: <enum> without a name')
	}
	mut enum_type := EnumType{
		name:     name
		bitfield: node.attr('bitfield') == 'true'
		summary:  summary_of(node)
	}
	for entry_node in node.find_all('entry') {
		entry_name := entry_node.attr('name')
		if entry_name == '' {
			return error('${path}: <enum> ${name} has an entry without a name')
		}
		enum_type.entries << EnumEntry{
			name:    entry_name
			value:   parse_int(entry_node.attr('value'))
			summary: clean_text(entry_node.attr('summary'))
		}
	}
	return enum_type
}

// parse_int reads a decimal or hexadecimal integer, as used by enum values.
fn parse_int(text string) i64 {
	value := text.trim_space()
	if value == '' {
		return 0
	}
	if value.starts_with('-') {
		return -i64(value[1..].int())
	}
	if value.starts_with('0x') || value.starts_with('0X') {
		mut result := i64(0)
		for i in 2 .. value.len {
			c := value[i]
			digit := if c >= u8(48) && c <= u8(57) {
				int(c) - 48
			} else if c >= u8(97) && c <= u8(102) {
				int(c) - 87
			} else if c >= u8(65) && c <= u8(70) {
				int(c) - 55
			} else {
				break
			}
			result = result * 16 + digit
		}
		return result
	}
	return i64(value.int())
}

// --- text helpers -----------------------------------------------------------

// clean_text collapses whitespace in a block of text.
pub fn clean_text(text string) string {
	mut out := []u8{cap: text.len}
	mut pending_space := false
	for c in text.bytes() {
		if c == u8(32) || c == u8(9) || c == u8(10) || c == u8(13) {
			pending_space = out.len > 0
			continue
		}
		if pending_space {
			out << u8(32)
			pending_space = false
		}
		out << c
	}
	return out.bytestr()
}

// summary_of returns a one line description for a node: the `summary` attribute
// when present, otherwise the first sentence of the `<description>` child.
fn summary_of(node &XmlNode) string {
	summary := node.attr('summary')
	if summary != '' {
		return truncate(clean_text(summary))
	}
	description := node.find_first('description') or { return '' }
	plain := clean_text(description.text)
	for i, c in plain.bytes() {
		if c == u8(46) && i > 24 {
			return truncate(plain[..i + 1])
		}
	}
	return truncate(plain)
}

fn truncate(text string) string {
	if text.len <= 110 {
		return text
	}
	return text[..110] + '...'
}
