/**
 * The session daemon's view of a terminal: a `TerminalEmulator` with no display, fed
 * *synchronously* by the session's pump thread through `apply(_:)`. It is the server's source
 * of truth for `screenText()` (capture), `serialize(_:)` (redraw on attach), the pane title and
 * the input modes (`modes()`).
 *
 * Threading: `apply`, `resize` and `serialize` are called by the session under its lock; the
 * getters may be called from any thread. Everything takes the emulator's own
 * `TerminalEmulator.lock()`.
 *
 * Replies (DA1, DA2, DSR 5/6) go to the `Replies` closure — the session's PTY writer queue — in
 * the emulator's `.basic` scope, which answers exactly the queries `QueryFilter` strips from
 * the client stream. The colour-scheme report `CSI ?997;…n` is never produced (only a client
 * knows its theme), and XTWINOPS resize requests from the program (`CSI 8;h;w t`) are ignored.
 * A `ModeTracker` sees every token too, for the OSC 7 / OSC 9;9 working directory.
 */
public final class HeadlessTerminal: @unchecked Sendable {

    /** Where the emulator's own replies (DA, DSR, CPR) go: the session's PTY writer queue. */
    public typealias Replies = ([UInt8]) -> Void

    /** The input and display modes a client or the session needs (see `modes()`). */
    public struct Modes: Equatable, Sendable, CustomStringConvertible {
        public let cursorVisible: Bool
        /** DECSCUSR 0..6, 0 = default. */
        public let cursorShape: Int
        public let bracketedPaste: Bool
        public let applicationCursorKeys: Bool
        public let applicationKeypad: Bool
        /** 1000/1002/1003, 0 = none. */
        public let mouseTrackingMode: Int
        public let mouseSgr: Bool
        public let focusReporting: Bool
        public let alternateScreen: Bool
        public let autoWrap: Bool
        public let originMode: Bool
        /** 1-based. */
        public let scrollTop: Int
        /** 1-based. */
        public let scrollBottom: Int
        public let title: String

        public init(cursorVisible: Bool, cursorShape: Int, bracketedPaste: Bool, applicationCursorKeys: Bool,
                    applicationKeypad: Bool, mouseTrackingMode: Int, mouseSgr: Bool, focusReporting: Bool,
                    alternateScreen: Bool, autoWrap: Bool, originMode: Bool, scrollTop: Int, scrollBottom: Int,
                    title: String) {
            self.cursorVisible = cursorVisible
            self.cursorShape = cursorShape
            self.bracketedPaste = bracketedPaste
            self.applicationCursorKeys = applicationCursorKeys
            self.applicationKeypad = applicationKeypad
            self.mouseTrackingMode = mouseTrackingMode
            self.mouseSgr = mouseSgr
            self.focusReporting = focusReporting
            self.alternateScreen = alternateScreen
            self.autoWrap = autoWrap
            self.originMode = originMode
            self.scrollTop = scrollTop
            self.scrollBottom = scrollBottom
            self.title = title
        }

        /** The Java record's `toString()`. */
        public var description: String {
            return "Modes[cursorVisible=\(cursorVisible), cursorShape=\(cursorShape), bracketedPaste=\(bracketedPaste), "
                + "applicationCursorKeys=\(applicationCursorKeys), applicationKeypad=\(applicationKeypad), "
                + "mouseTrackingMode=\(mouseTrackingMode), mouseSgr=\(mouseSgr), focusReporting=\(focusReporting), "
                + "alternateScreen=\(alternateScreen), autoWrap=\(autoWrap), originMode=\(originMode), "
                + "scrollTop=\(scrollTop), scrollBottom=\(scrollBottom), title=\(title)]"
        }
    }

    /** What `ESC 7` / `CSI ?1049 h` saved on the main screen — the cursor `CSI ?1049 l`
     * restores; nil when nothing was saved since the last RIS. `cursorX` and `cursorY` are
     * 0-based; `style` is a packed `Style`. */
    public struct StoredCursor: Equatable, Sendable {
        public let cursorX: Int
        public let cursorY: Int
        public let style: Int64
        public let autoWrap: Bool
        public let originMode: Bool

