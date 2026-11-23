module main

import wayland
import wayland.protocols.wayland as wl
import wayland.protocols.color_management_v1 as cm

// Reports the image description (color space / transfer function) that each
// output expects, via the color-management protocol.
//
//	v run examples/color_management

struct OutputColor {
mut:
	label    string
	tf       u32
	tf_set   bool
	prim     u32
	prim_set bool
	done     bool
}

struct InfoListener {
mut:
	oc &OutputColor
}

fn (mut l InfoListener) done(_ cm.WpImageDescriptionInfoV1) {
	l.oc.done = true
}

fn (mut l InfoListener) icc_file(_ cm.WpImageDescriptionInfoV1, _ int, _ u32) {}

fn (mut l InfoListener) primaries(_ cm.WpImageDescriptionInfoV1, _ i32, _ i32, _ i32, _ i32, _ i32, _ i32, _ i32, _ i32) {}

fn (mut l InfoListener) primaries_named(_ cm.WpImageDescriptionInfoV1, primaries u32) {
	l.oc.prim = primaries
	l.oc.prim_set = true
}

fn (mut l InfoListener) tf_power(_ cm.WpImageDescriptionInfoV1, _ u32) {}

fn (mut l InfoListener) tf_named(_ cm.WpImageDescriptionInfoV1, tf u32) {
	l.oc.tf = tf
	l.oc.tf_set = true
}

fn (mut l InfoListener) luminances(_ cm.WpImageDescriptionInfoV1, _ u32, _ u32, _ u32) {}

fn (mut l InfoListener) target_primaries(_ cm.WpImageDescriptionInfoV1, _ i32, _ i32, _ i32, _ i32, _ i32, _ i32, _ i32, _ i32) {}

fn (mut l InfoListener) target_luminance(_ cm.WpImageDescriptionInfoV1, _ u32, _ u32) {}

fn (mut l InfoListener) target_max_cll(_ cm.WpImageDescriptionInfoV1, _ u32) {}

fn (mut l InfoListener) target_max_fall(_ cm.WpImageDescriptionInfoV1, _ u32) {}

struct CmOutputListener {
mut:
	oc &OutputColor
}

fn (mut l CmOutputListener) image_description_changed(_ cm.WpColorManagementOutputV1) {}

fn tf_name(tf u32) string {
	return match tf {
		cm.wp_color_manager_v1_transfer_function_bt1886 { 'bt1886' }
		cm.wp_color_manager_v1_transfer_function_gamma22 { 'gamma22' }
		cm.wp_color_manager_v1_transfer_function_gamma28 { 'gamma28' }
		cm.wp_color_manager_v1_transfer_function_st240 { 'st240' }
		cm.wp_color_manager_v1_transfer_function_ext_linear { 'ext_linear' }
		cm.wp_color_manager_v1_transfer_function_st2084_pq { 'st2084_pq' }
		cm.wp_color_manager_v1_transfer_function_hlg { 'hlg' }
		else { 'tf ${tf}' }
	}
}

fn prim_name(p u32) string {
	return match p {
		cm.wp_color_manager_v1_primaries_srgb { 'srgb' }
		cm.wp_color_manager_v1_primaries_bt2020 { 'bt2020' }
		cm.wp_color_manager_v1_primaries_display_p3 { 'display_p3' }
		else { 'primaries ${p}' }
	}
}

fn main() {
	mut conn := wayland.connect()!
	defer {
		conn.close()
	}
	globals := conn.globals()!
	output_globals := globals.find_all('wl_output')
	if output_globals.len == 0 {
		eprintln('this compositor has no wl_output')
		return
	}
	cm_global := globals.find('wp_color_manager_v1') or {
		eprintln('this compositor does not speak color-management-v1')
		return
	}
	mut manager := cm.bind_wp_color_manager_v1(conn, cm_global)!

	mut ocs := []&OutputColor{}
	mut cm_listeners := []&CmOutputListener{}
	mut info_listeners := []&InfoListener{}
	for global in output_globals {
		oc := &OutputColor{
			label: 'output ${global.name}'
		}
		proxy := wl.bind_wl_output(conn, global)!
		cmo := manager.get_output(proxy) or {
			eprintln('color-management: could not get output: ${err.msg()}')
			continue
		}
		cm_listeners << &CmOutputListener{ oc: oc }
		cmo.set_listener(cm_listeners.last())!
		id := cmo.get_image_description() or {
			eprintln('color-management: could not get image description: ${err.msg()}')
			continue
		}
		info_listeners << &InfoListener{ oc: oc }
		info := id.get_information() or {
			eprintln('color-management: could not get information: ${err.msg()}')
			continue
		}
		info.set_listener(info_listeners.last())!
		ocs << oc
	}

	for {
		conn.dispatch()!
		if ocs.all(it.done) {
			break
		}
	}

	for oc in ocs {
		print('${oc.label}: ')
		if oc.tf_set {
			print('tf=${tf_name(oc.tf)} ')
		}
		if oc.prim_set {
			print('primaries=${prim_name(oc.prim)}')
		}
		println('')
	}
}
