<p align="center">
  <img src="packaging/icons/micro-harness-manager.png" width="128" height="128" alt="micro-harness-manager resistor logo">
</p>

# micro-harness-manager

A desktop app for running coding agents (Claude Code, Codex, Cursor Agent, Grok,
OpenCode, Pi, Muse) and shells side by side. A sidebar lists your sessions with what
each one is doing (working, waiting for you, idle), and the selected session's live
terminal fills the rest of the window. Sessions run in a background daemon, so they
survive closing and reopening the app.

It can also expose the sessions to the agents themselves: an optional MCP server lets an
agent in one session list, read, type into and wait on the others.

Runs on macOS, Linux and Windows 10 (1809+) / 11. Needs Java 25+ and Maven 3.6.3+.
Tested on macOS and Windows 11 with JDK 26, and on Ubuntu 24.04 with JDK 25 and Maven 3.8.

## Features

- **Sidebar.** Sessions with their state (working, waiting for input, idle, dead), sort by
  name, folder or status, filters by status and harness, and optional grouping by
  project folder.
- **Sessions.** Open…, New here, Shell here, Duplicate, Resume, Reload, Close (asks the
  harness and its shell to exit), Kill, and batch Close / Remove dead.
- **Harnesses.** Plugins for Claude Code, Codex, Cursor Agent, Grok, OpenCode, Pi and
  Muse detect each session's state from its screen and know how to start, resume and
  quit it.
- **Usage.** A budget panel and a usage dialog for the providers' plan limits.
- **Agents (MCP).** An optional MCP server whose tools (`list`, `read`, `send`, `keys`,
  `notify`, `spawn`, `kill`) let an agent in one session see and drive the others. It is
  off by default: turn it on in Settings → Agents, and sessions created or resumed from
  then on get it registered. It keeps working after you quit the app: a small background
  host serves the same tools on the same port until the last session ends, and hands
  back to the app when you reopen it (its log is `~/.micro-harness-manager/mcp-host.log`).
- **Background icon.** While sessions run with the app closed, a menu-bar icon (macOS) or
  system-tray icon (Windows; Linux desktops with a tray) shows how many are running and
  whether MCP is serving, and opens the app (end sessions from the app). On by default;
  Settings → Sessions → Background icon, or "Hide This Icon" in its menu, turns it off.
- **Terminal.** Right-click (Ctrl+click on macOS) for Copy, Paste, Select All, Page Up and
  Page Down; when the program tracks the mouse the click goes to it, and
  Shift+right-click still opens the menu. On macOS, Option+letter is Meta by default
  (word motion, shortcuts such as Option+Enter); Settings → Input → "Use Option as Meta"
  turns that off so Option composes accents natively (Option+e, e types é).
- **Look.** Light and dark FlatLaf themes, and the terminal font and palette of your
  choice.

## Install

