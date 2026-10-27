module gen

// A small XML reader, just enough for Wayland protocol descriptions.
//
// It understands elements, attributes, text, comments, processing instructions,
// CDATA sections, a DOCTYPE declaration and the usual character entities. It
// does not validate against a DTD (the protocol files reference wayland.dtd, but
// the parts we need are self describing).

// XmlNode is one element of a parsed document.
pub struct XmlNode {
pub mut:
	name     string
	attrs    map[string]string
	text     string
	children []&XmlNode
}

// attr returns an attribute value, or the empty string when it is absent.
pub fn (n &XmlNode) attr(name string) string {
	return n.attrs[name] or { '' }
}

// has_attr reports whether an attribute is present.
pub fn (n &XmlNode) has_attr(name string) bool {
	return name in n.attrs
}

// find_all returns every direct child with the given element name.
pub fn (n &XmlNode) find_all(name string) []&XmlNode {
	mut found := []&XmlNode{}
	for child in n.children {
		if child.name == name {
			found << child
		}
	}
	return found
}

// find_first returns the first direct child with the given element name.
pub fn (n &XmlNode) find_first(name string) ?&XmlNode {
	for child in n.children {
		if child.name == name {
			return child
		}
	}
	return none
}

// parse_xml parses a document and returns its top level elements. `source_name`
// is used in error messages only.
pub fn parse_xml(source string, source_name string) ![]&XmlNode {
	mut parser := XmlParser{
		src:  source
		name: source_name
	}
	return parser.parse_document()
}

struct XmlParser {
mut:
	src  string
	name string
	pos  int
}

// fail reports an error with the line number of the current position.
fn (p &XmlParser) fail(message string) IError {
	line := p.line_of(p.pos)
	return error('${p.name}:${line}: ${message}')
}

fn (p &XmlParser) line_of(pos int) int {
	mut line := 1
	for i in 0 .. pos {
		if i < p.src.len && p.src[i] == u8(10) {
			line++
		}
	}
	return line
}

fn (p &XmlParser) looking_at(s string) bool {
	if p.pos + s.len > p.src.len {
		return false
	}
	for i in 0 .. s.len {
		if p.src[p.pos + i] != s[i] {
			return false
		}
	}
	return true
}

fn (mut p XmlParser) skip_spaces() {
	for p.pos < p.src.len {
		c := p.src[p.pos]
		if c == u8(32) || c == u8(9) || c == u8(10) || c == u8(13) {
			p.pos++
		} else {
			break
		}
	}
}

fn (mut p XmlParser) skip_until(marker string) ! {
	for p.pos < p.src.len {
		if p.looking_at(marker) {
			p.pos += marker.len
			return
		}
		p.pos++
	}
	return p.fail('unterminated ${marker}')
}

// skip_doctype skips <!DOCTYPE ...>, including an internal subset in brackets.
fn (mut p XmlParser) skip_doctype() ! {
	mut depth := 0
	for p.pos < p.src.len {
		c := p.src[p.pos]
		if c == u8(91) {
			depth++
		} else if c == u8(93) {
			depth--
		} else if c == u8(62) && depth <= 0 {
			p.pos++
			return
		}
		p.pos++
	}
	return p.fail('unterminated DOCTYPE')
}

fn (mut p XmlParser) read_name() string {
	start := p.pos
	for p.pos < p.src.len {
		c := p.src[p.pos]
		is_name_char := (c >= u8(97) && c <= u8(122)) || (c >= u8(65) && c <= u8(90))
			|| (c >= u8(48) && c <= u8(57)) || c == u8(95) || c == u8(45) || c == u8(46)
			|| c == u8(58)
		if !is_name_char {
			break
		}
		p.pos++
	}
	if p.pos == start {
		return ''
	}
	return p.src[start..p.pos]
}

fn (mut p XmlParser) read_attribute_value() !string {
	if p.pos >= p.src.len {
		return p.fail('unterminated attribute')
	}
	quote := p.src[p.pos]
	if quote != u8(34) && quote != u8(39) {
		return p.fail('attribute value must be quoted')
	}
	p.pos++
	start := p.pos
	for p.pos < p.src.len && p.src[p.pos] != quote {
		p.pos++
	}
	if p.pos >= p.src.len {
		return p.fail('unterminated attribute value')
	}
	value := decode_entities(p.src[start..p.pos])
	p.pos++ // closing quote
	return value
}

