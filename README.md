# micro-harness-manager

A smaller harness-manager: the same sidebar of coding-agent and shell sessions, the same
state detection and MCP session-controller tools, but local sessions only, and built on
its own terminal stack. It has no tmux, no remote (SSH) machines and no harness-stim, and
it ships without JediTerm, the Kotlin standard library, pty4j or JetBrains annotations.

macOS, Linux and Windows 10 (1809+) / 11. Java 25+ (built and tested on JDK 26, on macOS
and Windows 11).

## Modules

| Module | What it is | Main / test lines |
|---|---|---|
| `vt` | Terminal emulator core: VT tokenizer, `TerminalEmulator` (screen model + interpreter), `HeadlessTerminal` (daemon side), `ScreenSerializer` (redraw on attach), Unicode 17 widths | 4.5k / 4.0k |
| `pty` | Pseudo-terminal processes over the Java FFM API (`PtyProcess`): POSIX ptys and Windows ConPTY, no native code of its own | 1.8k / 0.5k |
| `mux` | The session daemon and its client, forked from jmux, on `vt` and `pty` | 6.0k / 4.1k |
| `app` | The Swing app, ported from harness-manager, with its own terminal view (`TerminalView`) | 18.6k / 9.1k |

Runtime dependencies of the shipped jar: FlatLaf, Jackson, SLF4J. None of JediTerm,
Kotlin, pty4j or JetBrains annotations is a dependency at any scope, tests included.

## Run

```sh
./run.sh        # macOS, Linux
run.cmd         # Windows
```

It rebuilds the shaded jar (`app/target/microhm-app-0.1.0-SNAPSHOT.jar`) when sources
changed and launches it. The session daemon is started on demand from the same jar, and
outlives the app: quit and relaunch, and the sessions are still there.

`./microhm-mux` (`microhm-mux.cmd` on Windows) is the daemon's command-line client, run
from the same jar:

```sh
./microhm-mux list               # sessions on micro's daemon
./microhm-mux capture mhm-foo    # one session's screen as text
./microhm-mux attach mhm-foo     # attach this terminal (Ctrl+] detaches; not on Windows)
./microhm-mux shutdown           # stop the daemon and every session on it
```

## Isolation from harness-manager

The two run side by side and share nothing: micro keeps its state in
`~/.micro-harness-manager` (registry, settings, MCP config, and the daemon home `mux/`),
serves MCP on port 7392 as `micro-harness-manager`, names sessions `mhm-…`, and reads
`MICROHM_*` variables instead of `JMUX_*`. See [app/README.md](app/README.md) for the
full table.

## How the pieces replace the libraries

- **pty4j → `pty`.** The child is started with `posix_spawn`: `POSIX_SPAWN_SETSID` makes
  it a session leader, and a file action opens the PTY slave by path as fd 0. On Linux
  that makes the PTY its controlling terminal. macOS needs an explicit
  `ioctl(TIOCSCTTY)` from the child, which `posix_spawn` cannot do, so there the child
  is first a small JVM (`ControllingTerminal`, from the same jar) that takes the
  terminal and `execve`s the program under the same pid, with exactly the intended
  environment, no inherited descriptors and default signals. It adds a JVM start (well
  under a tenth of a second warm) to opening a session, and needs no perl, bash or
  native helper. Without it zsh would have no controlling terminal: no job control,
  and no foreground process group for the daemon to read. The master descriptor is closed exactly once and never used after (a late
  write fails instead of hitting a reused fd); a reaper thread `waitpid`s the child.
  On Windows the child runs in a ConPTY pseudoconsole (`CreatePseudoConsole`, then
  `CreateProcessW` with the pseudoconsole attribute), created suspended so it joins a
  kill-on-close job object first: killing a session ends its whole process tree. The
  shell is pwsh, else Windows PowerShell, else `%ComSpec%`, and harness commands are
  quoted for PowerShell. The process inherits normal Ctrl+C handling even when micro was
  started from something that ignores it (Windows OpenSSH does).
- **jediterm-core → `vt`.** `TerminalEmulator` implements the xterm subset the harnesses
  use: margins and scroll regions (including Codex's inline viewport on the main
  screen), alternate screens, pending wrap, wide and combining characters, full SGR with
  colon forms and underline styles, mouse/focus/bracketed-paste/synchronized-output
  modes and the kitty keyboard flags. Its behaviour on 49 hand-written cases, 40 fuzz
  seeds (state after every operation) and 11 real recordings is frozen in golden files
  under `vt/src/test/resources/golden`, generated while JediTerm was still a test oracle
  and checked against it; every deliberate difference (xterm behaviour where JediTerm
  deviates) is pinned in `KnownDifferencesTest`. After an intended behaviour change,
  regenerate them with `mvn -pl vt test -Dvt.golden.update=true` and review the diff.
- **jediterm-ui → `app/terminal`.** `TerminalView` paints the model directly (merged
  background runs, run-wise text, font fallback, geometry for every character made to tile:
  box drawing, blocks, braille, sextants, octants and the other block mosaics), coalesces
  frames to ~60 fps, and has pure, table-tested key, mouse and paste encoders. The
  client answers only the colour-scheme query (`CSI ?996n`).

## Tests

`mvn test` runs 1,144 tests: vt 463, pty 32, mux 154, app 495; each platform skips the
other's PTY tests (Windows also skips the POSIX-shell live daemon tests, and runs
PowerShell session tests of its own). They spawn real PTYs and daemons in temporary
homes; none touch `~/.micro-harness-manager`. The golden files and recordings are pinned
to exact bytes in `.gitattributes`, so a Windows checkout with `core.autocrlf` passes too.

## Known gaps

- Real macOS keyboard input (Option as Meta, dead keys, IME) is implemented and unit
  tested with synthetic events but has not been tried by hand. With Option as Meta (the
  default), Option+e is Meta and cannot also start an accent; turn the setting off to type
  accents with Option (see [app/README.md](app/README.md#the-terminal)).
- Not supported: text blink, underline colour (SGR 58), OSC 8 hyperlinks, rectangular
  selection, copy-on-select, DECLRMM/DECCOLM.
- Windows: PowerShell sessions don't report their working directory, so "New here" and
  Duplicate fall back to the session's launch directory (cmd does report it); the CLI's
  `attach` is POSIX only; keyboard input in the window was tested with synthetic events,
  not by hand.
- No packaging (jpackage, signing) yet; `run.sh` / `run.cmd` launch the shaded jar.

## License

MIT; see [LICENSE](LICENSE). Third-party components keep their own licenses: see
[THIRD-PARTY.md](THIRD-PARTY.md).