Each [release](https://github.com/ghosthack/micro-harness-manager/releases) carries a signed
installer per platform: a DMG for macOS (Apple silicon), an `.exe` for Windows x64 and a
`.deb` for Linux x64, plus portable archives for Windows and Linux. They bundle their own
Java runtime. See [packaging/README.md](packaging/README.md) for how releases are built.

## Run from source


```sh
./run.sh        # macOS, Linux
run.cmd         # Windows
```

This builds the jar when the sources changed and launches it. The session daemon starts
on demand from the same jar and keeps running after you quit the app.

`./microhm-mux` (`microhm-mux.cmd` on Windows) is the daemon's command-line client:

```sh
./microhm-mux list               # list sessions
./microhm-mux capture mhm-foo    # print a session's screen as text
./microhm-mux attach mhm-foo     # attach this terminal (Ctrl+] detaches; not on Windows)
./microhm-mux shutdown           # stop the daemon and every session on it
```

## Configuration

| | |
|---|---|
| State directory | `~/.micro-harness-manager` |
| Settings | `settings.properties` beside the registry (e.g. `terminal.option-as-meta=on\|off`) |
| Registry override | `-Dmicrohm.registry=/path/sessions.json` |
| Session daemon home | `~/.micro-harness-manager/mux` (`-Dmicrohm.mux.home`, `MICROHM_MUX_HOME`) |
| Session names | `mhm-…` |
| MCP port (default) | 7392 |
| MCP server name | `micro-harness-manager` |
| MCP token variable | `MHM_MCP_TOKEN` |

Settings, the per-session MCP config files (`mcp/`) and the single-instance lock
(`instance.lock`) all live beside the registry file, so pointing `-Dmicrohm.registry` at
a scratch path isolates a whole run. The tests do exactly that.

## Modules

| Module | What it is | Main / test lines |
|---|---|---|
| `vt` | Terminal emulator core: VT tokenizer, `TerminalEmulator` (screen model and interpreter), `HeadlessTerminal` (daemon side), `ScreenSerializer` (redraw on attach), Unicode 17 widths | 4.5k / 4.0k |
| `pty` | Pseudo-terminal processes over the Java FFM API (`PtyProcess`): POSIX ptys and Windows ConPTY, no native code of its own | 1.8k / 0.5k |
| `mux` | The session daemon and its client, on `vt` and `pty` | 6.0k / 4.1k |
| `app` | The Swing app, with its own terminal view (`TerminalView`) | 18.6k / 9.1k |

The shipped jar's runtime dependencies are FlatLaf, Jackson and SLF4J.

## How it works

- **Processes (`pty`).** On macOS and Linux the child is started with `posix_spawn` as a
  session leader, with the PTY slave as its stdin. Linux makes that its controlling
  terminal. macOS needs an explicit `ioctl(TIOCSCTTY)` from the child, which
  `posix_spawn` cannot do, so there the child is first a small JVM
  (`ControllingTerminal`, from the same jar) that takes the terminal and `execve`s the
  program under the same pid, with exactly the intended environment, no inherited
  descriptors and default signals. That adds well under a tenth of a second to opening
  a session, and gives shells job control and the daemon a foreground process group to
  read. A reaper thread `waitpid`s the child, and the master descriptor is closed
  exactly once. On Windows the child runs in a ConPTY pseudoconsole, created suspended
  so it joins a kill-on-close job object first: killing a session ends its whole process
  tree. The shell is pwsh, else Windows PowerShell, else `%ComSpec%`, and Ctrl+C works
  even when micro was started from something that ignores it (Windows OpenSSH does).
- **Emulation (`vt`).** `TerminalEmulator` implements the xterm subset the harnesses
  use: margins and scroll regions (including Codex's inline viewport on the main
  screen), alternate screens, pending wrap, wide and combining characters, full SGR with
  colon forms and underline styles, mouse, focus, bracketed-paste and synchronized-output
  modes, and the kitty keyboard flags. Its behaviour on 49 hand-written cases, 40 fuzz
  seeds and 11 real recordings is pinned in golden files under
  `vt/src/test/resources/golden`. After an intended behaviour change, regenerate them
  with `mvn -pl vt test -Dvt.golden.update=true` and review the diff.
- **Display (`app/terminal`).** `TerminalView` paints the screen model directly, and
  `SessionTerminal` connects it to a daemon attachment; the rest of the app only uses
  `SessionTerminal`'s small API. Frames are coalesced to about 60 fps, and the key,
  mouse and paste encoders are pure functions with table tests. The view paints in
  device pixels: on a 2× display the font is measured at twice its size, so cells can be
  half a point wide or tall (Menlo 14 gets 8.5 × 16.5-point cells, its own proportions,
  where whole points would space the lines about 6% too far apart). Characters made to
  tile are drawn as geometry fitted to the cell, never from a font: box drawing, block
  elements, braille (dots at exact sub-pixel positions, so the pitch stays even), the
  sextants, octants and other mosaics of Symbols for Legacy Computing (read from their
  Unicode names) and the scan lines. A font's glyph box is never exactly the cell, so
  font glyphs would leave gaps and steps between cells.

## Tests

`mvn test` runs 1,146 tests: vt 463, pty 32, mux 154, app 497. Each platform skips the
other's PTY tests, and Windows runs PowerShell session tests of its own. The tests spawn
real PTYs and daemons in temporary homes and never touch `~/.micro-harness-manager`.

## Known gaps

- macOS keyboard input (Option as Meta, dead keys, IME) is unit tested with synthetic
  events but not yet by hand. With Option as Meta on (the default), Option+e can't start
  an accent; turn the setting off to type accents with Option.
- Not supported: text blink, underline colour (SGR 58), OSC 8 hyperlinks, rectangular
  selection, copy-on-select, DECLRMM/DECCOLM.
- Windows: PowerShell sessions don't report their working directory, so "New here" and
  Duplicate use the session's launch directory (cmd does report it); the CLI's `attach`
  is POSIX only.

## License

MIT; see [LICENSE](LICENSE). Third-party components keep their own licenses: see
[THIRD-PARTY.md](THIRD-PARTY.md).
