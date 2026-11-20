import Foundation

/**
 * An xterm-compatible terminal emulator: the screen model (main screen with scrollback,
 * alternate screen, cursor, modes) plus the interpreter that applies `VtToken`s to it. No
 * dependencies. It has two consumers: `HeadlessTerminal` on the session daemon, and a renderer
 * on the client, which feeds raw bytes with `feed` and paints from the read API below.
 *
 * ## Threading
 * The model is guarded by `lock()`. `apply`, `feed` and `resize` take it themselves. Every
 * other getter reads unsynchronised state: hold the lock around a group of reads that must be
 * consistent (a frame), e.g.
 * ```
 * emulator.lock().lock()
 * defer { emulator.lock().unlock() }
 * for y in 0..<emulator.rows() { paint(emulator.line(y)) }
 * paintCursor(emulator.cursorRow(), emulator.cursorColumn())
 * ```
 * `changeCount()` is safe without the lock. `TerminalListener` callbacks and replies are
 * delivered after the lock is released, on the feeding thread.
 *
 * ## Coordinates
 * Rows and columns are 0-based. `line(_:)` takes `-historySize()..-1` for the scrollback (−1
 * is the newest history line) and `0..rows()-1` for the screen. After a character is written
 * in the last column the cursor stays on that column with `cursorPendingWrap()` set; the next
 * printable character wraps first (DEC/xterm deferred wrap).
 *
 * ## Replies
 * Queries are answered through the `ReplySink` given to `setReplies`. In the `.basic` scope
 * only DA1 (`CSI c` / `CSI 0 c`, no private marker), DA2 (`CSI > c` / `CSI > 0 c`) and DSR 5/6
 * are answered — the set `QueryFilter` strips from the stream clients see, so the two stay in
 * lock-step — plus XTGETTCAP (`DCS + q`), answered "invalid" as jediterm did. `.full` adds
 * DECXCPR (`CSI ? 6 n`), DECRQM, XTVERSION and the kitty keyboard query (`CSI ? u`); use it
 * only for a standalone terminal whose key encoder implements what it then advertises.
 * `.client` answers none of those: it is for a renderer attached through the daemon, which
 * answers the basic set itself and forwards the rest unanswered on purpose.
 *
 * The colour-scheme query `CSI ? 996 n` is answered (`CSI ? 997 ; 1 n` dark, `; 2 n` light)
 * in every scope, but only once `setColorScheme` has been given a scheme — only a client knows
 * its theme, so the daemon never sets one. While the program has DECSET 2031 on, a scheme
 * change is also reported unsolicited. Nothing answers OSC colour queries.
 */
public final class TerminalEmulator: @unchecked Sendable {

    /** Where replies to queries go (e.g. the PTY writer). */
    public typealias ReplySink = ([UInt8]) -> Void

    /** Which queries are answered; see the class documentation. */
    public enum ReplyScope: Sendable {
        case basic, full
        /** Nothing but the colour-scheme report (see `setColorScheme`). */
        case client
    }

    /** The light/dark preference reported for `CSI ? 996 n`. */
    public enum ColorScheme: Sendable {
        case dark, light

        /** The `CSI ? 997 ; n n` report value. */
        public var report: Int {
            return self == .dark ? 1 : 2
        }
    }

    /** Mouse reporting requested by the program (DECSET 9/1000/1002/1003). */
    public enum MouseTracking: Sendable, CustomStringConvertible {
        case none, x10, normal, buttonMotion, anyMotion

        /** The DECSET number, 0 for none. */
        public var mode: Int {
            switch self {
            case .none: return 0
            case .x10: return 9
            case .normal: return 1000
            case .buttonMotion: return 1002
            case .anyMotion: return 1003
            }
        }

        /** The Java constant name. */
        public var description: String {
            switch self {
            case .none: return "NONE"
            case .x10: return "X10"
            case .normal: return "NORMAL"
            case .buttonMotion: return "BUTTON_MOTION"
            case .anyMotion: return "ANY_MOTION"
            }
        }
    }

    /** How mouse reports are encoded (DECSET 1005/1006/1015; default is X10 bytes). */
    public enum MouseEncoding: Sendable, CustomStringConvertible {
        case `default`, utf8, sgr, urxvt

        /** The Java constant name. */
        public var description: String {
            switch self {
            case .default: return "DEFAULT"
            case .utf8: return "UTF8"
            case .sgr: return "SGR"
            case .urxvt: return "URXVT"
            }
        }
    }

    /**
     * A saved cursor (DECSC, `CSI s`, `CSI ?1048 h`, `CSI ?1049 h`). `charsets` packs the
     * G0–G3 designations (2 bits each, `charsetAscii`, `charsetDecGraphics`, `charsetUk`)
     * and the GL shift (bits 8–9).
     */
    public struct SavedCursor: Equatable, Sendable {
        public let column: Int
        public let row: Int
        public let pendingWrap: Bool
        public let style: Int64
        public let autoWrap: Bool
        public let originMode: Bool
        public let charsets: Int

        public init(_ column: Int, _ row: Int, _ pendingWrap: Bool, _ style: Int64, _ autoWrap: Bool,
                    _ originMode: Bool, _ charsets: Int) {
            self.column = column
            self.row = row
            self.pendingWrap = pendingWrap
            self.style = style
            self.autoWrap = autoWrap
            self.originMode = originMode
            self.charsets = charsets
        }
    }

    /** Charset designation: US ASCII (`ESC ( B` and anything unsupported). */
    public static let charsetAscii = 0
    /** Charset designation: DEC special graphics, line drawing (`ESC ( 0`). */
    public static let charsetDecGraphics = 1
    /** Charset designation: United Kingdom, `#` is `£` (`ESC ( A`). */
    public static let charsetUk = 2
    /** Java-named aliases of the charset constants. */
    public static let CHARSET_ASCII = charsetAscii
    public static let CHARSET_DEC_GRAPHICS = charsetDecGraphics
    public static let CHARSET_UK = charsetUk

    private static let MIN_COLUMNS = 2
    private static let MAX_PARAMS = 32
    private static let MAX_TITLE_STACK = 10
    private static let MAX_KITTY_STACK = 16
    private static let MAX_TITLE_LENGTH = 4096
    private static let DA1_REPLY: [UInt8] = Array("\u{1b}[?62;22c".utf8)
    private static let DA2_REPLY: [UInt8] = Array("\u{1b}[>0;10;0c".utf8)
    private static let XTVERSION = "microhm-vt"
    private static let XTGETTCAP_INVALID: [UInt8] = Array("\u{1b}P0+r\u{1b}\\".utf8)

    /** DEC special graphics for 0x5F..0x7E. */
    private static let DEC_GRAPHICS: [Int32] = [
        0x00a0, 0x25c6, 0x2592, 0x2409, 0x240c, 0x240d, 0x240a, 0x00b0, 0x00b1, 0x2424, 0x240b, 0x2518,
        0x2510, 0x250c, 0x2514, 0x253c, 0x23ba, 0x23bb, 0x2500, 0x23bc, 0x23bd, 0x251c, 0x2524, 0x2534,
        0x252c, 0x2502, 0x2264, 0x2265, 0x03c0, 0x2260, 0x00a3, 0x00b7,
    ]

    private let mutex = NSRecursiveLock()
    private let tokenizer = VtTokenizer()
    /** Tokens `applyFed` applied in the current `feed`. */
    private var tokensApplied = 0

    private var _columns: Int
    private var _rows: Int
    private let main: ScreenBuffer
    private let alt: ScreenBuffer
    private var screen: ScreenBuffer

    // Cursor and pen.
    private var cx = 0
    private var cy = 0
    private var pendingWrap = false
    private var _pen: Int64 = 0
    private var savedMain: SavedCursor?
    private var savedAlt: SavedCursor?
    private var lastPrinted = 0

