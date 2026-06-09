// clanker control — a tiny `top` for AI coding agents.
//
// A from-scratch Odin rewrite of https://github.com/ktamas77/agentop, trimmed
// down to the only two agents we care about: Claude Code and OpenCode.
//
// It lists running agent processes (via `ps`), resolves each one's working
// directory (via /proc), then enriches it with live session data:
//   - Claude Code: the newest transcript under ~/.claude/projects/<enc-cwd>/
//   - OpenCode:    the session row in ~/.local/share/opencode/opencode.db
//
// The screen redraws a couple of times a second. Keys: q quit, a/c/m/p sort,
// r reverse.
package main

import "core:encoding/json"
import "core:fmt"
import "core:os"
import "core:slice"
import "core:strconv"
import "core:strings"
import "core:time"
import "core:unicode/utf8"

// Platform-specific pieces live in platform_posix.odin / platform_windows.odin:
//   term_setup, term_restore, term_out, term_width, read_key, install_signals,
//   list_procs, proc_cwd

REFRESH_MS :: 500 // redraw interval
POLL_MS :: 60 // how often to check the keyboard while waiting
TAIL_BYTES :: 64 * 1024 // how much of a transcript tail to parse
MAX_LINES :: 200 // how many trailing transcript lines to scan

// Column widths (visible columns). ACTIVITY takes whatever is left.
W_PID :: 7
W_AGENT :: 8
W_MODEL :: 20
W_PROJ :: 16
W_BRANCH :: 12
W_STATE :: 8 // dot + space + 6-char name
W_CPU :: 5
W_MEM :: 6
W_UP :: 7
W_IDLE :: 6
GAPS :: 12 // literal spaces in a row (1 lead + 9 single + 2 before activity)
FIXED :: W_PID + W_AGENT + W_MODEL + W_PROJ + W_BRANCH + W_STATE + W_CPU + W_MEM + W_UP + W_IDLE + GAPS

// ── Data ────────────────────────────────────────────────────────────────────

Row :: struct {
	pid:      int,
	kind:     string, // "claude" | "opencode"
	model:    string,
	project:  string, // basename of cwd
	branch:   string,
	state:    string, // working | thinking | replied | waiting | active | idle | ?
	detail:   string,
	cpu:      f64,
	mem_kb:   int,
	uptime_s: int,
	idle_s:   int,
}

Proc :: struct {
	pid:      int,
	cpu:      f64,
	rss_kb:   int,
	uptime_s: int,
	args:     string,
}

// ── Main loop ─────────────────────────────────────────────────────────────────

main :: proc() {
	home := os.get_env("HOME", context.allocator)
	if home == "" do home = os.get_env("USERPROFILE", context.allocator) // Windows

	// `clanker-control once` renders a single frame and exits (handy for piping).
	if len(os.args) > 1 && os.args[1] == "once" {
		context.allocator = context.temp_allocator
		rows := collect(home)
		sort_rows(rows[:])
		render(rows[:], 0)
		return
	}

	term_setup()
	defer term_restore()
	install_signals()

	spinner := 0
	for !g_quit {
		// Everything this frame allocates is transient; wipe it at the end.
		context.allocator = context.temp_allocator

		rows := collect(home)
		sort_rows(rows[:])
		render(rows[:], spinner)
		spinner += 1

		free_all(context.temp_allocator)

		// Wait up to a refresh interval, but stay responsive to keystrokes.
		// Key polling only happens with a real terminal (raw mode); otherwise
		// `read` would block, so we just sleep and rely on signals to quit.
		waited := 0
		for waited < REFRESH_MS && !g_quit {
			if g_raw {
				if k := read_key(); k != 0 {
					if handle_key(k) do return // quit (defer restores the terminal)
					break // act on the keypress immediately
				}
			}
			time.sleep(POLL_MS * time.Millisecond)
			waited += POLL_MS
		}
	}
}

// ── Sorting ────────────────────────────────────────────────────────────────────

