import Darwin
import Foundation

/// The console's terminal as `attach` needs it. The real one works on `/dev/tty` with
/// termios and `TIOCGWINSZ` (what the Java side did by running `stty`), and learns of size
/// changes from SIGWINCH (which the JVM could not receive, so Java polled once a second);
/// tests fake it.
protocol TerminalControl: AnyObject {
    /// (columns, rows) of the controlling terminal, when it can be asked.
    func size() -> (Int, Int)?
    /// Puts the terminal in raw mode without echo; returns how to restore it, or nil when
    /// there is no terminal.
    func enterRaw() -> (() -> Void)?
    /// Calls `handler` whenever the terminal may have changed size; returns the cancel.
    func onResize(_ handler: @escaping () -> Void) -> () -> Void
}

/// `/dev/tty` through termios.
final class ControllingTerminalControl: TerminalControl {

    private func withTty<T>(_ body: (Int32) -> T?) -> T? {
        let fd = open("/dev/tty", O_RDWR | O_NOCTTY | O_CLOEXEC)
        if fd < 0 { return nil }
        defer { close(fd) }
        return body(fd)
    }

    func size() -> (Int, Int)? {
        withTty { fd in
            var ws = winsize()
            guard ioctl(fd, TIOCGWINSZ, &ws) == 0, ws.ws_col > 0, ws.ws_row > 0 else { return nil }
            return (Int(ws.ws_col), Int(ws.ws_row))
        }
    }

    func enterRaw() -> (() -> Void)? {
        withTty { fd -> (() -> Void)? in
            var saved = termios()
            guard tcgetattr(fd, &saved) == 0 else { return nil }
            var raw = saved
            cfmakeraw(&raw) // `stty raw -echo`
            guard tcsetattr(fd, TCSAFLUSH, &raw) == 0 else { return nil }
            let original = saved
            return {
                let fd = open("/dev/tty", O_RDWR | O_NOCTTY | O_CLOEXEC)
                if fd < 0 { return }
                var restore = original
                _ = tcsetattr(fd, TCSAFLUSH, &restore)
                close(fd)
            }
        }
    }

    func onResize(_ handler: @escaping () -> Void) -> () -> Void {
        signal(SIGWINCH, SIG_IGN) // delivered to the dispatch source instead
        let source = DispatchSource.makeSignalSource(signal: SIGWINCH, queue: .global())
        source.setEventHandler(handler: handler)
        source.resume()
        return { source.cancel() }
    }
}

/// `attach NAME` on a Unix console: the controlling terminal goes raw (restored on every
/// exit path, a TERM/HUP/INT to this process included), stdin is pumped to the session and
/// session output to stdout, Ctrl-] (`0x1d`) detaches, and the terminal size is forwarded
/// whenever it changes. An explicit `--size` pins the session size for this attach and
/// skips following the terminal. Size announcements from other clients are printed as a
/// notice rather than replayed.
final class AttachCommand {

    static let DETACH_KEY: UInt8 = 0x1d

    private let client: SessionServerClient
    private let stdin: CliInput
    private let stdout: CliOutput
    private let stderr: CliOutput
    private let terminal: TerminalControl

    init(client: SessionServerClient, stdin: CliInput, stdout: CliOutput, stderr: CliOutput,
         terminal: TerminalControl = ControllingTerminalControl()) {
        self.client = client
        self.stdin = stdin
        self.stdout = stdout
        self.stderr = stderr
        self.terminal = terminal
    }

    /// Exit code. `size` nil means "ask the terminal" (and follow it).
    func run(_ name: String, _ size: (Int, Int)?) throws -> Int32 {
        let initial = size ?? terminal.size() ?? (80, 24)
        let session = try client.attach(name, columns: initial.0, rows: initial.1)
        let restore = terminal.enterRaw()
        let restoreOnce = Once(restore ?? {})
        // What the JVM's shutdown hook did: a signal that ends this process restores the tty.
        var signalSources: [DispatchSourceSignal] = []
        for sig in [SIGTERM, SIGHUP, SIGINT] {
            signal(sig, SIG_IGN)
            let source = DispatchSource.makeSignalSource(signal: sig, queue: .global())
            source.setEventHandler {
                session.close()
                restoreOnce.run()
                exit(128 + sig)
            }
            source.resume()
            signalSources.append(source)
        }
        let detached = Flag()
        defer {
            session.close()
            signalSources.forEach { $0.cancel() }
            restoreOnce.run()
        }
        let input = Thread { [self] in pumpInput(session, detached) }
        input.name = "microhm-mux-stdin"
        input.start()
        // An explicit --size pins the size: not following the terminal, or its first change
        // would resize the session (and reflow every other client) to whatever it really is.
        var cancelResize: (() -> Void)?
        if size == nil {
            let last = SizeBox(initial)
            cancelResize = terminal.onResize { [terminal] in
                guard let now = terminal.size(), last.update(now) else { return }
                try? session.resize(columns: now.0, rows: now.1)
            }
        }
        pumpOutput(session)
        cancelResize?()
        session.close()
        restoreOnce.run()
        if let code = session.exitCode {
            stderr.println("[session \(name) exited with \(code)]")
        } else {
            stderr.println(detached.value ? "[detached]" : "[connection closed]")
        }
        return 0
    }

    private func pumpOutput(_ session: AttachedSession) {
        let filter = SizeAnnouncementFilter { [stdout] columns, rows in
            stdout.write(Array("\r\n[session resized to \(columns)x\(rows) by another client]\r\n".utf8))
        }
        var buffer = [UInt8](repeating: 0, count: 8192)
        while true {
            let n: Int
            do {
                n = try buffer.withUnsafeMutableBytes { try session.read(into: $0) }
            } catch {
                stderr.println("[\(error)]")
                break
            }
            if n < 0 { break }
            stdout.write(filter.filter(buffer[0..<n]))
        }
        stdout.write(filter.flush())
    }

    private func pumpInput(_ session: AttachedSession, _ detached: Flag) {
        var buffer = [UInt8](repeating: 0, count: 1024)
        while true {
            let n = buffer.withUnsafeMutableBytes { stdin.read(into: $0) }
            if n < 0 { return }
            let end = buffer[0..<n].firstIndex(of: AttachCommand.DETACH_KEY) ?? n
            if end > 0 {
                do {
                    try session.write(Array(buffer[0..<end]))
                } catch {
                    return // the attachment ended: the output pump notices and returns
                }
            }
            if end < n {
                detached.set()
                session.close()
                return
            }
        }
    }
}

private final class Once: @unchecked Sendable {
    private let lock = NSLock()
    private var action: (() -> Void)?
    init(_ action: @escaping () -> Void) { self.action = action }
    func run() {
        lock.lock()
        let pending = action
        action = nil
        lock.unlock()
        pending?()
    }
}

private final class Flag: @unchecked Sendable {
    private let lock = NSLock()
    private var flag = false
    func set() { lock.lock(); flag = true; lock.unlock() }
    var value: Bool { lock.lock(); defer { lock.unlock() }; return flag }
}

private final class SizeBox: @unchecked Sendable {
    private let lock = NSLock()
    private var size: (Int, Int)
    init(_ size: (Int, Int)) { self.size = size }
    /// True when `now` differs from the last size (which it then becomes).
    func update(_ now: (Int, Int)) -> Bool {
        lock.lock(); defer { lock.unlock() }
        if now == size { return false }
        size = now
        return true
    }
}
