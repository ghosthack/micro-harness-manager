import Darwin
import Foundation
import MicrohmShared

/// The command line: one subcommand per server operation plus `serve` and `version`. Exit
/// code 0 on success, 1 on any error (usage errors included), errors on stderr, JSON with
/// `--json`. The dead-server rules are the client library's: `list` prints nothing, `has`
/// prints false, `kill`/`shutdown` succeed, everything else reports "no such session" —
/// and only `new` spawns. Dependency-free on purpose: this is the debugging surface, not
/// the product UI.
public final class Cli {

    static let USAGE = """
        usage: microhm-mux <command> [options]

        commands:
          serve [--daemon] [--keep-alive] [--history-lines N] [--client-buffer BYTES]
          list [--json]
          has NAME
          new NAME [--dir DIR] [--size CxR]
          kill NAME
          send-keys NAME TEXT... [--no-enter]
          input NAME [--text T] [--paste] [KEY...]
          label NAME [KEY=VALUE...]   (KEY= removes the label)
          wait NAME [--quiet MS] [--timeout MS] [--since BYTES]
          watch [NAME...] [--quiet MS]
          capture NAME [--format text|annotated|ansi] [--history N] [--json]
          path NAME
          attach NAME [--size CxR]
          shutdown
          version [--json]

        options:
          --home DIR   server home (default ~/.micro-harness-manager-swift/mux,
                       or $MICROHM_MUX_HOME, or $MICROHM_HOME/mux)
          --json       machine-readable output

        keys (input): a single character, Enter, Tab, BTab, Esc, Space, Backspace,
          Delete, Insert, Up, Down, Left, Right, Home, End, PageUp, PageDown,
          F1..F12, C-x (control), M-key (meta/ESC prefix)

        """

    private static let VALUE_OPTIONS: Set<String> = ["--home", "--dir", "--size", "--history-lines", "--history",
                                                     "--client-buffer", "--text", "--format", "--quiet", "--timeout",
                                                     "--since"]
    private static let FLAG_OPTIONS: Set<String> = ["--json", "--daemon", "--keep-alive", "--no-enter", "--help",
                                                    "--paste"]

    private let stdin: CliInput
    private let out: CliOutput
    private let err: CliOutput
    /// The executable a spawned daemon runs (nil = resolve it; see `ServerLauncher`).
    private let launcher: URL?
    private let printLock = NSLock()

    public init(stdin: CliInput = FileDescriptorInput.standardInput,
                out: CliOutput = FileDescriptorOutput.standardOutput,
                err: CliOutput = FileDescriptorOutput.standardError,
                launcher: URL? = nil) {
        self.stdin = stdin
        self.out = out
        self.err = err
        self.launcher = launcher
    }

    /// Runs one command line and returns the process exit code.
    public func run(_ argv: [String]) -> Int32 {
        if argv.isEmpty || argv.contains("--help") || argv.contains("-h") {
            err.print(Cli.USAGE)
            return argv.isEmpty ? 1 : 0
        }
        let command = argv[0]
        do {
            let args = try Args.parse(Array(argv.dropFirst()), Cli.VALUE_OPTIONS, Cli.FLAG_OPTIONS)
            let home = args.value("--home").map { URL(fileURLWithPath: $0).standardizedFileURL } ?? ServerHome.resolve()
            return try dispatch(command, args, home)
        } catch let error as Args.UsageException {
            err.println("error: \(error.message)")
            err.print(Cli.USAGE)
            return 1
        } catch {
            err.println("error: \(error)")
            return 1
        }
    }

    private func dispatch(_ command: String, _ args: Args, _ home: URL) throws -> Int32 {
        let client = SessionServerClient(home: home, spawn: true, launcher: launcher)
        let json = args.flag("--json")
        switch command {
        case "serve":
            return try serve(args, home)
        case "version":
            return try version(client, json)
        case "list":
            return try list(client, json)
        case "has":
            out.println(String(try client.has(try args.positional(0, "NAME"))))
            return 0
        case "new":
            return try newSession(client, args)
        case "kill":
            try client.kill(try args.positional(0, "NAME"))
            return 0
        case "send-keys":
            let name = try args.positional(0, "NAME")
            let words = Array(args.positionals.dropFirst())
            if words.isEmpty {
                throw Args.UsageException("TEXT is required")
            }
            try client.sendKeys(name, text: words.joined(separator: " "), enter: !args.flag("--no-enter"))
            return 0
        case "input":
            return try input(client, args)
        case "label":
            return try label(client, args)
        case "wait":
            return try awaitQuiet(client, args)
        case "watch":
            return try watch(client, args)
        case "capture":
            return try capture(client, try args.positional(0, "NAME"), try Cli.captureFormat(args),
                               try Cli.historyLines(args), json)
        case "path":
            out.println(try client.currentPath(try args.positional(0, "NAME")).path)
            return 0
        case "attach":
            return try attach(client, args)
        case "shutdown":
            try client.shutdown()
            return 0
        default:
            throw Args.UsageException("unknown command '\(command)'")
        }
    }