Sort_Key :: enum {
	Activity,
	Cpu,
	Mem,
	Pid,
}

g_sort: Sort_Key = .Activity
g_rev: bool

sort_rows :: proc(rows: []Row) {
	slice.sort_by(rows, row_less)
}

row_less :: proc(a, b: Row) -> bool {
	less: bool
	switch g_sort {
	case .Activity:
		ra, rb := state_rank(a.state), state_rank(b.state)
		less = ra != rb ? ra < rb : a.idle_s < b.idle_s
	case .Cpu:
		less = a.cpu > b.cpu
	case .Mem:
		less = a.mem_kb > b.mem_kb
	case .Pid:
		less = a.pid < b.pid
	}
	return g_rev ? !less : less
}

// Most "interesting" states sort first.
state_rank :: proc(s: string) -> int {
	switch s {
	case "working":
		return 0
	case "thinking":
		return 1
	case "active":
		return 2
	case "replied":
		return 3
	case "waiting":
		return 4
	case "idle":
		return 5
	case:
		return 6
	}
}

// ── Input handling (portable) ────────────────────────────────────────────────

g_raw: bool // true when the terminal is in raw mode (a real TTY)
g_quit: bool // set by a signal handler or the quit key

// Returns true when the user asked to quit.
handle_key :: proc(k: u8) -> bool {
	switch k {
	case 'q', 'Q', 3, 4: // q, Ctrl-C, Ctrl-D
		return true
	case 'a', 'A':
		g_sort = .Activity
	case 'c', 'C':
		g_sort = .Cpu
	case 'm', 'M':
		g_sort = .Mem
	case 'p', 'P':
		g_sort = .Pid
	case 'r', 'R':
		g_rev = !g_rev
	}
	return false
}

collect :: proc(home: string) -> [dynamic]Row {
	rows: [dynamic]Row

	oc := opencode_sessions(home) // directory -> session info, built once per frame

	for p in list_procs() {
		kind: string
		switch {
		case is_claude(p.args):
			kind = "claude"
		case is_opencode(p.args):
			kind = "opencode"
		case:
			continue
		}

		cwd, ok := proc_cwd(p.pid)
		if !ok do continue

		row := Row {
			pid      = p.pid,
			kind     = kind,
			project  = basename(cwd),
			cpu      = p.cpu,
			mem_kb   = p.rss_kb,
			uptime_s = p.uptime_s,
			state    = "?",
			model    = "-",
		}

		if kind == "claude" {
			claude_enrich(&row, home, cwd)
		} else if s, found := oc[cwd]; found {
			row.model = s.model
			row.detail = s.title
			row.idle_s = s.idle_s
			row.state = s.idle_s < 60 ? "active" : "idle"
		}

		append(&rows, row)
	}
	return rows
}

// ── Process discovery ─────────────────────────────────────────────────────────
// list_procs() and proc_cwd() are platform-specific (see platform_*.odin).

// Parse `ps` output (shared by the Linux and macOS implementations).
parse_ps :: proc(out: string) -> [dynamic]Proc {
	procs: [dynamic]Proc
	for line in strings.split_lines(out) {
		f := strings.fields(line)
		if len(f) < 6 do continue
		p := Proc {
			pid      = atoi(f[0]),
			cpu      = atof(f[2]),
			rss_kb   = atoi(f[3]),
			uptime_s = parse_etime(f[4]),
			args     = strings.join(f[5:], " "),
		}
		append(&procs, p)
	}
	return procs
}

is_claude :: proc(args: string) -> bool {
	if !strings.contains(args, "claude") do return false
	if strings.contains(args, "agentop") do return false
	if strings.contains(args, "Helper") || strings.contains(args, "Desktop") do return false
	return strings.contains(args, "cli.js") ||
		strings.contains(args, "claude-code") ||
		strings.contains(args, "/claude")
}

