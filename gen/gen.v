module gen

import os

// Orchestration: read protocols from XML, put every generated module into one
// output directory, and let modules reference each other.

// GenerateResult describes one generated module.
pub struct GenerateResult {
pub:
	protocol   string
	module     string
	path       string
	interfaces int
}

// generate writes the V module for a protocol into `out_dir/<module>/<module>.v`.
pub fn generate(protocol &Protocol, out_dir string, externs map[string]ExternIface) !GenerateResult {
	source := emit_module(protocol, EmitOptions{
		externs: externs
	})!
	module := module_name(protocol.name)
	dir := os.join_path(out_dir, module)
	os.mkdir_all(dir)!
	path := os.join_path(dir, '${module}.v')
	os.write_file(path, source)!
	return GenerateResult{
		protocol:   protocol.name
		module:     module
		path:       path
		interfaces: protocol.interfaces.len
	}
}

// externs_for maps every interface defined by `protocols` (except the one named
// `skip`) to the module and import path it is generated into, so that protocols
// referencing each other get fully typed arguments.
pub fn externs_for(protocols []&Protocol, import_prefix string, skip string) map[string]ExternIface {
	mut externs := map[string]ExternIface{}
	for protocol in protocols {
		if protocol.name == skip {
			continue
		}
		module := module_name(protocol.name)
		for iface in protocol.interfaces {
			if iface.name in externs {
				continue
			}
			externs[iface.name] = ExternIface{
				module: module
				path:   '${import_prefix}.${module}'
			}
		}
	}
	return externs
}

// protocol_files expands a list of XML files and directories into XML paths.
pub fn protocol_files(inputs []string) ![]string {
	mut files := []string{}
	for input in inputs {
		if os.is_dir(input) {
			entries := os.ls(input)!
			for entry in entries {
				if entry.ends_with('.xml') {
					files << os.join_path(input, entry)
				}
			}
			continue
		}
		if !os.exists(input) {
			return error('no such file or directory: ${input}')
		}
		files << input
	}
	files.sort()
	return files
}