    // Margins (0-based, inclusive).
    private var _scrollTop = 0
    private var _scrollBottom = 0
    private var tabStops: [Bool]

    // Charsets.
    private var charsets = [0, 0, 0, 0]
    private var gl = 0
    private var singleShift = -1

    // Modes.
    private var _autoWrap = true
    private var _originMode = false
    private var _insertMode = false
    private var _newLineMode = false
    private var _applicationCursorKeys = false
    private var _applicationKeypad = false
    private var _cursorVisible = true
    private var _cursorBlink = false
    private var _cursorShape = 0
    private var _reverseVideo = false
    private var _bracketedPaste = false
    private var _focusReporting = false
    private var _synchronizedOutput = false
    private var _colorSchemeUpdates = false
    private var _colorScheme: ColorScheme?
    private var _mouseTracking = MouseTracking.none
    private var _mouseEncoding = MouseEncoding.default
    /** The kitty flags stack; the top is the last element. */
    private var kittyFlags: [Int] = []

    private var _title = ""
    /** The title stack; the top is the last element. */
    private var titleStack: [String] = []

    // UTF-8 decoder state, carried across TEXT tokens.
    private var utf8Need = 0
    private var utf8Code = 0
    private var utf8Min = 0

    // Parsed CSI parameters (reused).
    private let params = UnsafeMutablePointer<Int>.allocate(capacity: 32)
    private let subParam = UnsafeMutablePointer<Bool>.allocate(capacity: 32)
    private var paramCount = 0

    // Outputs of the batch being applied, delivered after unlocking.
    private var replySink: ReplySink?
    private var replyScope = ReplyScope.basic
    private var pendingReplies: [[UInt8]] = []
    private var pendingBells = 0
    private var titleDirty = false
    private var listener: TerminalListener?
    private var _changeCount: Int64 = 0

    /** A `columns` × `rows` terminal keeping up to `maxHistoryLines` lines of main-screen
     * scrollback. Columns below 2 and rows below 1 are raised to those minimums. */
    public init(_ columns: Int, _ rows: Int, _ maxHistoryLines: Int) {
        _columns = max(TerminalEmulator.MIN_COLUMNS, columns)
        _rows = max(1, rows)
        main = ScreenBuffer(_columns, _rows, maxHistoryLines)
        alt = ScreenBuffer(_columns, _rows, 0)
        screen = main
        tabStops = TerminalEmulator.defaultTabStops(_columns)
        params.initialize(repeating: 0, count: 32)
        subParam.initialize(repeating: false, count: 32)
        resetState()
    }

    public convenience init(columns: Int, rows: Int, maxHistoryLines: Int) {
        self.init(columns, rows, maxHistoryLines)
    }

    deinit {
        params.deallocate()
        subParam.deallocate()
    }

    // =====================================================================================
    // Input
    // =====================================================================================

    /** Routes replies to `sink` (nil drops them) answering queries in `scope`. */
    public func setReplies(_ sink: ReplySink?, _ scope: ReplyScope) {
        mutex.lock()
        defer { mutex.unlock() }
        replySink = sink
        replyScope = scope
    }

    /**
     * The scheme `CSI ? 996 n` is answered with; nil (the default) leaves it unanswered. When
     * the scheme changes while the program has DECSET 2031 on, the new report is sent at once
     * (on the calling thread, outside the lock).
     */
    public func setColorScheme(_ scheme: ColorScheme?) {
        var sink: ReplySink?
        mutex.lock()
        let notify = _colorSchemeUpdates && scheme != nil && scheme != _colorScheme
        _colorScheme = scheme
        sink = notify ? replySink : nil
        mutex.unlock()
        if let sink = sink, let scheme = scheme {
            sink(TerminalEmulator.colorSchemeReport(scheme))
        }
    }

    /** The scheme given to `setColorScheme`, or nil. */
    public func colorScheme() -> ColorScheme? {
        return _colorScheme
    }

    private static func colorSchemeReport(_ scheme: ColorScheme) -> [UInt8] {
        return Array("\u{1b}[?997;\(scheme.report)n".utf8)
    }

    /** Sets the (single) listener; nil removes it. Held strongly, as in Java. */
    public func setListener(_ listener: TerminalListener?) {
        mutex.lock()
        self.listener = listener
        mutex.unlock()
    }

    /** The lock guarding the model; see the class documentation. Reentrant. */
    public func lock() -> NSRecursiveLock {
        return mutex
    }

    /** Incremented by every `apply`, `feed` and `resize` that may have changed what a renderer
     * shows. Safe to read without the lock. */
    public func changeCount() -> Int64 {
        return _changeCount
    }

    /**
     * Feeds raw program output (any chunking): runs it through this emulator's own
     * `VtTokenizer` and applies the completed tokens. For the client side; the daemon tokenizes
     * itself and calls `apply`.
     */
    public func feed(_ data: UnsafeBufferPointer<UInt8>) {
        mutex.lock()
        tokensApplied = 0
        tokenizer.feed(data) { kind, b in
            self.tokensApplied += 1
            self.applyToken(kind, b)
        }
        if tokensApplied == 0 {
            mutex.unlock()
            return
        }
        let outcome = endBatch()
        mutex.unlock()
        deliver(outcome)
    }

    public func feed(_ data: [UInt8], _ off: Int, _ len: Int) {
        data.withUnsafeBufferPointer { p in
            feed(UnsafeBufferPointer(rebasing: p[off..<(off + len)]))
        }
    }

    /** `feed(_:_:_:)` for a whole array. */
    public func feed(_ data: [UInt8]) {
        data.withUnsafeBufferPointer { feed($0) }
    }

    /** Applies complete tokens in order (as produced by `VtTokenizer`). */
    public func apply(_ tokens: [VtToken]) {
        if tokens.isEmpty {
            return
        }
        mutex.lock()
        for token in tokens {
            token.bytes.withUnsafeBufferPointer { applyToken(token.kind, $0) }
        }
        let outcome = endBatch()
        mutex.unlock()
        deliver(outcome)
    }

    /** What a batch of tokens left to do outside the lock. */
    private struct Outcome {
        let replies: [[UInt8]]
        let sink: ReplySink?
        let bells: Int
        let newTitle: String?
        let listener: TerminalListener?
    }

    /** Under the lock, after a batch: counts the change and takes its pending effects. */
    private func endBatch() -> Outcome {
        _changeCount += 1
        let replies = pendingReplies
        pendingReplies.removeAll()
        let bells = pendingBells
        pendingBells = 0
        let newTitle = titleDirty ? _title : nil
        titleDirty = false
        return Outcome(replies: replies, sink: replySink, bells: bells, newTitle: newTitle, listener: listener)
    }

    /** Outside the lock: sends the replies and tells the listener. */
    private func deliver(_ outcome: Outcome) {
        if let sink = outcome.sink {
            for reply in outcome.replies {
                sink(reply)
            }
        }
        if let l = outcome.listener {
            if let title = outcome.newTitle {
                l.titleChanged(title)
            }
            if outcome.bells > 0 {
                l.bell(outcome.bells)
            }
            l.contentChanged()
        }
    }