is_opencode :: proc(args: string) -> bool {
	if !strings.contains(args, "opencode") do return false
	if strings.contains(args, "agentop") do return false
	// Ignore one-shot subcommands that aren't an interactive session.
	for bad in ([]string{"opencode auth", "opencode serve", "opencode --version"}) {
		if strings.contains(args, bad) do return false
	}
	return true
}

// ── Claude Code: transcript parsing ────────────────────────────────────────────

claude_enrich :: proc(row: ^Row, home, cwd: string) {
	dir := fmt.tprintf("%s/.claude/projects/%s", home, encode_path(cwd))
	path, mtime, ok := newest_jsonl(dir)
	if !ok do return

	row.idle_s = int(time.duration_seconds(time.diff(mtime, time.now())))

	data, dok := tail(path, TAIL_BYTES)
	if !dok do return
	lines := strings.split_lines(data)

	// Walk backward: the last line drives the state; we keep walking until we
	// find the model from the most recent assistant turn.
	set_state := false
	count := 0
	#reverse for line in lines {
		if count >= MAX_LINES do break
		if len(strings.trim_space(line)) == 0 do continue
		count += 1

		v, err := json.parse(transmute([]byte)line, allocator = context.temp_allocator)
		if err != .None do continue

		typ := str(get(v, "type"))

		// Branch lives on most records; take it from the newest one that has it.
		if row.branch == "" {
			if b := str(get(v, "gitBranch")); b != "" do row.branch = b
		}

		// State comes from the most recent conversational turn. Skip the
		// interleaved attachment/summary/system/snapshot records.
		if !set_state && (typ == "assistant" || typ == "user") {
			derive_claude_state(row, v, typ)
			set_state = true
		}

		if row.model == "-" && typ == "assistant" {
			if m := str(get(get(v, "message"), "model")); m != "" {
				row.model = m
			}
		}

		if set_state && row.model != "-" do break
	}
}

derive_claude_state :: proc(row: ^Row, v: json.Value, typ: string) {
	content := get(get(v, "message"), "content")
	arr, is_arr := content.(json.Array)

	switch typ {
	case "assistant":
		tools: [dynamic]string
		text: string
		if is_arr {
			for item in arr {
				switch str(get(item, "type")) {
				case "tool_use":
					append(&tools, str(get(item, "name")))
				case "text":
					if text == "" do text = str(get(item, "text"))
				}
			}
		}
		if len(tools) > 0 {
			row.state = "working"
			row.detail = strings.concatenate({"⚙ ", strings.join(tools[:], ", ")})
		} else {
			row.state = "replied"
			row.detail = first_line(text)
		}
	case "user":
		// A user turn carrying tool_result means the agent is digesting output.
		thinking := false
		if is_arr {
			for item in arr {
				if str(get(item, "type")) == "tool_result" do thinking = true
			}
		}
		row.state = thinking ? "thinking" : "waiting"
		if is_arr {
			row.detail = "tool result"
		} else {
			row.detail = first_line(str(content))
		}
	case:
		row.state = "?"
	}
}

newest_jsonl :: proc(dir: string) -> (path: string, mtime: time.Time, ok: bool) {
	d, derr := os.open(dir)
	if derr != nil do return
	defer os.close(d)

	files, ferr := os.read_directory(d, -1, context.temp_allocator)
	if ferr != nil do return

	best_ns: i64 = 0
	for fi in files {
		if !strings.has_suffix(fi.name, ".jsonl") do continue
		ns := time.time_to_unix_nano(fi.modification_time)
		if ns > best_ns {
			best_ns = ns
			path = fi.fullpath
			mtime = fi.modification_time
			ok = true
		}
	}
	return
}

// ── OpenCode: sqlite session lookup ─────────────────────────────────────────────

OC_Session :: struct {
	model:  string,
	title:  string,
	idle_s: int,
}

