# clanker control

A tiny `top` for AI coding agents, written in [Odin](https://odin-lang.org).

A from-scratch rewrite of [agentop](https://github.com/ktamas77/agentop),
deliberately scoped down to the only two agents we care about:

- **Claude Code**
- **OpenCode**

## How it works

Twice a second (every 500ms) it:

1. Lists processes via `ps -axww -o pid=,ppid=,pcpu=,rss=,etime=,args=`.
2. Keeps the ones that look like Claude Code or OpenCode.
3. Resolves each process's working directory by reading `/proc/<pid>/cwd`.
4. Enriches each row with live session data:
   - **Claude Code** — finds the newest transcript under
     `~/.claude/projects/<encoded-cwd>/*.jsonl` (the cwd with `/` and `.`
     replaced by `-`), then parses the tail to derive the model, git branch,
     state and current activity. Idle time comes from the file's mtime.
   - **OpenCode** — queries `session` in the SQLite DB
     (`$OPENCODE_DB`, else `$XDG_DATA_HOME/opencode/opencode.db`, else
     `~/.local/share/opencode/opencode.db`) via the `sqlite3` CLI, matching
     the session whose `directory` equals the process cwd.

No data ever leaves the machine, it only reads local process and session state.

## Keys

| Key       | Action                                   |
| --------- | ---------------------------------------- |
| `q`       | quit (Ctrl-C / Ctrl-D also work)         |
| `a`       | sort by activity (most active first)     |
| `c`       | sort by CPU                              |
| `m`       | sort by memory                           |
| `p`       | sort by PID                              |
| `r`       | reverse the current sort                 |

## States

| State    | Meaning                                          |
| -------- | ------------------------------------------------ |
| working  | Claude is running a tool (tool name in ACTIVITY) |
| thinking | digesting a tool result                          |
| replied  | last turn was assistant text                     |
| waiting  | waiting on the user                              |
| active   | OpenCode session updated in the last minute      |
| idle     | no recent activity                               |

## Platforms

| OS      | Status       | Notes                                                    |
| ------- | ------------ | -------------------------------------------------------- |
| Linux   | full         | cwd via `/proc/<pid>/cwd`                                |
| macOS   | full         | cwd via `lsof`                                           |
| Windows | experimental | UI renders, but process/cwd discovery isn't wired up yet |

Runtime deps: `ps` and `sqlite3` on `PATH` (Unix).

## Install

Grab a prebuilt binary from the [Releases](../../releases) page
(`linux-x86_64`, `macos-arm64`, `windows-x86_64.exe`) — these are built and
published automatically by the GitHub Actions workflow on every push.

## Build & run

Needs [Odin](https://odin-lang.org) (tested on `dev-2026-05`).

```sh
./build.sh             # produces ./clanker-control
./clanker-control      # live dashboard, refreshes every 500ms
./clanker-control once # render a single frame and exit (good for piping)
```

## Layout

```
main.odin              portable core: discovery, parsing, sorting, rendering
platform_posix.odin    Unix terminal/input/signals + `ps` listing (linux+darwin)
platform_linux.odin    cwd resolution via /proc
platform_darwin.odin   cwd resolution via lsof
platform_windows.odin  Windows stubs (ANSI console, no discovery yet)
.github/workflows/     CI: build + release for all three platforms
```