    /**
     * Resizes both screens without reflow: lines are truncated or padded; when the screen
     * loses rows, blank rows below the cursor go first, then rows are pushed off the top (into
     * history on the main screen) so the cursor row stays visible. The scroll region is reset
     * to the full screen and the cursor is kept inside it.
     */
    public func resize(_ newColumns: Int, _ newRows: Int) {
        let newColumns = max(TerminalEmulator.MIN_COLUMNS, newColumns)
        let newRows = max(1, newRows)
        mutex.lock()
        if newColumns == _columns && newRows == _rows {
            mutex.unlock()
            return
        }
        let onAlt = screen === alt
        let activePush = rowsToPush(screen, cy, newRows)
        let otherSaved = onAlt ? savedMain : savedAlt
        let other = onAlt ? main : alt
        let otherCursor = otherSaved?.row ?? lastNonBlankRow(other)
        let otherPush = rowsToPush(other, otherCursor, newRows)
        screen.resize(newColumns, newRows, activePush)
        other.resize(newColumns, newRows, otherPush)
        cy = TerminalEmulator.clamp(cy - activePush, 0, newRows - 1)
        cx = min(cx, newColumns - 1)
        pendingWrap = false
        savedMain = TerminalEmulator.shiftSaved(savedMain, onAlt ? otherPush : activePush, newColumns, newRows)
        savedAlt = TerminalEmulator.shiftSaved(savedAlt, onAlt ? activePush : otherPush, newColumns, newRows)
        var stops = TerminalEmulator.defaultTabStops(newColumns)
        for x in 0..<min(tabStops.count, newColumns) {
            stops[x] = tabStops[x]
        }
        tabStops = stops
        _columns = newColumns
        _rows = newRows
        _scrollTop = 0
        _scrollBottom = newRows - 1
        _changeCount += 1
        let l = listener
        mutex.unlock()
        l?.contentChanged()
    }

    private func rowsToPush(_ buffer: ScreenBuffer, _ cursorRow: Int, _ newRows: Int) -> Int {
        let lose = _rows - newRows
        if lose <= 0 {
            return 0
        }
        var blankBelow = 0
        var y = _rows - 1
        while y > cursorRow && blankBelow < lose {
            if !TerminalEmulator.isBlankLine(buffer.row(y)) {
                break
            }
            blankBelow += 1
            y -= 1
        }
        return lose - blankBelow
    }

    private func lastNonBlankRow(_ buffer: ScreenBuffer) -> Int {
        var y = _rows - 1
        while y >= 0 {
            if !TerminalEmulator.isBlankLine(buffer.row(y)) {
                return y
            }
            y -= 1
        }
        return 0
    }

    private static func shiftSaved(_ saved: SavedCursor?, _ pushed: Int, _ newColumns: Int, _ newRows: Int) -> SavedCursor? {
        guard let saved = saved else {
            return nil
        }
        return SavedCursor(min(saved.column, newColumns - 1), clamp(saved.row - pushed, 0, newRows - 1), false,
                           saved.style, saved.autoWrap, saved.originMode, saved.charsets)
    }

    private static func isBlankLine(_ line: Line) -> Bool {
        let cps = line.codePoints
        let sts = line.styles
        for x in 0..<line.count {
            if cps[x] != 0 || sts[x] != Style.default {
                return false
            }
        }
        return true
    }

    // =====================================================================================
    // Read API (hold lock())
    // =====================================================================================

    public func columns() -> Int {
        return _columns
    }

    public func rows() -> Int {
        return _rows
    }

    /** Lines of main-screen scrollback currently held (0 while the alternate screen is shown). */
    public func historySize() -> Int {
        return screen.history()
    }

    /**
     * Lines ever moved into the main screen's scrollback: monotonic, not reduced when the
     * oldest lines fall out of a full history or the history is cleared. A renderer keeps a
     * scrolled-back view (or a selection) anchored by adding the growth since its last frame,
     * which `historySize()` alone cannot show once the history is full.
     */
    public func historyLinesAdded() -> Int64 {
        return main.linesAdded()
    }

    /** History line (`-historySize()..-1`) or screen row (`0..rows()-1`). Traps when out of
     * range (Java throws IndexOutOfBoundsException). */
    public func line(_ index: Int) -> Line {
        precondition(index >= -screen.history() && index < _rows, "line \(index)")
        return screen.line(index)
    }

    /** Main-screen line by the same indexing, even while the alternate screen is shown (for
     * the serializer). */
    func mainLine(_ index: Int) -> Line {
        return main.line(index)
    }

    func mainHistorySize() -> Int {
        return main.history()
    }

    public func cursorRow() -> Int {
        return cy
    }

    public func cursorColumn() -> Int {
        return cx
    }

    /** True when the last column was just written and the next printable character wraps. */
    public func cursorPendingWrap() -> Bool {
        return pendingWrap
    }

    /** DECTCEM (`CSI ?25 h/l`). */
    public func cursorVisible() -> Bool {
        return _cursorVisible
    }

    /** DECSCUSR: 0 never set (the renderer's default), 1/2 blinking/steady block, 3/4
     * underline, 5/6 bar (`CSI 0 SP q` reads as 1). */
    public func cursorShape() -> Int {
        return _cursorShape
    }

    /** att610 cursor blinking (`CSI ?12 h/l`). */
    public func cursorBlink() -> Bool {
        return _cursorBlink
    }

    /** The current pen: the `Style` the next character is written with. */
    public func pen() -> Int64 {
        return _pen
    }

    public func alternateScreen() -> Bool {
        return screen === alt
    }

    public func bracketedPaste() -> Bool {
        return _bracketedPaste
    }

    /** DECCKM: arrow keys send SS3 sequences. */
    public func applicationCursorKeys() -> Bool {
        return _applicationCursorKeys
    }

    /** DECKPAM / DECKPNM. */
    public func applicationKeypad() -> Bool {
        return _applicationKeypad
    }

    public func mouseTracking() -> MouseTracking {
        return _mouseTracking
    }

    public func mouseEncoding() -> MouseEncoding {
        return _mouseEncoding
    }

    /** DECSET 1004: send focus in/out. */
    public func focusReporting() -> Bool {
        return _focusReporting
    }

    /** DECSET 2031: the program asked to be told when the colour scheme changes. */
    public func colorSchemeUpdates() -> Bool {
        return _colorSchemeUpdates
    }

    /** DECSET 2026: the program is mid-frame; a renderer may hold painting until it ends (with
     * a timeout of its own). */
    public func synchronizedOutput() -> Bool {
        return _synchronizedOutput
    }

    /** DECSCNM: the whole screen is shown in reverse video. */
    public func reverseVideo() -> Bool {
        return _reverseVideo
    }

    /** DECAWM. */
    public func autoWrap() -> Bool {
        return _autoWrap
    }

    /** DECOM. */
    public func originMode() -> Bool {
        return _originMode
    }

    /** IRM (`CSI 4 h`). */
    public func insertMode() -> Bool {
        return _insertMode
    }

    /** LNM (`CSI 20 h`): LF also returns the carriage, Enter should send CR LF. */
    public func newLineMode() -> Bool {
        return _newLineMode
    }

    /** Top margin of the scroll region, 0-based inclusive. */
    public func scrollTop() -> Int {
        return _scrollTop
    }

    /** Bottom margin of the scroll region, 0-based inclusive. */
    public func scrollBottom() -> Int {
        return _scrollBottom
    }

    /** The kitty keyboard protocol flags the program last pushed or set (0 = legacy keys).
     * Tracked only; key encoding is the renderer's business. */
    public func kittyKeyboardFlags() -> Int {
        return kittyFlags.last ?? 0
    }

    /** The window title (OSC 0/1/2), "" if never set. */
    public func title() -> String {
        return _title
    }

    /** Whether column `x` is a tab stop. */
    public func isTabStop(_ x: Int) -> Bool {
        return x >= 0 && x < tabStops.count && tabStops[x]
    }

    /** True when the tab stops are the power-on ones (every 8 columns). */
    func defaultTabs() -> Bool {
        for x in 0..<tabStops.count where tabStops[x] != (x > 0 && x % 8 == 0) {
            return false
        }
        return true
    }

    /** The cursor saved on the main (`alternate == false`) or alternate screen, or nil when
     * nothing was saved there. */
    public func savedCursor(_ alternate: Bool) -> SavedCursor? {
        return alternate ? savedAlt : savedMain
    }

    /** The packed charset state (as in `SavedCursor.charsets`). */
    public func charsetState() -> Int {
        return packCharsets()
    }

    // =====================================================================================
    // Token dispatch
    // =====================================================================================