opencode_sessions :: proc(home: string) -> map[string]OC_Session {
	out := make(map[string]OC_Session, allocator = context.temp_allocator)

	db := opencode_db(home)
	if db == "" do return out

	q := "SELECT directory, title, model, time_updated FROM session ORDER BY time_updated DESC"
	raw := run({"sqlite3", "-json", db, q})
	if len(strings.trim_space(raw)) == 0 do return out

	v, err := json.parse(transmute([]byte)raw, allocator = context.temp_allocator)
	if err != .None do return out
	arr, is_arr := v.(json.Array)
	if !is_arr do return out

	now_ms := time.time_to_unix_nano(time.now()) / 1_000_000
	for row in arr {
		dir := str(get(row, "directory"))
		if dir == "" do continue
		if _, seen := out[dir]; seen do continue // newest wins (query is sorted)

		updated := integer(get(row, "time_updated"))
		out[dir] = OC_Session {
			model  = oc_model(str(get(row, "model"))),
			title  = str(get(row, "title")),
			idle_s = int((now_ms - updated) / 1000),
		}
	}
	return out
}

opencode_db :: proc(home: string) -> string {
	if v := os.get_env("OPENCODE_DB", context.temp_allocator); v != "" {
		return v
	}
	xdg := os.get_env("XDG_DATA_HOME", context.temp_allocator)
	if xdg != "" {
		if c := fmt.tprintf("%s/opencode/opencode.db", xdg); exists(c) do return c
	}
	if c := fmt.tprintf("%s/.local/share/opencode/opencode.db", home); exists(c) do return c
	return ""
}

// OpenCode stores model as a JSON blob: {"id":"anthropic/claude-haiku-4.5",...}
oc_model :: proc(blob: string) -> string {
	if blob == "" do return "-"
	v, err := json.parse(transmute([]byte)blob, allocator = context.temp_allocator)
	if err != .None do return blob
	if id := str(get(v, "id")); id != "" do return id
	return blob
}

// ── Rendering ────────────────────────────────────────────────────────────────

INV :: "\x1b[7m"
DIM :: "\x1b[2m"
BOLD :: "\x1b[1m"
RST :: "\x1b[0m"
CYAN :: "\x1b[36m"
MAGENTA :: "\x1b[35m"
BMAGENTA :: "\x1b[95m"
BBLUE :: "\x1b[94m"
BYELLOW :: "\x1b[93m"

render :: proc(rows: []Row, spinner: int) {
	frames := [?]string{"⠋", "⠙", "⠹", "⠸", "⠼", "⠴", "⠦", "⠧", "⠇", "⠏"}
	w := term_width()
	act_w := max(12, w - FIXED)
	b := strings.builder_make(context.temp_allocator)

	// Summary stats.
	total_cpu: f64
	total_mem, n_cc, n_oc: int
	for r in rows {
		total_cpu += r.cpu
		total_mem += r.mem_kb
		if r.kind == "claude" {n_cc += 1} else {n_oc += 1}
	}

	strings.write_string(&b, "\x1b[H") // home — clear-per-line below keeps it flicker-free
	spin := frames[spinner % len(frames)]

	// Header block.
	line(
		&b,
		fmt.tprintf("%s%s%s %sclanker control%s %s· claude code & opencode%s", CYAN, spin, RST, BOLD, RST, DIM, RST),
	)
	line(
		&b,
		fmt.tprintf(
			"%s%d agents%s  %s·%s  %d cc · %d oc  %s·%s  CPU %.1f%%  %s·%s  MEM %s",
			BOLD, len(rows), RST, DIM, RST, n_cc, n_oc, DIM, RST, total_cpu, DIM, RST, human_mem(total_mem),
		),
	)
	line(&b, "")

	// Column header (full-width inverse bar).
	hdr := strings.concatenate(
		{
			" ", fit("PID", W_PID), " ", fit("AGENT", W_AGENT), " ", fit("MODEL", W_MODEL),
			" ", fit("PROJECT", W_PROJ), " ", fit("BRANCH", W_BRANCH), " ", fit("STATE", W_STATE),
			" ", fitr("%CPU", W_CPU), " ", fitr("MEM", W_MEM), " ", fitr("UP", W_UP),
			" ", fitr("IDLE", W_IDLE), "  ", fit("ACTIVITY", act_w),
		},
	)
	line(&b, strings.concatenate({INV, fit(hdr, w), RST}))

	if len(rows) == 0 {
		line(&b, "")
		line(&b, fmt.tprintf("%s   no claude code or opencode sessions running%s", DIM, RST))
	}
	for r in rows {
		line(&b, build_row(r, act_w))
	}

	// Footer (full-width inverse help bar).
	line(&b, "")
	names := [Sort_Key]string {
		.Activity = "activity",
		.Cpu      = "cpu",
		.Mem      = "mem",
		.Pid      = "pid",
	}
	arrow := g_rev ? "↑" : "↓"
	foot := fmt.tprintf(
		" q quit  a activity  c cpu  m mem  p pid  r reverse     sort: %s %s ",
		names[g_sort],
		arrow,
	)
	line(&b, strings.concatenate({INV, fit(foot, w), RST}))

	strings.write_string(&b, "\x1b[J") // wipe anything left over from a taller frame
	term_out(strings.to_string(b))
}

