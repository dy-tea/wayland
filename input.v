module wayland

import os
import wayland.protocols.wayland as wl

// Keyboard input.
//
// wl_keyboard reports key presses as raw Linux evdev key codes: they name
// physical keys, not letters, so which character a key produces depends on the
// layout the compositor selected. The codes below are the ones an application
// usually acts on (Escape, the arrows, Enter and so on); turning any other code
// into a character or a keysym needs the xkb keymap, which the compositor sends
// as a file descriptor - `read_keymap()` reads it.

// key_escape is the Escape key.
pub const key_escape = u32(1)

// key_backspace is the Backspace key.
pub const key_backspace = u32(14)

// key_tab is the Tab key.
pub const key_tab = u32(15)

// key_enter is the Return key.
pub const key_enter = u32(28)

// key_space is the space bar.
pub const key_space = u32(57)

// key_insert is the Insert key.
pub const key_insert = u32(110)

// key_delete is the Delete key.
pub const key_delete = u32(111)

// key_home is the Home key.
pub const key_home = u32(102)

// key_end is the End key.
pub const key_end = u32(107)

// key_page_up is the Page Up key.
pub const key_page_up = u32(104)

// key_page_down is the Page Down key.
pub const key_page_down = u32(109)

// key_left is the left arrow key.
pub const key_left = u32(105)

// key_right is the right arrow key.
pub const key_right = u32(106)

// key_up is the up arrow key.
pub const key_up = u32(103)

// key_down is the down arrow key.
pub const key_down = u32(108)

// keymap_size_limit is the largest keymap read_keymap will read. The size comes
// from the compositor, and the keymaps xkeyboard-config ships are tens of
// kilobytes, so anything this large is a mistake - or a compositor that is not
// being friendly - and must not turn into an allocation.
const keymap_size_limit = 16 * 1024 * 1024

// key_name returns the name of a key code, for the codes this file defines.
// Other codes have no name here: they depend on the layout, and only the keymap
// knows what they produce.
pub fn key_name(key u32) ?string {
	return match key {
		key_escape { 'Escape' }
		key_backspace { 'Backspace' }
		key_tab { 'Tab' }
		key_enter { 'Enter' }
		key_space { 'Space' }
		key_insert { 'Insert' }
		key_delete { 'Delete' }
		key_home { 'Home' }
		key_end { 'End' }
		key_page_up { 'Page Up' }
		key_page_down { 'Page Down' }
		key_left { 'Left' }
		key_right { 'Right' }
		key_up { 'Up' }
		key_down { 'Down' }
		else { none }
	}
}

// read_keymap reads the keymap a wl_keyboard sent and closes its descriptor:
// the fd in the keymap event belongs to the client, and this is the only
// function that needs it.
//
// `format` and `size` are the arguments of the keymap event. Format
// `wl_keyboard_keymap_format_no_keymap` means the compositor has no keymap for
// the client, and the returned string is empty; the xkb format returns the
// keymap text, without its terminating NUL.
pub fn read_keymap(format u32, fd int, size u32) !string {
	if fd < 0 {
		return error('the keymap event carries no descriptor')
	}
	defer {
		os.fd_close(fd)
	}
	if format == wl.wl_keyboard_keymap_format_no_keymap {
		return ''
	}
	if format != wl.wl_keyboard_keymap_format_xkb_v1 {
		return error('unsupported keyboard keymap format ${format}')
	}
	if size > keymap_size_limit {
		return error('the keymap event claims ${size} bytes, more than ${keymap_size_limit}')
	}
	// The descriptor is a seekable file whose file offset is shared with the
	// compositor and with every other client that received the same keymap:
	// after one reader reaches the end, everyone else reads nothing. Rewinding
	// first is the reading equivalent of the fresh mapping libwayland clients
	// take of the descriptor. The file is already unlinked (the compositor
	// keeps it alive through the descriptors it sent), so the path is gone and
	// the descriptor itself is all a client has.
	rewind_fd(fd)
	mut text := ''
	mut remaining := int(size)
	for remaining > 0 {
		chunk, read := os.fd_read(fd, remaining)
		if read <= 0 {
			break
		}
		text += chunk
		remaining -= read
	}
	if text.len < int(size) {
		return error('could not read the keyboard keymap from its descriptor')
	}
	return text[..int(size)].trim_right('\x00')
}