    /** Applies one token. Sequences are parsed in place, so `b` may be a buffer the tokenizer
     * reuses. */
    private func applyToken(_ kind: VtToken.Kind, _ buf: UnsafeBufferPointer<UInt8>) {
        guard let b = buf.baseAddress, buf.count > 0 else {
            return
        }
        let len = buf.count
        if kind == .text {
            printUtf8(b, 0, len)
            return
        }
        flushUtf8()
        switch kind {
        case .control:
            control(b[0])
        case .csi:
            csi(b, len)
        case .escape:
            escape(b, len)
        case .osc:
            osc(b, len)
        case .string:
            deviceControlString(b, len)
        default:
            break
        }
    }

    private func control(_ c: UInt8) {
        switch c {
        case 0x07:
            pendingBells += 1
        case 0x08:
            backspace()
        case 0x09:
            tabForward(1)
        case 0x0A, 0x0B, 0x0C:
            index()
            if _newLineMode {
                cx = 0
            }
        case 0x0D:
            cx = 0
            pendingWrap = false
        case 0x0E:
            gl = 1 // SO: G1 into GL
        case 0x0F:
            gl = 0 // SI: G0 into GL
        default:
            break // NUL, ENQ, DEL and the rest: ignored.
        }
    }

    // --- printing ---------------------------------------------------------------------

    private func printUtf8(_ b: UnsafePointer<UInt8>, _ from: Int, _ n: Int) {
        var i = from
        while i < n {
            let c = b[i]
            if utf8Need == 0 && c < 0x80 {
                if c < 0x20 || c == 0x7F {
                    i += 1 // never produced by the tokenizer; ignore defensively
                    continue
                }
                var end = i + 1
                while end < n && b[end] >= 0x20 && b[end] < 0x7F {
                    end += 1
                }
                if singleShift < 0 && charsets[gl] == TerminalEmulator.charsetAscii && !_insertMode {
                    printAscii(b, i, end)
                } else {
                    for k in i..<end {
                        print(Int(b[k]))
                    }
                }
                i = end
                continue
            }
            decodeByte(Int(c))
            i += 1
        }
    }

    /** One byte of a multi-byte UTF-8 sequence (or a stray continuation/invalid byte). */
    private func decodeByte(_ c: Int) {
        if utf8Need > 0 {
            if (c & 0xC0) == 0x80 {
                utf8Code = (utf8Code << 6) | (c & 0x3F)
                utf8Need -= 1
                if utf8Need == 0 {
                    var cp = utf8Code
                    if cp < utf8Min || cp > 0x10FFFF || (cp >= 0xD800 && cp <= 0xDFFF) {
                        cp = 0xFFFD
                    }
                    print(cp)
                }
                return
            }
            // Truncated sequence: replace it and reprocess this byte.
            utf8Need = 0
            print(0xFFFD)
            if c < 0x80 {
                if c >= 0x20 && c != 0x7F {
                    print(c)
                }
                return
            }
        }
        if c >= 0xC2 && c <= 0xDF {
            utf8Need = 1
            utf8Code = c & 0x1F
            utf8Min = 0x80
        } else if c >= 0xE0 && c <= 0xEF {
            utf8Need = 2
            utf8Code = c & 0x0F
            utf8Min = 0x800
        } else if c >= 0xF0 && c <= 0xF4 {
            utf8Need = 3
            utf8Code = c & 0x07
            utf8Min = 0x10000
        } else {
            print(0xFFFD)
        }
    }

    /** A control or sequence interrupted a partial UTF-8 character. */
    @inline(__always)
    private func flushUtf8() {
        if utf8Need > 0 {
            utf8Need = 0
            print(0xFFFD)
        }
    }

    /** Fast path: printable ASCII with GL = ASCII and replace mode. */
    private func printAscii(_ b: UnsafePointer<UInt8>, _ from: Int, _ to: Int) {
        var i = from
        let columns = _columns
        while i < to {
            if pendingWrap {
                pendingWrap = false
                if _autoWrap {
                    wrapLine()
                }
            }
            let line = screen.row(cy)
            let x = cx
            let n = min(columns - x, to - i)
            line.breakWide(x, x + n)
            line.touch()
            let cps = line.codePoints
            let styles = line.styles
            let p = _pen
            for k in 0..<n {
                cps[x + k] = Int32(b[i + k])
                styles[x + k] = p
            }
            if line.extras != nil {
                for k in 0..<n {
                    line.extras![x + k] = nil
                }
            }
            lastPrinted = Int(b[i + n - 1])
            cx = x + n
            i += n
            if cx >= columns {
                cx = columns - 1
                pendingWrap = true
            }
        }
    }

    private func print(_ cpIn: Int) {
        var cp = cpIn
        if cp < 0x80 {
            cp = mapCharset(cp)
        } else if cp < 0xA0 {
            return // C1 controls as UTF-8: not printable, not interpreted
        }
        singleShift = -1
        let width = CharWidth.of(cp)
        if width == 0 || joinsPrevious(cp) {
            attach(cp)
            return
        }
        if pendingWrap {
            pendingWrap = false
            if _autoWrap {
                wrapLine()
            }
        }
        if width == 2 && cx == _columns - 1 {
            if !_autoWrap {
                return // a wide character cannot be shown in the last column
            }
            // It does not fit: leave the last cell empty and wrap.
            screen.row(cy).erase(cx, cx + 1, Style.eraseStyle(_pen))
            wrapLine()
        }
        let line = screen.row(cy)
        if _insertMode {
            line.insertCells(cx, width, Style.default)
        }
        line.breakWide(cx, cx + width)
        if width == 2 {
            line.setWide(cx, Int32(cp), _pen)
        } else {
            line.set(cx, Int32(cp), _pen)
        }
        lastPrinted = cp
        cx += width
        if cx >= _columns {
            cx = _columns - 1
            pendingWrap = true
        }
    }

    private func mapCharset(_ cp: Int) -> Int {
        let set = charsets[singleShift >= 0 ? singleShift : gl]
        if set == TerminalEmulator.charsetDecGraphics && cp >= 0x5F && cp <= 0x7E {
            return Int(TerminalEmulator.DEC_GRAPHICS[cp - 0x5F])
        }
        if set == TerminalEmulator.charsetUk && cp == 0x23 {
            return 0xA3
        }
        return cp
    }

    /** The cell a zero-width code point attaches to: the last one written before the cursor
     * (the lead of a wide character), or -1. */
    private func attachTarget() -> Int {
        let x = pendingWrap ? cx : cx - 1
        if x < 0 {
            return -1
        }
        return screen.row(cy).isWideTail(x) ? x - 1 : x
    }

    /** Code points that have a width but join the previous cell's grapheme: anything but ASCII
     * after a ZWJ, the second regional indicator of a flag, and emoji skin-tone modifiers.
     * (ASCII never joins, so the ASCII fast path needs no check.) */
    private func joinsPrevious(_ cp: Int) -> Bool {
        if cp < 0x80 {
            return false
        }
        let x = attachTarget()
        if x < 0 {
            return false
        }
        let line = screen.row(cy)
        if line.lastExtra(x) == 0x200D {
            return true
        }
        if TerminalEmulator.isRegionalIndicator(cp) {
            return TerminalEmulator.isRegionalIndicator(line.codePoint(x)) && !line.hasExtras(x)
        }
        return cp >= 0x1F3FB && cp <= 0x1F3FF && line.width(x) == 2
    }

    private static func isRegionalIndicator(_ cp: Int) -> Bool {
        return cp >= 0x1F1E6 && cp <= 0x1F1FF
    }

    private func attach(_ cp: Int) {
        let x = attachTarget()
        if x < 0 {
            return
        }
        let line = screen.row(cy)
        if line.codePoint(x) != 0 {
            line.attach(x, cp)
        }
    }

    /** The deferred wrap: mark the row soft-wrapped and move to the next line. */
    private func wrapLine() {
        screen.row(cy).setWrapped(true)
        cx = 0
        index()
    }