        public init(cursorX: Int, cursorY: Int, style: Int64, autoWrap: Bool, originMode: Bool) {
            self.cursorX = cursorX
            self.cursorY = cursorY
            self.style = style
            self.autoWrap = autoWrap
            self.originMode = originMode
        }
    }

    /** Scrollback lines above the main screen, oldest first, in `screenText()`'s shape (one row
     * per line, trailing whitespace trimmed, each ending with `\n`); `held` is how many lines
     * the history holds, `added` how many have ever scrolled into it (monotonic: the oldest
     * falling out of a full history or a clear does not lower it), and `alternateScreen`
     * whether a full-screen program is showing (the main screen's history then stays as it
     * was). */
    public struct History: Equatable, Sendable {
        public let text: String
        public let held: Int
        public let added: Int64
        public let alternateScreen: Bool

        public init(text: String, held: Int, added: Int64, alternateScreen: Bool) {
            self.text = text
            self.held = held
            self.added = added
            self.alternateScreen = alternateScreen
        }
    }

    /** Prefix of a row `annotatedText()` considers selected. */
    public static let selectionMarker = "\u{25b6} "
    /** Inserted by `annotatedText()` where the visible cursor is. */
    public static let cursorMarker = "\u{25ae}"
    /** Java-named aliases. */
    public static let SELECTION_MARKER = selectionMarker
    public static let CURSOR_MARKER = cursorMarker

    private let _emulator: TerminalEmulator
    private let modeTracker: ModeTracker
    private var closed = false

    public init(_ columns: Int, _ rows: Int, _ maxHistoryLines: Int, _ replies: @escaping Replies) {
        _emulator = TerminalEmulator(columns, rows, maxHistoryLines)
        _emulator.setReplies(replies, .basic)
        modeTracker = ModeTracker(rows)
    }

    public convenience init(columns: Int, rows: Int, maxHistoryLines: Int, replies: @escaping Replies) {
        self.init(columns, rows, maxHistoryLines, replies)
    }

    @inline(__always)
    private func locked<T>(_ body: () -> T) -> T {
        let lock = _emulator.lock()
        lock.lock()
        defer { lock.unlock() }
        return body()
    }

    /** Applies a batch of complete tokens to the emulator and the mode tracker, in order.
     * Returns when every token has been applied. Called under the session lock only. */
    public func apply(_ tokens: [VtToken]) {
        if closed || tokens.isEmpty {
            return
        }
        _emulator.apply(tokens)
        locked {
            for token in tokens {
                modeTracker.observe(token)
            }
        }
    }

    /** Resizes both screens (see `TerminalEmulator.resize`); the scroll region resets. */
    public func resize(_ columns: Int, _ rows: Int) {
        if closed {
            return
        }
        _emulator.resize(columns, rows)
        locked {
            modeTracker.resized(_emulator.rows())
        }
    }

    public func columns() -> Int {
        return locked { _emulator.columns() }
    }

    public func rows() -> Int {
        return locked { _emulator.rows() }
    }

    /** The visible screen: one string per row, trailing whitespace trimmed, wide-character
     * placeholder cells removed; lines joined with `\n`, and the result ends with `\n` (tmux
     * `capture-pane -p` shape). */
    public func screenText() -> String {
        return locked {
            var sb = ""
            for y in 0..<_emulator.rows() {
                sb += HeadlessTerminal.trimTrailing(_emulator.line(y).toString())
                sb += "\n"
            }
            return sb
        }
    }

    /** The newest `maxLines` history lines (fewer when it holds fewer). */
    public func history(_ maxLines: Int) -> History {
        return locked { historyLocked(max(0, maxLines)) }
    }

    /** The history lines added after the first `since` ever added, those still held: a reader
     * that keeps `History.added` gets each line once by passing it back. A `since` beyond
     * `added` (another session's count) is taken as 0. */
    public func historySince(_ since: Int64) -> History {
        return locked {
            let added = _emulator.historyLinesAdded()
            let start = since < 0 || since > added ? 0 : since
            return historyLocked(Int(min(added - start, Int64(Int32.max))))
        }
    }

