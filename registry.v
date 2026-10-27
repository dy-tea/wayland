module wayland

// Global discovery and binding.
//
// The compositor advertises its capabilities as "globals": a name, an interface
// name and the interface version. Applications list them with `globals()` and
// then bind the ones they need. Binding is where the typed protocol modules
// take over: `wl.bind_wl_compositor(conn, global)` returns a `WlCompositor`
// proxy, while `bind_global()` is the untyped building block.

// Global is one object advertised by the compositor.
pub struct Global {
pub:
	// name is the numeric name used when binding. It can differ between two runs.
	name u32
	// interface is the interface implemented by the global, e.g. "wl_compositor".
	interface string
	// version is the highest interface version the compositor supports.
	version u32
}

// get_registry creates a proxy for the compositor's registry. Keep it around if
// you want to react to globals appearing and disappearing at run time; listener
// dispatch for it is provided by the generated core protocol module.
//
// There is no need to destroy a registry: the registry protocol has no destroy
// request (the request libwayland exposes under that name only drops the client
// side proxy), and the compositor releases it when the connection ends.
pub fn (mut c Connection) get_registry() !Object {
	id := c.alloc_id()!
	c.register_object(id, 'wl_registry', &wl_registry_iface)!
	c.request(c.display_id, 1, [ArgValue(ObjectRef{
		id: id
	})])!
	return Object{
		id:    id
		conn:  c
		iface: 'wl_registry'
	}
}

// internal_registry returns the registry the library uses for its own global
// lookups. It is created on first use and kept for the lifetime of the
// connection: reusing one registry keeps `bind_global()` from asking the
// compositor to re-announce every global for each bind.
fn (mut c Connection) internal_registry() !u32 {
	if c.registry_id != 0 && !c.object_destroyed(c.registry_id) {
		return c.registry_id
	}
	id := c.alloc_id()!
	c.register_object(id, 'wl_registry', &wl_registry_iface)!
	c.request(c.display_id, 1, [ArgValue(ObjectRef{
		id: id
	})])!
	c.registry_id = id
	return id
}

// globals returns the globals the compositor has advertised, keeping the
// snapshot up to date as they come and go. It performs a registry roundtrip, so
// it blocks until the compositor answered every request sent so far, and the
// snapshot is therefore complete for a fresh connection.
//
// The snapshot is per connection and grows (and shrinks) as announcements
// arrive, so calling it again is cheap: only globals that appeared since the
// last call need to be announced. Applications that want to react to globals
// appearing at run time should keep their own registry from `get_registry()`.
pub fn (mut c Connection) globals() ![]Global {
	registry_id := c.internal_registry()!
	callback := c.sync()!
	c.flush()!
	for {
		msg := c.next_message()!
		if msg.object_id == registry_id {
			match msg.opcode {
				0 {
					// wl_registry.global
					c.remember_global(Global{
						name:      msg.arg_u32(0)!
						interface: msg.arg_string(1)!
						version:   msg.arg_u32(2)!
					})
				}
				1 {
					// wl_registry.global_remove
					c.forget_global(msg.arg_u32(0)!)
				}
				else {
					c.dispatch_message(msg)!
				}
			}
			continue
		}
		if msg.object_id == callback && msg.opcode == 0 {
			break
		}
		c.dispatch_message(msg)!
	}
	return c.globals_cache.clone()
}

// remember_global adds a global to the snapshot, replacing the entry with the
// same name: a name can be reused after a global_remove.
fn (mut c Connection) remember_global(global Global) {
	for i, existing in c.globals_cache {
		if existing.name == global.name {
			c.globals_cache[i] = global
			return
		}
	}
	c.globals_cache << global
}

// forget_global drops the global with the given name from the snapshot.
fn (mut c Connection) forget_global(name u32) {
	for i, existing in c.globals_cache {
		if existing.name == name {
			c.globals_cache.delete(i)
			return
		}
	}
}

// find_global returns the first global implementing `iface`.
pub fn (globals []Global) find(iface string) ?Global {
	for g in globals {
		if g.interface == iface {
			return g
		}
	}
	return none
}

// find_all_globals returns every global implementing `iface`.
pub fn (globals []Global) find_all(iface string) []Global {
	mut found := []Global{}
	for g in globals {
		if g.interface == iface {
			found << g
		}
	}
	return found
}

// bind_global creates an object implementing the global and returns a proxy for
// it. `version` must not exceed the version the compositor advertised, and
// `desc` describes the interface so that its events can be decoded; generated
// protocol modules pass their own descriptor, and hand written protocols can pass
// `opaque_iface` (their events are then dropped).
//
// The returned proxy has no listener yet: call the generated `set_listener()`
// on it to receive events.
pub fn (mut c Connection) bind_global(global Global, iface string, version u32, desc &IfaceDesc) !Object {
	if version == 0 {
		return error('cannot bind ${iface} with version 0')
	}
	if version > global.version {
		return error('compositor supports ${iface} up to version ${global.version}, needs ${version}')
	}
	registry_id := c.internal_registry()!
	id := c.alloc_id()!
	c.register_object(id, iface, desc)!
	c.request(registry_id, 0, [
		ArgValue(global.name),
		ArgValue(iface),
		ArgValue(version),
		ArgValue(ObjectRef{
			id: id
		}),
	])!
	c.flush()!
	return Object{
		id:    id
		conn:  c
		iface: iface
	}
}
