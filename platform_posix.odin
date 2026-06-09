#+build linux, darwin
// Terminal, input, signals and process listing for Unix (Linux + macOS).
package main

import "core:c"
import "core:sys/posix"

foreign import libc "system:c"

@(default_calling_convention = "c")
foreign libc {
	ioctl :: proc(fd: c.int, request: c.ulong, arg: rawptr) -> c.int ---
}

when ODIN_OS == .Darwin {
	TIOCGWINSZ :: 0x40087468
} else {
	TIOCGWINSZ :: 0x5413
}

STDIN :: posix.FD(0)
STDOUT :: posix.FD(1)

g_orig: posix.termios

term_setup :: proc() {
	term_out("\x1b[?1049h\x1b[?25l\x1b[2J") // alt screen, hide cursor, clear once
	if posix.tcgetattr(STDIN, &g_orig) == .OK {
		raw := g_orig
		raw.c_lflag -= {.ECHO, .ICANON, .ISIG, .IEXTEN} // raw keys, no echo, keys not signals
		raw.c_cc[.VMIN] = 0 // non-blocking reads
		raw.c_cc[.VTIME] = 0
		posix.tcsetattr(STDIN, .TCSANOW, &raw)
		g_raw = true
	}
}

term_restore :: proc() {
	if g_raw {
		posix.tcsetattr(STDIN, .TCSANOW, &g_orig)
		g_raw = false
	}
	term_out("\x1b[?25h\x1b[?1049l") // show cursor, leave alt screen
}

term_out :: proc(s: string) {
	posix.write(STDOUT, raw_data(s), len(s))
}

read_key :: proc() -> u8 {
	buf: [1]u8
	if posix.read(STDIN, raw_data(buf[:]), 1) > 0 do return buf[0]
	return 0
}

on_signal :: proc "c" (_: posix.Signal) {
	g_quit = true
}

install_signals :: proc() {
	posix.signal(.SIGINT, on_signal)
	posix.signal(.SIGTERM, on_signal)
}

term_width :: proc() -> int {
	Winsize :: struct {
		row, col, xpix, ypix: u16,
	}
	ws: Winsize
	ioctl(1, c.ulong(TIOCGWINSZ), &ws)
	if ws.col > 0 do return int(ws.col)
	return 120
}

list_procs :: proc() -> [dynamic]Proc {
	return parse_ps(run({"ps", "-axww", "-o", "pid=,ppid=,pcpu=,rss=,etime=,args="}))
}