    private func repeatLast(_ count: Int) {
        if lastPrinted <= 0 {
            return
        }
        let cp = lastPrinted
        let count = min(count, _columns * _rows)
        for _ in 0..<count {
            print(cp)
        }
    }

    // --- cursor movement --------------------------------------------------------------

    /** LF/IND: down one row, scrolling the region when on its bottom margin. */
    private func index() {
        pendingWrap = false
        if cy == _scrollBottom {
            scrollUp(1)
        } else if cy < _rows - 1 {
            cy += 1
        }
    }

    /** RI: up one row, scrolling the region down when on its top margin. */
    private func reverseIndex() {
        pendingWrap = false
        if cy == _scrollTop {
            screen.scrollDown(_scrollTop, _scrollBottom, 1, Style.eraseStyle(_pen))
        } else if cy > 0 {
            cy -= 1
        }
    }

    private func scrollUp(_ n: Int) {
        let toHistory = screen === main && _scrollTop == 0
        screen.scrollUp(_scrollTop, _scrollBottom, n, Style.eraseStyle(_pen), toHistory)
    }

    private func backspace() {
        pendingWrap = false
        if cx > 0 {
            cx -= 1
        }
    }

    private func tabForward(_ n: Int) {
        pendingWrap = false
        var i = 0
        while i < n && cx < _columns - 1 {
            repeat {
                cx += 1
            } while cx < _columns - 1 && !tabStops[cx]
            i += 1
        }
    }

    private func tabBackward(_ n: Int) {
        pendingWrap = false
        var i = 0
        while i < n && cx > 0 {
            repeat {
                cx -= 1
            } while cx > 0 && !tabStops[cx]
            i += 1
        }
    }

    private func cursorUp(_ n: Int) {
        pendingWrap = false
        let limit = cy >= _scrollTop ? _scrollTop : 0
        cy = max(limit, cy - n)
    }

    private func cursorDown(_ n: Int) {
        pendingWrap = false
        let limit = cy <= _scrollBottom ? _scrollBottom : _rows - 1
        cy = min(limit, cy + n)
    }

    private func setColumn(_ x: Int) {
        pendingWrap = false
        cx = TerminalEmulator.clamp(x, 0, _columns - 1)
    }

    /** Moves to row `y` (0-based), relative to the region in origin mode. */
    private func setRow(_ y: Int) {
        pendingWrap = false
        if _originMode {
            cy = TerminalEmulator.clamp(_scrollTop + y, _scrollTop, _scrollBottom)
        } else {
            cy = TerminalEmulator.clamp(y, 0, _rows - 1)
        }
    }

    private func home() {
        setRow(0)
        setColumn(0)
    }

    // --- saved cursor -----------------------------------------------------------------

    private func saveCursor() {
        let saved = SavedCursor(cx, cy, pendingWrap, _pen, _autoWrap, _originMode, packCharsets())
        if screen === alt {
            savedAlt = saved
        } else {
            savedMain = saved
        }
    }

    private func restoreCursor() {
        guard let saved = screen === alt ? savedAlt : savedMain else {
            // Nothing saved: home, default pen, origin off, default charsets.
            _originMode = false
            _pen = Style.default
            resetCharsets()
            cx = 0
            cy = 0
            pendingWrap = false
            return
        }
        cx = min(saved.column, _columns - 1)
        cy = min(saved.row, _rows - 1)
        pendingWrap = saved.pendingWrap && cx == _columns - 1
        _pen = saved.style
        _autoWrap = saved.autoWrap
        _originMode = saved.originMode
        if _originMode && (cy < _scrollTop || cy > _scrollBottom) {
            // As xterm's CursorRestore: in origin mode the cursor is confined to the region.
            cy = TerminalEmulator.clamp(cy, _scrollTop, _scrollBottom)
            pendingWrap = false
        }
        unpackCharsets(saved.charsets)
    }

    private func packCharsets() -> Int {
        return charsets[0] | charsets[1] << 2 | charsets[2] << 4 | charsets[3] << 6 | gl << 8
    }

    private func unpackCharsets(_ packed: Int) {
        for i in 0..<4 {
            charsets[i] = (packed >> (2 * i)) & 3
        }
        gl = (packed >> 8) & 3
        singleShift = -1
    }

    private func resetCharsets() {
        charsets = [0, 0, 0, 0]
        gl = 0
        singleShift = -1
    }

    // --- screens ----------------------------------------------------------------------

    private func enterAlternate(_ clear: Bool) {
        if screen !== alt {
            screen = alt
        }
        if clear {
            clearScreen(alt, Style.default)
        }
    }

    private func leaveAlternate(_ clear: Bool) {
        if screen === alt {
            if clear {
                clearScreen(alt, Style.default)
            }
            screen = main
        }
    }

    private func clearScreen(_ buffer: ScreenBuffer, _ fill: Int64) {
        for y in 0..<_rows {
            buffer.row(y).clear(fill)
        }
    }

    // --- erase ------------------------------------------------------------------------

    private func eraseInDisplay(_ mode: Int) {
        let fill = Style.eraseStyle(_pen)
        pendingWrap = false
        switch mode {
        case 0:
            let line = screen.row(cy)
            line.erase(cx, _columns, fill)
            line.setWrapped(false)
            var y = cy + 1
            while y < _rows {
                screen.row(y).clear(fill)
                y += 1
            }
        case 1:
            for y in 0..<cy {
                screen.row(y).clear(fill)
            }
            screen.row(cy).erase(0, cx + 1, fill)
        case 2:
            if screen === main {
                // As VTE and jediterm do: the screen's content goes to the scrollback instead
                // of being lost (the region is irrelevant here).
                let last = lastNonBlankRow(main)
                if last > 0 || !TerminalEmulator.isBlankLine(main.row(0)) {
                    main.scrollUp(0, _rows - 1, last + 1, Style.default, true)
                }
            }
            clearScreen(screen, fill)
        case 3:
            screen.clearHistory()
        default:
            break
        }
    }

    private func eraseInLine(_ mode: Int) {
        let fill = Style.eraseStyle(_pen)
        pendingWrap = false
        let line = screen.row(cy)
        switch mode {
        case 0:
            line.erase(cx, _columns, fill)
            line.setWrapped(false)
        case 1:
            line.erase(0, cx + 1, fill)
        case 2:
            line.erase(0, _columns, fill)
            line.setWrapped(false)
        default:
            break
        }
    }

    private func insertLines(_ n: Int) {
        if cy < _scrollTop || cy > _scrollBottom {
            return
        }
        screen.scrollDown(cy, _scrollBottom, n, Style.eraseStyle(_pen))
        cx = 0
        pendingWrap = false
    }

    private func deleteLines(_ n: Int) {
        if cy < _scrollTop || cy > _scrollBottom {
            return
        }
        screen.scrollUp(cy, _scrollBottom, n, Style.eraseStyle(_pen), false)
        cx = 0
        pendingWrap = false
    }

    // --- reset ------------------------------------------------------------------------

    /** Power-on state of everything but the screens' contents and the title. */
    private func resetState() {
        cx = 0
        cy = 0
        pendingWrap = false
        _pen = Style.default
        savedMain = nil
        savedAlt = nil
        lastPrinted = 0
        _scrollTop = 0
        _scrollBottom = _rows - 1
        tabStops = TerminalEmulator.defaultTabStops(_columns)
        resetCharsets()
        _autoWrap = true
        _originMode = false
        _insertMode = false
        _newLineMode = false
        _applicationCursorKeys = false
        _applicationKeypad = false
        _cursorVisible = true
        _cursorBlink = false
        _cursorShape = 0
        _reverseVideo = false
        _bracketedPaste = false
        _focusReporting = false
        _synchronizedOutput = false
        _colorSchemeUpdates = false
        _mouseTracking = .none
        _mouseEncoding = .default
        kittyFlags.removeAll()
        titleStack.removeAll()
    }