    private func serve(_ args: Args, _ home: URL) throws -> Int32 {
        let options = try ServeOptions(home: home, daemon: args.flag("--daemon"), keepAlive: args.flag("--keep-alive"),
                                       historyLines: try args.intValue("--history-lines", ServeOptions.DEFAULT_HISTORY_LINES),
                                       clientBufferBytes: try args.intValue("--client-buffer",
                                                                            ServeOptions.DEFAULT_CLIENT_BUFFER_BYTES),
                                       behindTimeout: ServeOptions.DEFAULT_BEHIND_TIMEOUT)
        // A client that goes away mid-write must cost an EPIPE, not the daemon.
        signal(SIGPIPE, SIG_IGN)
        if options.daemon {
            // After the stdio redirect, errors (fd 2) go to server.log.
            try DaemonMode.enter(ServerHome.log(home))
        }
        let manager = SessionManagerFactory.createSessionManager(options)
        let server = SessionServer(options: options, manager: manager)
        if try !server.start() {
            return 0 // another server owns the home: that one serves, we are redundant
        }
        // What Java's shutdown hook did: a TERM (or, outside daemon mode, an INT or HUP)
        // kills the sessions in order and removes the socket before the process ends.
        var sources: [DispatchSourceSignal] = []
        let signals = options.daemon ? [SIGTERM] : [SIGTERM, SIGINT, SIGHUP]
        for sig in signals {
            signal(sig, SIG_IGN)
            let source = DispatchSource.makeSignalSource(signal: sig, queue: .global())
            source.setEventHandler { server.shutdown() }
            source.resume()
            sources.append(source)
        }
        server.awaitExit()
        sources.forEach { $0.cancel() }
        return 0
    }

    private func version(_ client: SessionServerClient, _ json: Bool) throws -> Int32 {
        let version = ServerVersion.current()
        let running = try client.ping()
        if json {
            var node = Json.object().with(MuxProtocol.F_VERSION, version).with(MuxProtocol.F_PROTOCOL, MuxProtocol.VERSION)
            if let info = running {
                node["server"] = .object(Json.object()
                    .with(MuxProtocol.F_VERSION, info.version)
                    .with(MuxProtocol.F_PROTOCOL, info.protocol)
                    .with(MuxProtocol.F_PID, info.pid))
            }
            printJson(.object(node))
        } else {
            out.println("microhm-mux \(version) (protocol \(MuxProtocol.VERSION))")
            if let info = running {
                out.println("server running: \(info.version) (protocol \(info.protocol), pid \(info.pid))")
            }
        }
        return 0
    }

    private func list(_ client: SessionServerClient, _ json: Bool) throws -> Int32 {
        let sessions = try client.list()
        if json {
            printJson(.array(sessions.map { .object(JsonEncoding.info($0)) }))
        } else {
            for info in sessions {
                out.println("\(info.name): \(info.columns)x\(info.rows) pid \(info.pid), \(info.clients) client"
                            + (info.clients == 1 ? "" : "s") + (info.alive ? "" : ", exited")
                            + " [\(info.backend)] \(info.workdir.path)")
            }
        }
        return 0
    }

    private func newSession(_ client: SessionServerClient, _ args: Args) throws -> Int32 {
        let name = try args.positional(0, "NAME")
        let dir = args.value("--dir").map { URL(fileURLWithPath: $0) }
            ?? URL(fileURLWithPath: FileManager.default.currentDirectoryPath)
        let size = try args.value("--size").map(Args.size) ?? (80, 24)
        try client.newSession(name, workdir: dir, columns: size.0, rows: size.1, command: nil)
        return 0
    }

    private func input(_ client: SessionServerClient, _ args: Args) throws -> Int32 {
        let name = try args.positional(0, "NAME")
        let keys = Array(args.positionals.dropFirst())
        let text = args.value("--text")
        if text == nil && keys.isEmpty {
            throw Args.UsageException("--text or a KEY is required")
        }
        try client.input(name, text: text, paste: args.flag("--paste"), keys: keys)
        return 0
    }

    private func label(_ client: SessionServerClient, _ args: Args) throws -> Int32 {
        let name = try args.positional(0, "NAME")
        let changes = try Cli.parseLabels(Array(args.positionals.dropFirst()))
        let labels = try client.label(name, changes: changes)
        if args.flag("--json") {
            printJson(.object(JsonEncoding.labels(labels)))
        } else {
            for (key, value) in sortedLabels(labels) {
                out.println("\(key)=\(value)")
            }
        }
        return 0
    }

