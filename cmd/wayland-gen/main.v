module main

import os
import wayland.gen

// wayland-gen generates V modules from Wayland protocol XML files.
//
//	wayland-gen protocols/xml                     # regenerate every protocol
//	wayland-gen -o protocols protocols/xml/xdg-shell.xml
//
// Every protocol in the given files (or directories) is generated into its own
// module, `<out>/<protocol_name>/<protocol_name>.v`. Protocols that reference
// interfaces from the other given files get fully typed arguments; interfaces
// from protocols that are not given are passed as untyped wayland.Object values.
const usage = 'usage: wayland-gen [-o <dir>] [-p <import prefix>] <protocol.xml | directory>...'

fn main() {
	args := os.args[1..]
	mut options := Options{}
	mut inputs := []string{}
	mut index := 0
	for index < args.len {
		arg := args[index]
		match arg {
			'-h', '--help', 'help' {
				println(usage)
				println('')
				println('  -o, --out <dir>        output directory for generated modules (default: protocols)')
				println('  -p, --prefix <path>    import path prefix of the modules (default: wayland.protocols)')
				return
			}
			'-o', '--out' {
				index++
				if index >= args.len {
					fail('missing value for ${arg}')
				}
				options.out_dir = args[index]
			}
			'-p', '--prefix' {
				index++
				if index >= args.len {
					fail('missing value for ${arg}')
				}
				options.prefix = args[index]
			}
			else {
				if arg.starts_with('-') {
					fail('unknown option ${arg}')
				}
				inputs << arg
			}
		}
		index++
	}
	if inputs.len == 0 {
		println(usage)
		exit(2)
	}
	files := gen.protocol_files(inputs) or { fail(err.msg()) }
	mut protocols := []&gen.Protocol{}
	for file in files {
		protocol := gen.load_protocol(file) or { fail(err.msg()) }
		protocols << &protocol
	}
	mut total := 0
	for protocol in protocols {
		externs := gen.externs_for(protocols, options.prefix, protocol.name)
		result := gen.generate(protocol, options.out_dir, externs) or { fail(err.msg()) }
		if !format(result.path) {
			eprintln('wayland-gen: could not run `v fmt`; ${result.path} is left unformatted')
		}
		println('${result.protocol}: ${result.interfaces} interfaces -> ${result.path}')
		total += result.interfaces
	}
	println('generated ${protocols.len} protocols, ${total} interfaces')
}

// format runs the V formatter on a generated module, so that regenerating a
// protocol does not show up as a formatting diff. Set wayland_GEN_NO_FMT to
// keep the raw emitter output instead.
fn format(path string) bool {
	if os.getenv('wayland_GEN_NO_FMT') != '' {
		return true
	}
	v := @VEXE
	if v == '' {
		return false
	}
	return os.system_args([v, 'fmt', '-w', path]) == 0
}

struct Options {
mut:
	out_dir string = 'protocols'
	prefix  string = 'wayland.protocols'
}

@[noreturn]
fn fail(message string) {
	eprintln('wayland-gen: ${message}')
	exit(1)
}