// Append a logical line: clear to end-of-line (so leftovers vanish) then newline.
line :: proc(b: ^strings.Builder, s: string) {
	strings.write_string(b, s)
	strings.write_string(b, "\x1b[K\n")
}

build_row :: proc(r: Row, act_w: int) -> string {
	dot, scol := state_style(r.state)
	agent_color := r.kind == "claude" ? BMAGENTA : BBLUE
	cpu_color := r.cpu >= 20 ? BYELLOW : ""
	state_cell := strings.concatenate({scol, dot, " ", fit(r.state, W_STATE - 2), RST})

	return strings.concatenate(
		{
			" ", DIM, fit(fmt.tprintf("%d", r.pid), W_PID), RST,
			" ", agent_color, fit(r.kind, W_AGENT), RST,
			" ", MAGENTA, fit(r.model, W_MODEL), RST,
			" ", BOLD, fit(r.project, W_PROJ), RST,
			" ", CYAN, fit(r.branch, W_BRANCH), RST,
			" ", state_cell,
			" ", cpu_color, fitr(fmt.tprintf("%.1f", r.cpu), W_CPU), RST,
			" ", fitr(human_mem(r.mem_kb), W_MEM),
			" ", fitr(human_dur(r.uptime_s), W_UP),
			" ", fitr(human_dur(r.idle_s), W_IDLE),
			"  ", DIM, fit(r.detail, act_w), RST,
		},
	)
}

state_style :: proc(state: string) -> (dot: string, color: string) {
	switch state {
	case "working":
		return "●", "\x1b[92m" // bright green
	case "thinking":
		return "◐", "\x1b[96m" // bright cyan
	case "replied":
		return "○", "\x1b[32m" // green
	case "active":
		return "●", "\x1b[94m" // bright blue
	case "waiting":
		return "○", "\x1b[33m" // yellow
	case "idle":
		return "○", "\x1b[90m" // gray
	case:
		return "·", "\x1b[90m"
	}
}

// ── JSON helpers ───────────────────────────────────────────────────────────────

get :: proc(v: json.Value, key: string) -> json.Value {
	o, ok := v.(json.Object)
	if !ok do return nil
	return o[key]
}

str :: proc(v: json.Value) -> string {
	s, ok := v.(json.String)
	if !ok do return ""
	return string(s)
}

integer :: proc(v: json.Value) -> i64 {
	#partial switch n in v {
	case json.Integer:
		return i64(n)
	case json.Float:
		return i64(n)
	}
	return 0
}

// ── Small utilities ────────────────────────────────────────────────────────────

