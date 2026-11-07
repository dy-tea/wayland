module gen

import encoding.xml

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
	document := xml.XMLDocument.from_string(source) or {
		return error('${source_name}: ${err.msg()}')
	}
	return [convert_node(document.root)!]
}

fn convert_node(node xml.XMLNode) !&XmlNode {
	mut text := ''
	mut children := []&XmlNode{}
	for child in node.children {
		match child {
			string {
				text += child
			}
			xml.XMLCData {
				text += child.text
			}
			xml.XMLNode {
				children << convert_node(child)!
			}
			xml.XMLComment {}
		}
	}
	return &XmlNode{
		name:     node.name
		attrs:    node.attributes
		text:     text
		children: children
	}
}