    private func historyLocked(_ maxLines: Int) -> History {
        let held = _emulator.mainHistorySize()
        let n = min(maxLines, held)
        var sb = ""
        var i = -n
        while i < 0 {
            sb += HeadlessTerminal.trimTrailing(_emulator.mainLine(i).toString())
            sb += "\n"
            i += 1
        }
        return History(text: sb, held: held, added: _emulator.historyLinesAdded(),
                       alternateScreen: _emulator.alternateScreen())
    }

    /**
     * `screenText()` with two hints a reader of plain text would otherwise lose:
     *  - **Selection**: a row with a non-blank cell drawn in reverse video, or on a background
     *    other than the screen's dominant one (the most frequent background of the non-blank
     *    cells, default included), is prefixed `selectionMarker`. When more than a third of
     *    the non-blank rows qualify the colours are a theme, not a selection, and no row is
     *    marked.
     *  - **Cursor**: when the cursor is visible, `cursorMarker` is inserted (not substituted)
     *    at its column in its row, padding with spaces past the text.
     *
     * A blank cell is a space or an empty cell with the default background and no reverse
     * video.
     */
    public func annotatedText() -> String {
        return locked {
            let height = _emulator.rows()
            let width = _emulator.columns()
            var lines: [Line] = []
            lines.reserveCapacity(height)
            var counts: [Int: Int] = [:]
            var order: [Int] = [] // first-seen order, for Java HashMap's iteration order
            for y in 0..<height {
                let line = _emulator.line(y)
                lines.append(line)
                for x in 0..<width where !HeadlessTerminal.isBlank(line, x) {
                    let bg = Style.background(line.style(x))
                    if let c = counts[bg] {
                        counts[bg] = c + 1
                    } else {
                        counts[bg] = 1
                        order.append(bg)
                    }
                }
            }
            var dominant = Style.colorDefault
            var best = -1
            for key in HeadlessTerminal.javaHashMapOrder(order) {
                let value = counts[key]!
                if value > best {
                    best = value
                    dominant = key
                }
            }
            var highlighted = [Bool](repeating: false, count: height)
            var contentRows = 0
            var highlightedRows = 0
            for y in 0..<height {
                var content = false
                for x in 0..<width {
                    if HeadlessTerminal.isBlank(lines[y], x) {
                        continue
                    }
                    content = true
                    let style = lines[y].style(x)
                    if Style.inverse(style) || Style.background(style) != dominant {
                        highlighted[y] = true
                        break
                    }
                }
                if content {
                    contentRows += 1
                }
                if highlighted[y] {
                    highlightedRows += 1
                }
            }
            let selection = highlightedRows > 0 && highlightedRows * 3 <= contentRows
            let cursorRow = _emulator.cursorVisible() ? _emulator.cursorRow() : -1
            var sb = ""
            for y in 0..<height {
                var text = HeadlessTerminal.trimTrailing(lines[y].toString())
                if y == cursorRow {
                    // Java indexes the row's text in UTF-16 units.
                    let index = HeadlessTerminal.textIndex(lines[y], _emulator.cursorColumn())
                    var row = Array(text.utf16)
                    while row.count < index {
                        row.append(0x20)
                    }
                    row.insert(contentsOf: Array(HeadlessTerminal.cursorMarker.utf16), at: index)
                    text = String(decoding: row, as: UTF16.self)
                }
                if selection && highlighted[y] {
                    sb += HeadlessTerminal.selectionMarker
                }
                sb += text
                sb += "\n"
            }
            return sb
        }
    }

    /** The iteration order of a `java.util.HashMap<Integer, Integer>` holding `keys` (inserted
     * in this order): by bucket, then insertion order within a bucket. Only ties between
     * equally frequent backgrounds depend on it. */
    private static func javaHashMapOrder(_ keys: [Int]) -> [Int] {
        var capacity = 16
        while Double(keys.count) > Double(capacity) * 0.75 {
            capacity *= 2
        }
        func bucket(_ key: Int) -> Int {
            let h = Int32(truncatingIfNeeded: key)
            let spread = h ^ Int32(bitPattern: UInt32(bitPattern: h) >> 16)
            return Int(spread) & (capacity - 1)
        }
        return keys.enumerated().sorted { a, b in
            let ba = bucket(a.element)
            let bb = bucket(b.element)
            return ba != bb ? ba < bb : a.offset < b.offset
        }.map { $0.element }
    }