    /** RIS: everything back to power-on, both screens and the history cleared. The title is
     * kept (it is the window's, as in jediterm and `ModeTracker`). */
    private func fullReset() {
        screen = main
        clearScreen(main, Style.default)
        clearScreen(alt, Style.default)
        main.clearHistory()
        resetState()
    }

    /** DECSTR. */
    private func softReset() {
        _cursorVisible = true
        _insertMode = false
        _originMode = false
        _autoWrap = true
        _applicationKeypad = false
        _applicationCursorKeys = false
        _scrollTop = 0
        _scrollBottom = _rows - 1
        _pen = Style.default
        resetCharsets()
        if screen === alt {
            savedAlt = nil
        } else {
            savedMain = nil
        }
    }

    private static func defaultTabStops(_ columns: Int) -> [Bool] {
        var stops = [Bool](repeating: false, count: columns)
        var x = 8
        while x < columns {
            stops[x] = true
            x += 8
        }
        return stops
    }

    // =====================================================================================
    // ESC
    // =====================================================================================

    private func escape(_ b: UnsafePointer<UInt8>, _ len: Int) {
        if len == 2 {
            switch b[1] {
            case UInt8(ascii: "7"): saveCursor()
            case UInt8(ascii: "8"): restoreCursor()
            case UInt8(ascii: "D"): index()
            case UInt8(ascii: "E"):
                index()
                cx = 0
            case UInt8(ascii: "M"): reverseIndex()
            case UInt8(ascii: "H"): tabStops[cx] = true
            case UInt8(ascii: "c"): fullReset()
            case UInt8(ascii: "="): _applicationKeypad = true
            case UInt8(ascii: ">"): _applicationKeypad = false
            case UInt8(ascii: "N"): singleShift = 2
            case UInt8(ascii: "O"): singleShift = 3
            case UInt8(ascii: "n"): gl = 2
            case UInt8(ascii: "o"): gl = 3
            default:
                break // ESC \ (a lone ST), ESC F and others: ignored.
            }
            return
        }
        if len == 3 {
            let set: Int
            switch b[2] {
            case UInt8(ascii: "0"): set = TerminalEmulator.charsetDecGraphics
            case UInt8(ascii: "A"): set = TerminalEmulator.charsetUk
            default: set = TerminalEmulator.charsetAscii
            }
            switch b[1] {
            case UInt8(ascii: "("): charsets[0] = set
            case UInt8(ascii: ")"), UInt8(ascii: "-"): charsets[1] = set
            case UInt8(ascii: "*"), UInt8(ascii: "."): charsets[2] = set
            case UInt8(ascii: "+"), UInt8(ascii: "/"): charsets[3] = set
            case UInt8(ascii: "#"):
                if b[2] == UInt8(ascii: "8") {
                    alignmentTest()
                }
            default:
                break
            }
        }
    }

    /** DECALN: margins reset, cursor home, the screen filled with 'E'. */
    private func alignmentTest() {
        _scrollTop = 0
        _scrollBottom = _rows - 1
        _originMode = false
        for y in 0..<_rows {
            let line = screen.row(y)
            line.clear(Style.default)
            line.codePoints.update(repeating: 0x45, count: line.count)
            line.touch()
        }
        home()
    }

    // =====================================================================================
    // CSI
    // =====================================================================================

    /** Parses `ESC [ prefix? params intermediates final` into `params`; returns
     * `prefix << 16 | intermediate << 8 | final`, or -1 for a malformed sequence. */
    private func parseCsi(_ b: UnsafePointer<UInt8>, _ len: Int) -> Int {
        let end = len - 1
        var i = 2
        var prefix = 0
        if i < end && b[i] >= 0x3C && b[i] <= 0x3F { // '<' .. '?'
            prefix = Int(b[i])
            i += 1
        }
        paramCount = 0
        var current = -1
        var nextIsSub = false
        var any = false
        var intermediate = 0
        while i < end {
            let c = Int(b[i])
            if c >= 0x30 && c <= 0x39 {
                if intermediate != 0 {
                    return -1
                }
                current = current < 0 ? c - 0x30 : min(current * 10 + (c - 0x30), 0xFFFF)
                any = true
            } else if c == 0x3B || c == 0x3A { // ';' ':'
                if intermediate != 0 {
                    return -1
                }
                pushParam(current, nextIsSub)
                current = -1
                nextIsSub = c == 0x3A
                any = true
            } else if c >= 0x20 && c <= 0x2F {
                intermediate = c
            } else {
                return -1 // a private marker in the middle, etc.
            }
            i += 1
        }
        if any {
            pushParam(current, nextIsSub)
        }
        return prefix << 16 | intermediate << 8 | Int(b[end])
    }

    @inline(__always)
    private func pushParam(_ value: Int, _ sub: Bool) {
        if paramCount < TerminalEmulator.MAX_PARAMS {
            params[paramCount] = value
            subParam[paramCount] = sub
            paramCount += 1
        }
    }

    /** Parameter `k`, or `def` when absent. */
    @inline(__always)
    private func arg(_ k: Int, _ def: Int) -> Int {
        return k < paramCount && params[k] >= 0 ? params[k] : def
    }

    /** Parameter `k` where 0 and absent both mean 1 (counts). */
    @inline(__always)
    private func count(_ k: Int) -> Int {
        let v = arg(k, 1)
        return v == 0 ? 1 : v
    }

    private func hasSubParams() -> Bool {
        for k in 0..<paramCount where subParam[k] {
            return true
        }
        return false
    }

    private func csi(_ b: UnsafePointer<UInt8>, _ len: Int) {
        let key = parseCsi(b, len)
        if key < 0 {
            return
        }
        let fin = key & 0xFF
        let intermediate = (key >> 8) & 0xFF
        let prefix = key >> 16
        if fin == 0x6D && prefix == 0 && intermediate == 0 { // 'm'
            sgr()
            return
        }
        if hasSubParams() {
            return
        }
        switch prefix {
        case 0:
            if intermediate == 0 {
                csiPlain(fin)
            } else {
                csiIntermediate(intermediate, fin)
            }
        case 0x3F: // '?'
            if intermediate == 0 {
                csiPrivate(fin)
            } else if intermediate == 0x24 && fin == 0x70 { // '$' 'p'
                requestMode(true)
            }
        case 0x3E: // '>'
            csiGreater(fin)
        case 0x3C: // '<'
            if fin == 0x75 && intermediate == 0 { // 'u'
                var i = min(count(0), kittyFlags.count)
                while i > 0 {
                    kittyFlags.removeLast()
                    i -= 1
                }
            }
        case 0x3D: // '='
            if fin == 0x75 && intermediate == 0 {
                setKittyFlags(arg(0, 0), arg(1, 1))
            }
        default:
            break
        }
    }

