// Windows support is experimental: the dashboard chrome renders (with ANSI
// enabled), but process/cwd inspection isn't wired up yet — there is no /proc
// equivalent and reading a process's working directory needs PEB walking. So it
// currently lists no sessions. Quit with Ctrl-C.
package main

import "core:os"
import win "core:sys/windows"

foreign import kernel32 "system:Kernel32.lib"

@(default_calling_convention = "system")
foreign kernel32 {
	SetConsoleMode :: proc(h: win.HANDLE, mode: win.DWORD) -> win.BOOL ---
	GetConsoleMode :: proc(h: win.HANDLE, mode: ^win.DWORD) -> win.BOOL ---
}

term_setup :: proc() {
	// Enable ANSI escape processing on the output handle (Windows 10+).
	h := win.GetStdHandle(win.STD_OUTPUT_HANDLE)
	mode: win.DWORD
	if GetConsoleMode(h, &mode) {
		SetConsoleMode(h, mode | win.ENABLE_VIRTUAL_TERMINAL_PROCESSING | win.ENABLE_PROCESSED_OUTPUT)
	}
	term_out("\x1b[?1049h\x1b[?25l\x1b[2J")
	g_raw = false // no raw key input; quit with Ctrl-C
}

term_restore :: proc() {
	term_out("\x1b[?25h\x1b[?1049l")
}

term_out :: proc(s: string) {
	os.write(os.stdout, transmute([]byte)s)
}

read_key :: proc() -> u8 {
	return 0
}

install_signals :: proc() {}

term_width :: proc() -> int {
	info: win.CONSOLE_SCREEN_BUFFER_INFO
	h := win.GetStdHandle(win.STD_OUTPUT_HANDLE)
	if win.GetConsoleScreenBufferInfo(h, &info) {
		w := int(info.srWindow.Right - info.srWindow.Left + 1)
		if w > 0 do return w
	}
	return 120
}

list_procs :: proc() -> [dynamic]Proc {
	return nil
}

proc_cwd :: proc(_: int) -> (string, bool) {
	return "", false
}
