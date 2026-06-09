// Working-directory resolution on macOS: ask `lsof` for the process's cwd.
package main

import "core:fmt"
import "core:strings"

proc_cwd :: proc(pid: int) -> (string, bool) {
	// `-Fn` prints field-prefixed output; the cwd path comes on an 'n' line.
	out := run({"lsof", "-a", "-p", fmt.tprintf("%d", pid), "-d", "cwd", "-Fn"})
	for line in strings.split_lines(out) {
		if len(line) > 1 && line[0] == 'n' {
			return line[1:], true
		}
	}
	return "", false
}
