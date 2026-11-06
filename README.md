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

## Run

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

State lives in `~/.micro-harness-manager`: the session registry, settings, MCP config and
the daemon's home (`mux/`). The MCP server, off by default, listens on port 7392. See
[app/README.md](app/README.md) for the app's features and settings.

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
- **Display (`app/terminal`).** `TerminalView` paints the screen model directly, in
  device pixels: merged background runs, run-wise text, font fallback, and geometry for
  every character made to tile (box drawing, blocks, braille, sextants, octants and the
  other block mosaics), so they join without gaps. Frames are coalesced to about 60 fps,
  and the key, mouse and paste encoders are pure functions with table tests.

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
- No installers or signed packages yet; `run.sh` / `run.cmd` launch the jar.

## License

MIT; see [LICENSE](LICENSE). Third-party components keep their own licenses: see
[THIRD-PARTY.md](THIRD-PARTY.md).
