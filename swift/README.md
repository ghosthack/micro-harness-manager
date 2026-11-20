# Microhm for macOS (Swift)

A native macOS port of micro-harness-manager: AppKit, Core Text and Swift, with no
third-party packages. Everything in the main [README](../README.md) applies:
- the sidebar of agent and shell sessions with their states;
- sessions that outlive the app in a background daemon;
- the harness plugins;
- the MCP server and the phone page;
- usage budgets;
- the menu-bar icon.

The exceptions are listed under [Differences from the Java app](#differences-from-the-java-app).

## Build and run

```sh
scripts/build-app.sh                 # dist/Microhm.app (release, ad-hoc signed)
open dist/Microhm.app
swift test                           # 798 tests
scripts/phone-e2e.sh                 # the phone page's Playwright suite against the Swift server
```

`SIGN_IDENTITY="Developer ID Application: …" scripts/build-app.sh` signs for distribution.

The bundle holds three executables in `Contents/MacOS`:
- `Microhm` is the app.
- `microhm-mux` is the session daemon and its CLI (`list`, `capture`, `attach`, `shutdown`, …).
- `microhm-host` is the background host. It keeps MCP, the phone page and the menu-bar icon
  running after the app quits, and hands them back when the app reopens.

## Side by side with the Java app

| | Java | Swift |
|---|---|---|
| State directory | `~/.micro-harness-manager` | `~/.micro-harness-manager-swift` (`MICROHM_HOME`) |
| Daemon home | `…/mux` | `…/mux` (`MICROHM_MUX_HOME`) |
| MCP port | 7392 | 7402 |
| Phone port | 7393 | 7403 |

The daemon speaks the same wire protocol (v1) as the Java one. The Java `microhm-mux` CLI
drives a Swift daemon, and the other way round. A Unix socket path must stay under 104
bytes, so keep `MICROHM_MUX_HOME` short.

## Layout

See [PORTING.md](PORTING.md) for the module map: `MicrohmVT` (emulator), `MicrohmPTY`,
`MicrohmMux` (daemon, client, CLI), `MicrohmCore` (harnesses, registry, settings, controller,
MCP, phone), `MicrohmTerminal` (the terminal view), `MicrohmStatusItem` and `MicrohmApp`.

## Differences from the Java app

- macOS only (14+). There is no ConPTY or Windows/Linux tray code.
- `forkpty` replaces the `ControllingTerminal` JVM trampoline.
- The Performance tab shows the process's memory, CPU and threads in place of JVM heap and GC.
- `MICROHM_UI_DEBUG=<dir>` turns on a development hook. On SIGUSR1 the app runs commands
  from `<dir>/command` (`select`, `new`, `settings N`, `type …`, `snapshot NAME`, `quit`, …)
  and renders its own windows to PNG, so the UI can be checked without screen-recording
  permission.
- Additions: dropping files on a terminal types their shell-quoted paths, and the Budgets panel folds
  away to a one-line summary (its last good figures stay up, marked stale, when a refresh fails).
