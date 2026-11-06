# micro-harness-manager — app

The Swing app: a sidebar of coding-agent and shell sessions on the left, the selected
session's live terminal on the right. Every session runs on the `mux` session daemon on
the local machine.

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
  then on get it registered.
- **Look.** Light and dark FlatLaf themes, and the terminal font and palette of your
  choice.

## State and configuration

| | |
|---|---|
| State directory | `~/.micro-harness-manager` |
| Registry override | `-Dmicrohm.registry=/path/sessions.json` |
| Session daemon home | `~/.micro-harness-manager/mux` (`-Dmicrohm.mux.home`, `MICROHM_MUX_HOME`) |
| Session names | `mhm-…` |
| MCP port (default) | 7392 |
| MCP server name | `micro-harness-manager` |
| MCP token variable | `MHM_MCP_TOKEN` |

Settings (`settings.properties`), the per-session MCP config files (`mcp/`) and the
single-instance lock (`instance.lock`) all live beside the registry file, so pointing
`-Dmicrohm.registry` at a scratch path isolates a whole run. The tests do exactly that,
and surefire sets both overrides to `app/target/test-state` as a backstop.

## Build and run

From the repo root: `./run.sh` (`run.cmd` on Windows) builds the reactor (`vt`, `pty`,
`mux`, `app`) when anything changed and launches the shaded jar with
`--enable-native-access=ALL-UNNAMED`.
The jar also carries the daemon: the client starts it from the same class path the
first time a session is created.

Tests: `mvn -pl app test`.

## The terminal

The embedded terminal is the app's own: `TerminalView` paints the `vt` module's
`TerminalEmulator` directly, and `SessionTerminal` connects it to a daemon attachment.
Everything lives in the `terminal` package; the rest of the app only uses
`SessionTerminal`'s small API. Key, mouse and paste encoding are pure functions
(`KeyEncoder`, `MouseEncoder`, `PasteEncoder`) with table tests.

The view paints in device pixels: on a 2× Retina display the font is measured at twice
its size and cells are whole device pixels, so they can be half a point wide or tall.
Menlo 14 gets 8.5 × 16.5-point cells, its own proportions, where whole points round to
8 × 17 and space the lines about 6% too far apart. Swing's own coordinates (layout, mouse,
the input method's caret) stay in points and are converted at those edges, and moving
the window to a screen of another density re-measures the cell.

Characters made to tile into lines and pictures are drawn as geometry fitted to the cell,
never from a font: box drawing, block elements, braille (an even 2 × 4 dot grid, dots at
exact sub-pixel positions so the pitch stays even when the cell is not a multiple of
2 × 4 pixels, as Codex's braille logo needs), the sextants, octants, eighth bars and partial blocks of
Symbols for Legacy Computing (read from the Unicode names, so every 2 × 4 pattern is
covered), and the scan lines. No font's glyph box is the cell, and a fallback font's is
smaller and on its own baseline, which leaves gaps and steps between cells. The few
tile-designed pictograph pieces micro cannot draw are stretched from whatever font has
them to fill the cell exactly. Other glyphs from a fallback font stay on the text
baseline, where they line up with the text around them.

Right-click (Ctrl+click on macOS) opens a menu with Copy, Paste, Select All, Page Up and
Page Down. When the program in the terminal tracks the mouse, the click goes to it
instead; Shift+right-click still opens the menu.

On macOS, Option+letter and Option+digit are Meta by default (word motion, agent
shortcuts such as Option+Enter). Settings → Input → "Use Option as Meta" turns that off,
and Option then composes as it does natively (Option+e, e types é). The setting is
`terminal.option-as-meta=on|off` in `settings.properties`, and it applies live.