    /** The last OSC 0/1/2 title, or "" if never set. */
    public func title() -> String {
        return locked { _emulator.title() }
    }

    /** The last OSC 7 / OSC 9;9 working directory the shell reported, or nil. */
    public func reportedCwd() -> String? {
        return locked { modeTracker.reportedCwd() }
    }

    public func modes() -> Modes {
        return locked { modesLocked() }
    }

    public func storedCursor() -> StoredCursor? {
        return locked {
            guard let saved = _emulator.savedCursor(false) else {
                return nil
            }
            return StoredCursor(cursorX: saved.column, cursorY: saved.row, style: saved.style,
                                autoWrap: saved.autoWrap, originMode: saved.originMode)
        }
    }

    /** The redraw stream for a freshly attached client at the current size: see
     * `ScreenSerializer`. Includes up to `historyLines` history lines before the screen. */
    public func serialize(_ historyLines: Int) -> [UInt8] {
        return locked { ScreenSerializer.serialize(_emulator, historyLines) }
    }

    /** Test/diagnostic access: the screen rows as plain text, untrimmed. */
    public func screenLines() -> [String] {
        return locked {
            (0..<_emulator.rows()).map { _emulator.line($0).toString() }
        }
    }

    /** The underlying emulator, for reads beyond this class's (take its `lock()`). Do not feed
     * it directly: go through `apply`. */
    public func emulator() -> TerminalEmulator {
        return _emulator
    }

    /** Releases nothing OS-level (there is no thread); marks the instance closed so a late
     * `apply` is a no-op. Idempotent. */
    public func close() {
        closed = true
    }

    // --- internals -------------------------------------------------------------------

    private func modesLocked() -> Modes {
        let e = _emulator
        let mouse: Int
        switch e.mouseTracking() {
        case .normal, .buttonMotion, .anyMotion: mouse = e.mouseTracking().mode
        case .none, .x10: mouse = 0
        }
        return Modes(cursorVisible: e.cursorVisible(), cursorShape: e.cursorShape(), bracketedPaste: e.bracketedPaste(),
                     applicationCursorKeys: e.applicationCursorKeys(), applicationKeypad: e.applicationKeypad(),
                     mouseTrackingMode: mouse, mouseSgr: e.mouseEncoding() == .sgr,
                     focusReporting: e.focusReporting(), alternateScreen: e.alternateScreen(),
                     autoWrap: e.autoWrap(), originMode: e.originMode(), scrollTop: e.scrollTop() + 1,
                     scrollBottom: e.scrollBottom() + 1, title: e.title())
    }

    /** The index in the row's text (UTF-16 units, as Java) of column `column`: wide tails take
     * a column but no text, attached code points add text, and columns past the end count as
     * spaces. */
    private static func textIndex(_ line: Line, _ column: Int) -> Int {
        var index = 0
        let end = min(column, line.columns())
        for x in 0..<max(0, end) {
            if line.isWideTail(x) {
                continue
            }
            let cp = line.codePoint(x)
            index += cp == 0 ? 1 : (cp >= 0x10000 ? 2 : 1)
            if line.hasExtras(x) {
                index += line.extraText(x).utf16.count
            }
        }
        return index + max(0, column - line.columns())
    }

    private static func isBlank(_ line: Line, _ x: Int) -> Bool {
        let cp = line.codePoint(x)
        let style = line.style(x)
        return (cp == 0x20 || cp == 0) && !line.isWideTail(x)
            && Style.background(style) == Style.colorDefault && !Style.inverse(style)
    }

    static func trimTrailing(_ s: String) -> String {
        var scalars = s.unicodeScalars
        while let last = scalars.last, last == " " || last == "\t" || last == "\0" {
            scalars.removeLast()
        }
        return String(scalars)
    }
}