    private func csiPlain(_ fin: Int) {
        switch UnicodeScalar(UInt8(fin)) {
        case "@":
            pendingWrap = false
            screen.row(cy).insertCells(cx, count(0), Style.eraseStyle(_pen))
        case "A": cursorUp(count(0))
        case "B", "e": cursorDown(count(0))
        case "C", "a": setColumn(cx + count(0))
        case "D": setColumn(cx - count(0))
        case "E":
            cursorDown(count(0))
            cx = 0
        case "F":
            cursorUp(count(0))
            cx = 0
        case "G", "`": setColumn(count(0) - 1)
        case "H", "f":
            setRow(count(0) - 1)
            setColumn(count(1) - 1)
        case "I": tabForward(count(0))
        case "J": eraseInDisplay(arg(0, 0))
        case "K": eraseInLine(arg(0, 0))
        case "L": insertLines(count(0))
        case "M": deleteLines(count(0))
        case "P":
            pendingWrap = false
            screen.row(cy).deleteCells(cx, count(0), Style.eraseStyle(_pen))
        case "S": scrollUp(count(0))
        case "T":
            if paramCount <= 1 { // more parameters: xterm's mouse highlight tracking
                screen.scrollDown(_scrollTop, _scrollBottom, count(0), Style.eraseStyle(_pen))
            }
        case "X":
            pendingWrap = false
            screen.row(cy).erase(cx, cx + count(0), Style.eraseStyle(_pen))
        case "Z": tabBackward(count(0))
        case "b": repeatLast(count(0))
        case "c":
            // DA1, CSI c / CSI 0 c only: with a private marker it is not this query (CSI ? Ps c
            // sets the Linux console's cursor), and a reply would be typed at a program that
            // asked nothing.
            if arg(0, 0) == 0 {
                reply(TerminalEmulator.DA1_REPLY)
            }
        case "d": setRow(count(0) - 1)
        case "g":
            let mode = arg(0, 0)
            if mode == 0 {
                tabStops[cx] = false
            } else if mode == 3 {
                for x in 0..<tabStops.count {
                    tabStops[x] = false
                }
            }
        case "h", "l":
            let set = fin == 0x68
            for k in 0..<paramCount {
                switch params[k] {
                case 4: _insertMode = set
                case 20: _newLineMode = set
                default: break
                }
            }
        case "n": deviceStatus(arg(0, 0))
        case "r": setScrollRegion(arg(0, 1), arg(1, _rows))
        case "s": saveCursor()
        case "t": windowOps()
        case "u":
            if paramCount == 0 {
                restoreCursor()
            }
        default:
            break
        }
    }

    private func csiIntermediate(_ intermediate: Int, _ fin: Int) {
        if intermediate == 0x20 && fin == 0x71 { // ' ' 'q'
            let ps = arg(0, 0)
            if ps <= 6 {
                _cursorShape = ps == 0 ? 1 : ps // 0 and 1 both mean a blinking block
            }
        } else if intermediate == 0x21 && fin == 0x70 { // '!' 'p'
            softReset()
        } else if intermediate == 0x24 && fin == 0x70 { // '$' 'p'
            requestMode(false)
        }
    }

    private func csiPrivate(_ fin: Int) {
        switch UnicodeScalar(UInt8(fin)) {
        case "h", "l":
            let set = fin == 0x68
            for k in 0..<paramCount {
                decPrivateMode(params[k], set)
            }
        case "J": eraseInDisplay(arg(0, 0)) // DECSED: no protected cells, so plain ED
        case "K": eraseInLine(arg(0, 0))    // DECSEL
        case "n":
            if arg(0, 0) == 6 && replyScope == .full {
                reply("\u{1b}[?\(reportRow());\(cx + 1);1R")
            } else if arg(0, 0) == 996, let scheme = _colorScheme, replySink != nil {
                // Any scope: only a client sets a scheme (the daemon never knows its theme).
                pendingReplies.append(TerminalEmulator.colorSchemeReport(scheme))
            }
        case "u":
            if replyScope == .full {
                reply("\u{1b}[?\(kittyKeyboardFlags())u")
            }
        default:
            break
        }
    }

    private func csiGreater(_ fin: Int) {
        switch UnicodeScalar(UInt8(fin)) {
        case "c":
            if arg(0, 0) == 0 {
                reply(TerminalEmulator.DA2_REPLY)
            }
        case "q":
            if replyScope == .full {
                reply("\u{1b}P>|\(TerminalEmulator.XTVERSION)\u{1b}\\")
            }
        case "u":
            if kittyFlags.count >= TerminalEmulator.MAX_KITTY_STACK {
                kittyFlags.removeFirst()
            }
            kittyFlags.append(arg(0, 0))
        default:
            break // CSI > Ps m (modifyOtherKeys) and friends: ignored.
        }
    }

    private func setKittyFlags(_ flags: Int, _ mode: Int) {
        let current = kittyKeyboardFlags()
        let next: Int
        switch mode {
        case 2: next = current | flags
        case 3: next = current & ~flags
        default: next = flags
        }
        if !kittyFlags.isEmpty {
            kittyFlags.removeLast()
        }
        kittyFlags.append(next)
    }

    private func decPrivateMode(_ mode: Int, _ set: Bool) {
        switch mode {
        case 1: _applicationCursorKeys = set
        case 5: _reverseVideo = set
        case 6:
            _originMode = set
            home()
        case 7: _autoWrap = set
        case 9: _mouseTracking = set ? .x10 : .none
        case 12: _cursorBlink = set
        case 25: _cursorVisible = set
        case 47:
            if set {
                enterAlternate(false)
            } else {
                leaveAlternate(false)
            }
        case 1047:
            if set {
                enterAlternate(false)
            } else {
                leaveAlternate(true)
            }
        case 1048:
            if set {
                saveCursor()
            } else {
                restoreCursor()
            }
        case 1049:
            if set {
                saveCursor()
                enterAlternate(true)
            } else {
                leaveAlternate(false)
                restoreCursor()
            }
        case 1000: _mouseTracking = set ? .normal : .none
        case 1002: _mouseTracking = set ? .buttonMotion : .none
        case 1003: _mouseTracking = set ? .anyMotion : .none
        case 1004: _focusReporting = set
        case 1005: _mouseEncoding = set ? .utf8 : .default
        case 1006: _mouseEncoding = set ? .sgr : .default
        case 1015: _mouseEncoding = set ? .urxvt : .default
        case 2004: _bracketedPaste = set
        case 2026: _synchronizedOutput = set
        case 2031: _colorSchemeUpdates = set
        default:
            break // 3 (DECCOLM: no 80/132 resize), 4, 8, 45, 1001, 1007, 1034, 1039, 9001, …
        }
    }

    /** DECRQM reply (FULL scope): 1 set, 2 reset, 0 not recognised. */
    private func requestMode(_ dec: Bool) {
        if replyScope != .full {
            return
        }
        let mode = arg(0, 0)
        let value: Int
        if dec {
            value = decModeValue(mode)
        } else {
            switch mode {
            case 4: value = _insertMode ? 1 : 2
            case 20: value = _newLineMode ? 1 : 2
            default: value = 0
            }
        }
        reply("\u{1b}[\(dec ? "?" : "")\(mode);\(value)$y")
    }

    private func decModeValue(_ mode: Int) -> Int {
        let on: Bool?
        switch mode {
        case 1: on = _applicationCursorKeys
        case 5: on = _reverseVideo
        case 6: on = _originMode
        case 7: on = _autoWrap
        case 9: on = _mouseTracking == .x10
        case 12: on = _cursorBlink
        case 25: on = _cursorVisible
        case 47, 1047, 1049: on = screen === alt
        case 1000: on = _mouseTracking == .normal
        case 1002: on = _mouseTracking == .buttonMotion
        case 1003: on = _mouseTracking == .anyMotion
        case 1004: on = _focusReporting
        case 1005: on = _mouseEncoding == .utf8
        case 1006: on = _mouseEncoding == .sgr
        case 1015: on = _mouseEncoding == .urxvt
        case 2004: on = _bracketedPaste
        case 2026: on = _synchronizedOutput
        default: on = nil
        }
        guard let value = on else {
            return 0
        }
        return value ? 1 : 2
    }

    private func deviceStatus(_ code: Int) {
        if code == 5 {
            reply("\u{1b}[0n")
        } else if code == 6 {
            reply("\u{1b}[\(reportRow());\(cx + 1)R")
        }
    }

    /** The cursor row for a position report: 1-based, relative to the region in DECOM. */
    private func reportRow() -> Int {
        return (_originMode ? cy - _scrollTop : cy) + 1
    }

    private func setScrollRegion(_ topIn: Int, _ bottomIn: Int) {
        var top = topIn
        var bottom = bottomIn
        if top == 0 {
            top = 1
        }
        if bottom == 0 || bottom > _rows {
            bottom = _rows
        }
        if top >= bottom {
            return // xterm ignores a region of fewer than two lines
        }
        _scrollTop = top - 1
        _scrollBottom = bottom - 1
        home()
    }

