# Swift port — conventions

The native macOS port of micro-harness-manager. The Java sources in `../vt`, `../pty`,
`../mux` and `../app` are the specification: port behaviour faithfully, including
comments that explain *why*. Don't redesign. Where Java uses a JVM-only trick (FFM,
the `ControllingTerminal` re-exec, AOT caches, FlatLaf, Swing), use the native macOS
equivalent.

## Module map

| Swift target | Java source | Notes |
|---|---|---|
| `MicrohmShared` | — | `MicrohmPaths` (state dirs, ports), `Log`. Shared by all. |
| `MicrohmVT` | `vt/` | Terminal emulator core. Same type names (`TerminalEmulator`, `HeadlessTerminal`, `Line`, `Style`, `ScreenSerializer`, `VtTokenizer`, `KeyNames`, `CharWidth`…). |
| `MicrohmPTY` | `pty/` | POSIX ptys only (`forkpty`/`posix_spawn` + `TIOCSCTTY` natively; no ConPTY). |
| `MicrohmMux` | `mux/` | Daemon (server), client library, CLI logic, protocol v1 **wire-identical** to Java. |
| `microhm-mux` | `mux/.../Main`, `cli/` | Executable: the CLI *and* the daemon (`microhm-mux serve …`, the way the Java launcher starts it). |
| `MicrohmCore` | `app/` minus `ui/`, `terminal/` | Harness plugins, state detection, registry, settings, usage, status, control (SessionController), session launch, MCP server, MCP host, phone server (serves `Resources/web` verbatim). |
| `MicrohmTerminal` | `app/terminal/` | AppKit `TerminalView` (Core Text/Core Graphics), key/mouse/paste encoders, box drawing, palettes, fonts, links, selection. |
| `MicrohmApp` | `app/ui/`, `MicroHarnessManagerApp` | The AppKit app: main window, sidebar, dialogs, settings, menu-bar icon. |
| `microhm-host` | `app/mcphost/McpHost` | Headless background host serving MCP + phone after the app quits. |

## Rules

- **Swift 6 toolchain, language mode 5** (set in `Package.swift`), macOS 14+. No
  third-party packages: Foundation, Darwin, Network, AppKit, CoreText, CoreImage only.
- **Names.** Keep Java class and method names (Swift-cased) so modules ported in
  parallel can code against the Java signatures and still line up. Java records become
  structs, enums stay enums, interfaces become protocols. Make the API another module
  uses `public`.
- **Concurrency.** Threads + locks (`NSLock`, `DispatchQueue`) the way Java does it are
  fine. Don't fight strict concurrency. Mark shared mutable classes `@unchecked Sendable`.
- **Paths.** Never touch `~/.micro-harness-manager` (the user's live Java install). All
  state goes through `MicrohmPaths` (default `~/.micro-harness-manager-swift`, override
  `MICROHM_HOME`). Default ports are 7402 (MCP) and 7403 (phone).
- **Wire compatibility.** The mux protocol (frames, JSON field names, ops, errors) and the
  phone page's HTTP API must match the Java implementation byte for byte where it
  matters, so the Java CLI (`../microhm-mux`) and the unmodified web page work against
  the Swift servers.
- **Tests.** XCTest, in `Tests/<Target>Tests`. Port the Java tests that pin behaviour
  (VT golden files are in `Tests/MicrohmVTTests/golden`, loaded via `Bundle.module`).
  Tests that spawn processes use temp dirs and set `MicrohmPaths.homeOverride` or
  `MICROHM_HOME`, never the real home.
- **Building in parallel.** Several people build at once: always pass your own scratch
  path, e.g. `swift build --scratch-path .build-vt` / `swift test --scratch-path .build-vt
  --filter MicrohmVTTests`. Only edit files in your own target dirs. If you must touch
  `Package.swift`, change only your own target's entry, with a minimal Edit.
- Delete your target's `_Placeholder.swift` / `PlaceholderTests.swift` once you have
  real files.