fn (mut p XmlParser) parse_document() ![]&XmlNode {
	mut nodes := []&XmlNode{}
	for {
		p.skip_spaces()
		if p.pos >= p.src.len {
			break
		}
		if p.looking_at('<?') {
			p.skip_until('?>')!
			continue
		}
		if p.looking_at('<!--') {
			p.skip_until('-->')!
			continue
		}
		if p.looking_at('<!DOCTYPE') || p.looking_at('<!doctype') {
			p.skip_doctype()!
			continue
		}
		if !p.looking_at('<') {
			return p.fail('unexpected content outside of any element')
		}
		nodes << p.parse_element()!
	}
	if nodes.len == 0 {
		return p.fail('no elements found')
	}
	return nodes
}

fn (mut p XmlParser) parse_element() !&XmlNode {
	if !p.looking_at('<') {
		return p.fail('expected an element')
	}
	p.pos++
	name := p.read_name()
	if name == '' {
		return p.fail('expected an element name')
	}
	mut node := &XmlNode{
		name:  name
		attrs: map[string]string{}
	}
	// attributes
	for {
		p.skip_spaces()
		if p.pos >= p.src.len {
			return p.fail('unterminated <${name}> element')
		}
		if p.looking_at('/>') {
			p.pos += 2
			return node
		}
		if p.looking_at('>') {
			p.pos++
			break
		}
		attr_name := p.read_name()
		if attr_name == '' {
			return p.fail('unexpected character inside <${name}>')
		}
		p.skip_spaces()
		if !p.looking_at('=') {
			return p.fail('expected `=` after attribute ${attr_name}')
		}
		p.pos++
		p.skip_spaces()
		node.attrs[attr_name] = p.read_attribute_value()!
	}
	// content
	mut text := ''
	for {
		if p.pos >= p.src.len {
			return p.fail('unterminated <${name}> element')
		}
		if p.looking_at('</') {
			p.pos += 2
			end := p.read_name()
			if end != name {
				return p.fail('closing tag </${end}> does not match <${name}>')
			}
			p.skip_spaces()
			if !p.looking_at('>') {
				return p.fail('expected `>` to close <${name}>')
			}
			p.pos++
			break
		}
		if p.looking_at('<!--') {
			p.skip_until('-->')!
			continue
		}
		if p.looking_at('<?') {
			p.skip_until('?>')!
			continue
		}
		if p.looking_at('<![CDATA[') {
			p.pos += '<![CDATA['.len
			start := p.pos
			p.skip_until(']]>')!
			text += p.src[start..p.pos - 3]
			continue
		}
		if p.looking_at('<') {
			node.children << p.parse_element()!
			continue
		}
		start := p.pos
		for p.pos < p.src.len && p.src[p.pos] != u8(60) {
			p.pos++
		}
		text += decode_entities(p.src[start..p.pos])
	}
	node.text = text
	return node
}

// decode_entities expands the predefined XML entities and numeric escapes.
pub fn decode_entities(s string) string {
	if !s.contains('&') {
		return s
	}
	mut out := []u8{cap: s.len}
	mut i := 0
	for i < s.len {
		if s[i] != u8(38) {
			out << s[i]
			i++
			continue
		}
		end := s.index_after(';', i) or { -1 }
		if end < 0 {
			out << s[i]
			i++
			continue
		}
		entity := s[i + 1..end]
		i = end + 1
		match entity {
			'amp' {
				out << u8(38)
			}
			'lt' {
				out << u8(60)
			}
			'gt' {
				out << u8(62)
			}
			'quot' {
				out << u8(34)
			}
			'apos' {
				out << u8(39)
			}
			else {
				if entity.starts_with('#') {
					code := if entity.len > 1 && (entity[1] == u8(120) || entity[1] == u8(88)) {
						parse_hex(entity[2..])
					} else {
						entity[1..].int()
					}
					if code > 0 {
						out << u8(code & 0xff)
					}
				} else {
					// unknown entity (the DTD may define it): keep it verbatim
					out << '&${entity};'.bytes()
				}
			}
		}
	}
	return out.bytestr()
}

fn parse_hex(s string) int {
	mut value := 0
	for i in 0 .. s.len {
		c := s[i]
		digit := if c >= u8(48) && c <= u8(57) {
			int(c) - 48
		} else if c >= u8(97) && c <= u8(102) {
			int(c) - 87
		} else if c >= u8(65) && c <= u8(70) {
			int(c) - 55
		} else {
			return value
		}
		value = value * 16 + digit
	}
	return value
}