    /** XTWINOPS: only the title stack (22/23); resizes and reports are ignored. */
    private func windowOps() {
        let op = arg(0, 0)
        let which = arg(1, 0)
        if which != 0 && which != 2 {
            return
        }
        if op == 22 {
            if titleStack.count >= TerminalEmulator.MAX_TITLE_STACK {
                titleStack.removeFirst()
            }
            titleStack.append(_title)
        } else if op == 23, let popped = titleStack.popLast() {
            setTitle(popped)
        }
    }

    // --- SGR --------------------------------------------------------------------------

    private func sgr() {
        if paramCount == 0 {
            _pen = Style.default
            return
        }
        var s = _pen
        var k = 0
        while k < paramCount {
            var end = k + 1
            while end < paramCount && subParam[end] {
                end += 1
            }
            let subCount = end - k - 1
            let a = max(0, params[k])
            switch a {
            case 0: s = Style.default
            case 1: s |= Style.BOLD
            case 2: s |= Style.DIM
            case 3: s |= Style.ITALIC
            case 4:
                s = Style.withUnderline(s, subCount > 0 ? min(max(0, params[k + 1]), 5) : Style.underlineSingle)
            case 5: s = (s | Style.BLINK) & ~Style.RAPID_BLINK
            case 6: s = (s | Style.RAPID_BLINK) & ~Style.BLINK
            case 7: s |= Style.INVERSE
            case 8: s |= Style.INVISIBLE
            case 9: s |= Style.STRIKETHROUGH
            case 21: s = Style.withUnderline(s, Style.underlineDouble)
            case 22: s &= ~(Style.BOLD | Style.DIM)
            case 23: s &= ~Style.ITALIC
            case 24: s = Style.withUnderline(s, Style.underlineNone)
            case 25: s &= ~(Style.BLINK | Style.RAPID_BLINK)
            case 27: s &= ~Style.INVERSE
            case 28: s &= ~Style.INVISIBLE
            case 29: s &= ~Style.STRIKETHROUGH
            case 30...37: s = Style.withForeground(s, Style.indexed(a - 30))
            case 39: s = Style.withForeground(s, Style.colorDefault)
            case 40...47: s = Style.withBackground(s, Style.indexed(a - 40))
            case 49: s = Style.withBackground(s, Style.colorDefault)
            case 53: s |= Style.OVERLINE
            case 55: s &= ~Style.OVERLINE
            case 90...97: s = Style.withForeground(s, Style.indexed(a - 90 + 8))
            case 100...107: s = Style.withBackground(s, Style.indexed(a - 100 + 8))
            case 38, 48, 58:
                let color: Int
                if subCount > 0 {
                    color = colonColor(k + 1, subCount)
                } else {
                    color = semicolonColor(k + 1)
                    end = min(paramCount, k + 1 + semicolonColorLength(k + 1))
                }
                if color >= 0 {
                    if a == 38 {
                        s = Style.withForeground(s, color)
                    } else if a == 48 {
                        s = Style.withBackground(s, color)
                    } // 58: underline colour, parsed and ignored
                }
            default:
                break // 10–20 fonts, 26, 50–52, 54, 59, 60–65 ideograms, 73–75: ignored.
            }
            k = end
        }
        _pen = s
    }

    /** `38:5:n` / `38:2:[cs]:r:g:b` with sub-parameters starting at `k`. */
    private func colonColor(_ k: Int, _ subCount: Int) -> Int {
        let space = params[k]
        if space == 5 && subCount >= 2 {
            let n = params[k + 1]
            return n >= 0 && n <= 255 ? Style.indexed(n) : -1
        }
        if space == 2 {
            let first = subCount >= 5 ? k + 2 : k + 1 // with or without the colour-space id
            if first + 2 < k + subCount { // the group ends at k + subCount - 1
                return TerminalEmulator.rgbOrInvalid(params[first], params[first + 1], params[first + 2])
            }
        }
        return -1
    }

    /** `38;5;n` / `38;2;r;g;b` with the selector at `k`. */
    private func semicolonColor(_ k: Int) -> Int {
        let space = arg(k, -1)
        if space == 5 {
            let n = arg(k + 1, 0)
            return n <= 255 ? Style.indexed(n) : -1
        }
        if space == 2 {
            return TerminalEmulator.rgbOrInvalid(arg(k + 1, 0), arg(k + 2, 0), arg(k + 3, 0))
        }
        return -1
    }

    private func semicolonColorLength(_ k: Int) -> Int {
        switch arg(k, -1) {
        case 5: return 2
        case 2: return 4
        default: return 0
        }
    }

    private static func rgbOrInvalid(_ r: Int, _ g: Int, _ b: Int) -> Int {
        let r = max(0, r)
        let g = max(0, g)
        let b = max(0, b)
        return r <= 255 && g <= 255 && b <= 255 ? Style.rgb(r, g, b) : -1
    }

    /**
     * DCS/APC/PM/SOS are consumed and ignored, except XTGETTCAP (`DCS + q … ST`), which is
     * answered "invalid request" (`DCS 0 + r ST`) so a prober moves on at once instead of
     * waiting for its timeout (as the daemon's jediterm did).
     */
    private func deviceControlString(_ b: UnsafePointer<UInt8>, _ len: Int) {
        if len >= 4 && b[1] == UInt8(ascii: "P") && b[2] == UInt8(ascii: "+") && b[3] == UInt8(ascii: "q") {
            reply(TerminalEmulator.XTGETTCAP_INVALID)
        }
    }

    // =====================================================================================
    // OSC
    // =====================================================================================

    private func osc(_ b: UnsafePointer<UInt8>, _ len: Int) {
        var end = len
        if end > 2 && b[end - 1] == 0x07 {
            end -= 1
        } else if end > 3 && b[end - 1] == UInt8(ascii: "\\") && b[end - 2] == 0x1B {
            end -= 2
        }
        var i = 2
        var ps = 0
        var digits = false
        while i < end && b[i] >= 0x30 && b[i] <= 0x39 {
            ps = min(ps * 10 + Int(b[i] - 0x30), 100_000)
            digits = true
            i += 1
        }
        if !digits || (i < end && b[i] != UInt8(ascii: ";")) {
            return
        }
        if ps <= 2 && i < end {
            let text = String(decoding: UnsafeBufferPointer(start: b + i + 1, count: end - i - 1), as: UTF8.self)
            setTitle(TerminalEmulator.truncateUtf16(text, TerminalEmulator.MAX_TITLE_LENGTH))
        }
        // 4, 7, 8, 10–12, 52, 104, 110–112, 133, …: parsed and ignored here (the session
        // tracks OSC 7 through ModeTracker; nothing is answered).
    }

    /** Java's `substring(0, max)` on a string longer than `max` UTF-16 units. */
    private static func truncateUtf16(_ s: String, _ max: Int) -> String {
        let utf16 = s.utf16
        if utf16.count <= max {
            return s
        }
        return String(decoding: Array(utf16.prefix(max)), as: UTF16.self)
    }

    private func setTitle(_ newTitle: String) {
        // Code point equality, as Java's String.equals (Swift's == is canonical equivalence).
        if !newTitle.unicodeScalars.elementsEqual(_title.unicodeScalars) {
            _title = newTitle
            titleDirty = true
        }
    }

    // =====================================================================================
    // helpers
    // =====================================================================================

    private func reply(_ s: String) {
        reply(Array(s.utf8))
    }

    private func reply(_ bytes: [UInt8]) {
        if replySink != nil && replyScope != .client {
            pendingReplies.append(bytes)
        }
    }

    private static func clamp(_ v: Int, _ lo: Int, _ hi: Int) -> Int {
        return max(lo, min(hi, v))
    }
}
