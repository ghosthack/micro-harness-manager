import XCTest
@testable import MicrohmPTY

/// The POSIX PTY (port of the Java `PtyProcessTest`).
final class PtyProcessTests: XCTestCase {

    private var dir: URL!

    override func setUpWithError() throws {
        dir = FileManager.default.temporaryDirectory.appendingPathComponent("pty-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: dir)
    }

    private func env() -> [String: String] {
        ["PATH": "/usr/bin:/bin:/usr/sbin:/sbin", "TERM": "xterm-256color", "LANG": "en_US.UTF-8"]
    }

    private func start(_ command: [String], _ environment: [String: String]? = nil,
                       columns: Int = 80, rows: Int = 24) throws -> PtyProcess {
        try PtyProcess.start(command, environment: environment ?? env(), directory: dir, columns: columns, rows: rows)
    }

    /// Everything the terminal prints until output ends.
    private func drain(_ process: PtyProcess) throws -> String {
        var out = [UInt8]()
        while let chunk = try process.read() { out += chunk }
        return String(decoding: out, as: UTF8.self)
    }

    /// Reads until `needle` appears (or output ends).
    private func readUntil(_ process: PtyProcess, _ needle: String) throws -> String {
        var seen = [UInt8]()
        while !String(decoding: seen, as: UTF8.self).contains(needle), let chunk = try process.read() {
            seen += chunk
        }
        return String(decoding: seen, as: UTF8.self)
    }

    private var realDir: String {
        URL(fileURLWithPath: dir.path).resolvingSymlinksInPath().path
    }

    func testChildHasThePtyAsItsControllingTerminalAtTheRequestedSize() throws {
        let process = try start(["/bin/sh", "-c", "tty; stty size; (exec 3</dev/tty && echo CTTY-OK) 2>&1; pwd -P"],
                                columns: 100, rows: 30)
        let output = try drain(process)
        XCTAssertEqual(0, process.waitFor())
        XCTAssertTrue(output.contains("/dev/"), output)
        XCTAssertTrue(output.contains("30 100"), output)
        XCTAssertTrue(output.contains("CTTY-OK"), output)
        XCTAssertTrue(output.contains(realDir), output)
    }

    /// zsh, unlike bash, does not take the terminal for itself: the PTY layer must have made
    /// it the controlling terminal already, or job control, /dev/tty and the foreground
    /// process group (tpgid, which the daemon's foreground probe reads) are all missing.
    func testAShellThatDoesNotTakeTheTerminalItselfStillHasIt() throws {
        try XCTSkipUnless(FileManager.default.isExecutableFile(atPath: "/bin/zsh"), "no /bin/zsh")
        let process = try start(["/bin/zsh", "-f", "-c", "ps -o tpgid= -p $$; (exec 3</dev/tty && echo CTTY-OK) 2>&1; true"])
        let output = try drain(process)
        XCTAssertEqual(0, process.waitFor())
        XCTAssertTrue(output.contains("CTTY-OK"), output)
        let first = output.trimmingCharacters(in: .whitespacesAndNewlines).split(whereSeparator: { $0.isWhitespace }).first
        XCTAssertEqual(String(process.pid), first.map(String.init), "the shell's own group is the foreground: \(output)")
    }

    func testArgvZeroIsPreserved() throws {
        let process = try start(["/bin/sh", "-c", "echo \"[$0]\"", "custom-name"])
        XCTAssertTrue(try drain(process).contains("[custom-name]"))
        XCTAssertEqual(0, process.waitFor())
    }

    func testChildIsASessionLeader() throws {
        let process = try start(["/bin/sh", "-c", "ps -o sess= -o pgid= -p $$"])
        let output = try drain(process).trimmingCharacters(in: .whitespacesAndNewlines)
        process.waitFor()
        let columns = output.split(whereSeparator: { $0.isWhitespace })
        XCTAssertEqual(String(process.pid), columns.last.map(String.init), output)
    }

    func testInputIsEchoedAndReachesTheChild() throws {
        let process = try start(["/bin/sh", "-c", "read line; echo \"got:$line\""])
        try process.write(Array("hello\r".utf8))
        let output = try drain(process)
        XCTAssertEqual(0, process.waitFor())
        XCTAssertTrue(output.contains("got:hello"), output)
    }

    func testResizeIsSeenByTheChild() throws {
        let process = try start(["/bin/sh", "-c", "echo ready; read x; stty size"])
        _ = try readUntil(process, "ready")
        try process.setWinSize(columns: 132, rows: 50)
        try process.write(Array("\r".utf8))
        let output = try drain(process)
        XCTAssertTrue(output.contains("50 132"), output)
    }

    func testExitStatusAndSignalDeathAreReported() throws {
        let exits = try start(["/bin/sh", "-c", "exit 7"])
        _ = try drain(exits)
        XCTAssertEqual(7, exits.waitFor())
        XCTAssertFalse(exits.isAlive)

        let sleeper = try start(["/bin/sleep", "60"])
        XCTAssertTrue(sleeper.isAlive)
        XCTAssertFalse(sleeper.waitFor(timeout: 0.1))
        sleeper.destroyForcibly()
        XCTAssertTrue(sleeper.waitFor(timeout: 5))
        XCTAssertEqual(128 + 9, sleeper.exitValue())
    }

    /// The hangup is sent once the shell is at its prompt, not after a fixed wait, and the
    /// output is read throughout, as the daemon does.
    func testHangupEndsAnInteractiveShell() throws {
        let shell = try start(["/bin/sh", "-i"])
        let prompt = try readUntil(shell, "$ ")
        XCTAssertTrue(prompt.contains("$ "), "the shell reached its prompt: \(prompt)")
        let reader = Thread { _ = try? self.drain(shell) }
        reader.start()
        shell.hangup()
        XCTAssertTrue(shell.waitFor(timeout: 5), "the shell exits on a hangup at its prompt")
    }

    func testProgramIsResolvedOnTheChildPath() throws {
        let process = try start(["echo", "resolved"])
        XCTAssertTrue(try drain(process).contains("resolved"))
        XCTAssertEqual(0, process.waitFor())
    }

    func testTheChildGetsExactlyTheGivenEnvironment() throws {
        var environment = env()
        environment["MICROHM_PTY_TEST"] = "yes"
        environment["WITH_SPACES"] = "a b  c"
        let process = try start(["/usr/bin/env"], environment)
        let output = try drain(process)
        XCTAssertEqual(0, process.waitFor())
        var seen: [String: String] = [:]
        for line in output.components(separatedBy: "\r\n") {
            if let eq = line.firstIndex(of: "="), eq != line.startIndex {
                seen[String(line[..<eq])] = String(line[line.index(after: eq)...])
            }
        }
        XCTAssertEqual(environment, seen, "exactly the given environment, nothing from the parent")
    }

    /// No signal is blocked or ignored in the child: each one it sends itself kills it with
    /// the default action.
    func testTheChildStartsWithDefaultSignals() throws {
        signal(SIGPIPE, SIG_IGN) // what the daemon does; the child must not inherit it
        for sig: Int32 in [1, 2, 3, 13, 15, 25] { // HUP INT QUIT PIPE TERM XFSZ
            let process = try start(["/bin/sh", "-c", "kill -\(sig) $$; echo SURVIVED"])
            let output = try drain(process)
            XCTAssertEqual(128 + sig, process.waitFor(), "signal \(sig): \(output)")
            XCTAssertFalse(output.contains("SURVIVED"), "signal \(sig) was ignored")
        }
        let mask = try start(["/bin/sh", "-c", "ps -o sigmask= -p $$"])
        let blocked = try drain(mask).trimmingCharacters(in: .whitespacesAndNewlines)
        XCTAssertEqual(0, mask.waitFor())
        XCTAssertEqual(0, UInt64(blocked, radix: 16), "blocked signals: \(blocked)")
    }

    func testNoParentDescriptorsLeakIntoTheChild() throws {
        let marker = dir.appendingPathComponent("open-in-parent")
        try Data("x".utf8).write(to: marker)
        let held = open(marker.path, O_RDONLY) // deliberately not close-on-exec
        defer { close(held) }
        // a shell glob, no child process: only the shell's own descriptors are listed
        let process = try start(["/bin/sh", "-c", "for f in /dev/fd/*; do echo \"${f#/dev/fd/}\"; done"])
        let fds = try drain(process).trimmingCharacters(in: .whitespacesAndNewlines)
        // 0, 1, 2, plus the descriptor the glob itself opens to read the directory
        for fd in fds.split(whereSeparator: { $0.isWhitespace }) {
            XCTAssertLessThanOrEqual(Int(fd) ?? 99, 3, "unexpected descriptor in the child: \(fds)")
        }
    }

    func testWritesAfterTheTerminalClosesFailInsteadOfHittingAReusedDescriptor() throws {
        let process = try start(["/bin/sh", "-c", "exit 0"])
        _ = try drain(process)
        process.closeTerminal()
        XCTAssertThrowsError(try process.write(Array("x".utf8)))
        XCTAssertThrowsError(try process.setWinSize(columns: 10, rows: 10))
        XCTAssertNil(try process.read())
    }

    func testAMissingProgramOrDirectoryFailsToStart() {
        XCTAssertThrowsError(try start(["/nonexistent/program"]))
        XCTAssertThrowsError(try PtyProcess.start(["/bin/sh"], environment: env(),
                                                  directory: dir.appendingPathComponent("missing"), columns: 80, rows: 24))
        XCTAssertThrowsError(try start(["no-such-program-anywhere"]))
    }

    func testDecodesWaitStatus() {
        XCTAssertEqual(0, PtyProcess.decode(0))
        XCTAssertEqual(3, PtyProcess.decode(3 << 8))
        XCTAssertEqual(128 + 15, PtyProcess.decode(15))
    }

    func testLargeOutputArrivesIntact() throws {
        let process = try start(["/bin/sh", "-c",
                                 "stty -opost; i=0; while [ $i -lt 20000 ]; do echo line$i; i=$((i+1)); done"])
        let output = try drain(process)
        XCTAssertEqual(0, process.waitFor())
        XCTAssertTrue(output.contains("line0\n") && output.contains("line19999\n"), "\(output.count) chars")
    }

    func testForegroundProcessGroupIsTheShellAtFirst() throws {
        let process = try start(["/bin/sh", "-c", "echo ready; read x"])
        _ = try readUntil(process, "ready")
        XCTAssertEqual(process.pid, process.foregroundProcessGroup())
        try process.write(Array("\r".utf8))
        _ = try drain(process)
        process.waitFor()
        process.closeTerminal()
        XCTAssertEqual(-1, process.foregroundProcessGroup())
    }
}
