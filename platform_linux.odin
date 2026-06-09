// Working-directory resolution on Linux: read /proc/<pid>/cwd.
package main

import "core:fmt"
import "core:os"

proc_cwd :: proc(pid: int) -> (string, bool) {
	s, err := os.read_link(fmt.tprintf("/proc/%d/cwd", pid), context.temp_allocator)
	return s, err == nil
}