run :: proc(cmd: []string) -> string {
	// process_exec takes an argv slice and never invokes a shell, so the command
	// arguments are passed verbatim — no shell-injection surface.
	runp := os.process_exec
	_, stdout, _, err := runp(os.Process_Desc{command = cmd}, context.temp_allocator)
	if err != nil do return ""
	return string(stdout)
}

tail :: proc(path: string, n: int) -> (string, bool) {
	f, err := os.open(path)
	if err != nil do return "", false
	defer os.close(f)

	size, serr := os.file_size(f)
	if serr != nil do return "", false

	start := max(i64(0), size - i64(n))
	want := int(size - start)
	buf := make([]byte, want, context.temp_allocator)
	read, rerr := os.read_at(f, buf, start)
	if rerr != nil && read == 0 do return "", false
	return string(buf[:read]), true
}

exists :: proc(path: string) -> bool {
	f, err := os.open(path)
	if err != nil do return false
	os.close(f)
	return true
}

// Claude encodes a cwd into a directory name by replacing '/' and '.' with '-'.
encode_path :: proc(p: string) -> string {
	b := strings.builder_make(context.temp_allocator)
	for c in p {
		if c == '/' || c == '.' {
			strings.write_rune(&b, '-')
		} else {
			strings.write_rune(&b, c)
		}
	}
	return strings.to_string(b)
}

basename :: proc(p: string) -> string {
	if i := strings.last_index(p, "/"); i >= 0 && i + 1 < len(p) {
		return p[i + 1:]
	}
	return p
}

first_line :: proc(s: string) -> string {
	t := strings.trim_space(s)
	if i := strings.index(t, "\n"); i >= 0 {
		return t[:i]
	}
	return t
}

// Left-justify to `w` display columns, truncating (rune-safe) with an ellipsis.
fit :: proc(s: string, w: int) -> string {
	n := utf8.rune_count_in_string(s)
	if n == w do return s
	if n < w {
		return strings.concatenate({s, spaces(w - n)})
	}
	// Truncate to w-1 runes, then add "…".
	keep := 0
	count := 0
	for _, idx in s {
		if count == w - 1 {
			keep = idx
			break
		}
		count += 1
	}
	return strings.concatenate({s[:keep], "…"})
}

// Right-justify to `w` display columns.
fitr :: proc(s: string, w: int) -> string {
	n := utf8.rune_count_in_string(s)
	if n >= w do return fit(s, w)
	return strings.concatenate({spaces(w - n), s})
}

spaces :: proc(n: int) -> string {
	if n <= 0 do return ""
	return strings.repeat(" ", n)
}

human_mem :: proc(kb: int) -> string {
	if kb >= 1024 * 1024 {
		return fmt.tprintf("%.1fG", f64(kb) / (1024 * 1024))
	}
	if kb >= 1024 {
		return fmt.tprintf("%dM", kb / 1024)
	}
	return fmt.tprintf("%dK", kb)
}

human_dur :: proc(s: int) -> string {
	if s <= 0 do return "-"
	if s < 60 do return fmt.tprintf("%ds", s)
	if s < 3600 do return fmt.tprintf("%dm", s / 60)
	if s < 86400 do return fmt.tprintf("%dh%dm", s / 3600, (s % 3600) / 60)
	return fmt.tprintf("%dd%dh", s / 86400, (s % 86400) / 3600)
}

// etime is one of: SS, MM:SS, HH:MM:SS, or D-HH:MM:SS.
parse_etime :: proc(s: string) -> int {
	days := 0
	rest := s
	if i := strings.index(s, "-"); i >= 0 {
		days = atoi(s[:i])
		rest = s[i + 1:]
	}
	parts := strings.split(rest, ":")
	secs := 0
	for p in parts {
		secs = secs * 60 + atoi(p)
	}
	return days * 86400 + secs
}

atoi :: proc(s: string) -> int {
	n, _ := strconv.parse_int(strings.trim_space(s))
	return n
}

atof :: proc(s: string) -> f64 {
	n, _ := strconv.parse_f64(strings.trim_space(s))
	return n
}