    /// `KEY=VALUE` words as label changes; `KEY=` (empty value) removes.
    static func parseLabels(_ words: [String]) throws -> [String: String?] {
        var changes: [String: String?] = [:]
        for word in words {
            guard let eq = word.firstIndex(of: "="), eq != word.startIndex else {
                throw Args.UsageException("labels are KEY=VALUE (KEY= removes), not '\(word)'")
            }
            let value = String(word[word.index(after: eq)...])
            changes[String(word[..<eq])] = .some(value.isEmpty ? nil : value)
        }
        return changes
    }

    private func awaitQuiet(_ client: SessionServerClient, _ args: Args) throws -> Int32 {
        let name = try args.positional(0, "NAME")
        let result = try client.awaitQuiet(name, sinceBytes: try args.longValue("--since", -1),
                                           quietMs: try args.longValue("--quiet", MuxProtocol.WAIT_DEFAULT_QUIET_MS),
                                           timeoutMs: try args.longValue("--timeout", MuxProtocol.WAIT_DEFAULT_TIMEOUT_MS))
        printJson(.object(Json.object()
            .with(MuxProtocol.F_QUIET, result.quiet)
            .with(MuxProtocol.F_OUTPUT_BYTES, result.outputBytes)
            .with(MuxProtocol.F_ALIVE, result.alive)))
        return 0
    }

    /// One JSON line per event until the server ends the stream (or the process is
    /// interrupted). A stream the server dropped with an error (the watcher fell behind)
    /// prints that error and exits 1, so a script can tell it from a normal end.
    private func watch(_ client: SessionServerClient, _ args: Args) throws -> Int32 {
        let quietMs = try args.longValue("--quiet", MuxProtocol.WATCH_DEFAULT_QUIET_MS)
        let watch = try client.watch(names: args.positionals, quietMs: quietMs) { [self] event in printEvent(event) }
        defer { watch.close() }
        while watch.isOpen {
            Thread.sleep(forTimeInterval: 0.1)
        }
        if let error = watch.error {
            err.println("error: \(error)")
            return 1
        }
        return 0
    }

    private func printEvent(_ event: SessionEvent) {
        printLock.lock(); defer { printLock.unlock() }
        var node = Json.object()
            .with(MuxProtocol.F_EVENT, event.type)
            .with(MuxProtocol.F_NAME, event.name)
            .with(MuxProtocol.F_OUTPUT_BYTES, event.outputBytes)
        if let title = event.title {
            node[MuxProtocol.F_TITLE] = .string(title)
        }
        if let exitCode = event.exitCode {
            node[MuxProtocol.F_EXIT_CODE] = .int(Int64(exitCode))
        }
        printJson(.object(node))
    }

    static func captureFormat(_ args: Args) throws -> CaptureFormat {
        guard let name = args.value("--format") else { return .TEXT }
        guard let format = CaptureFormat.fromWireName(name) else {
            throw Args.UsageException("--format must be text, annotated or ansi, not '\(name)'")
        }
        return format
    }

    /// `--history N`: scrollback lines to print above the screen (default 0).
    static func historyLines(_ args: Args) throws -> Int {
        let lines = try args.intValue("--history", 0)
        if lines < 0 {
            throw Args.UsageException("--history must be zero or greater, not \(lines)")
        }
        return lines
    }

    /// JSON with every non-ASCII character escaped (`\uXXXX`): lossless whatever the
    /// console's encoding.
    private func printJson(_ node: JSON) {
        out.println(Cli.asciiJson(node))
    }

    static func asciiJson(_ node: JSON) -> String {
        node.serialized(escapeNonASCII: true)
    }

    private func capture(_ client: SessionServerClient, _ name: String, _ format: CaptureFormat, _ historyLines: Int,
                         _ json: Bool) throws -> Int32 {
        // The client folds the server's "no such session" into nil (the app maps it to a
        // dead pane); only blame a missing server when none answers.
        guard let captured = try client.captureWithFormat(name, format: format, historyLines: historyLines) else {
            throw try client.isServerRunning() ? SessionServerException("no such session: \(name)")
                                               : SessionServerException.noServer(name)
        }
        let capture = captured.capture
        if json {
            // The reply's shape without its `ok`.
            printJson(.object(JsonEncoding.capture(capture, captured.format).removing(MuxProtocol.F_OK)))
        } else {
            if let history = capture.history {
                out.print(history.text)
            }
            out.print(capture.text)
        }
        return 0
    }

    private func attach(_ client: SessionServerClient, _ args: Args) throws -> Int32 {
        let name = try args.positional(0, "NAME")
        // Same existence check as capture(): a missing name or dead server reports "no such
        // session" like every other command.
        if try !client.has(name) {
            throw try client.isServerRunning() ? SessionServerException("no such session: \(name)")
                                               : SessionServerException.noServer(name)
        }
        let size = try args.value("--size").map(Args.size)
        return try AttachCommand(client: client, stdin: stdin, stdout: out, stderr: err).run(name, size)
    }
}

extension JSONObject {
    func removing(_ key: String) -> JSONObject {
        var copy = self
        copy[key] = nil
        return copy
    }
}
