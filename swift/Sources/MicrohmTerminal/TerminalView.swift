import AppKit
import CoreText
import MicrohmVT

/// Where the view sends program input. `write` is called on the main thread for keys,
/// mouse and paste, and on the feeding thread for the emulator's replies (answers to
/// queries), so an implementation must be thread-safe; `SessionTerminal`'s queues it.
public protocol TerminalViewOutput: AnyObject {
    func write(_ bytes: [UInt8])

    /// The grid changed to `columns` × `rows` (debounced). Main thread.
    func resize(columns: Int, rows: Int)
}

/// A flag set from the feeding thread, cleared on the main thread.
private final class AtomicFlag: @unchecked Sendable {
    private let lock = NSLock()
    private var value = false

    /// Sets the flag; true when it was clear.
    func set() -> Bool {
        lock.lock()
        defer { lock.unlock() }
        if value {
            return false
        }
        value = true
        return true
    }

    func clear() {
        lock.lock()
        value = false
        lock.unlock()
    }
}

/// Weak box so the emulator's listener and reply sink don't retain the view.
private final class WeakListener: TerminalListener, @unchecked Sendable {
    weak var view: TerminalView?
    let flag: AtomicFlag

    init(_ view: TerminalView, _ flag: AtomicFlag) {
        self.view = view
        self.flag = flag
    }

    func contentChanged() {
        if flag.set() {
            DispatchQueue.main.async { [weak self] in
                self?.view?.frameDue()
            }
        }
    }

    func bell(_ count: Int) {
        DispatchQueue.main.async { [weak self] in
            self?.view?.flashBell()
        }
    }

    func titleChanged(_ title: String) {
        DispatchQueue.main.async { [weak self] in
            self?.view?.onTitleChanged?(title)
        }
    }
}

/// An AppKit terminal over a `TerminalEmulator`: draws its cells with Core Text and Core
/// Graphics, turns keyboard, mouse, paste and input-method events into program input, and
/// keeps the local view state — the scrollback offset, the selection, the cursor blink.
/// Nothing here knows about sessions or settings; `SessionTerminal` feeds the emulator from
/// a transport and maps the app's settings onto the setters.
///
/// ## Threading
/// The emulator is fed on a reader thread; it calls `contentChanged()` there, which only
/// queues one frame on the main thread (an atomic flag, so a burst of output is one pending
/// frame). The frame is rate-limited to ~60 fps, held while the program is mid synchronized
/// update (DECSET 2026, capped at 150 ms so a stuck program still paints), and then adjusts
/// the scrollback anchor and the scroller and invalidates what changed (see Damage below).
/// Drawing holds the emulator lock for the duration of one frame. Everything else here is
/// main-thread only. While the view is not showing (a hidden card) frames are skipped
/// entirely — the pending one is left queued, so output costs the main thread nothing — and
/// one catch-up frame with a full redraw runs when it shows again. Frames come from a
/// one-shot main-run-loop timer, not a CVDisplayLink (whose thread crashed the Java app on
/// wake); AppKit then coalesces the invalidation with the display's own refresh.
///
/// ## Damage
/// Each frame remembers, per visible row, the `Line` object it showed and that line's
/// `version()`; the next frame redraws only the rows whose line or version differ (one
/// union rectangle, a row of margin either side for glyphs that overflow their cell) plus
/// the old and new cursor rows. Anything global — the grid size, the scroll position or
/// history growth, reverse video, the alternate screen, the cursor's mode, the selection,
/// focus, the view's size, fonts or colours — makes the frame redraw everything.
///
/// ## Drawing
/// In device pixels: on a 2× display the font is measured at twice its size, so cells can
/// be half a point wide or tall (see `TerminalFonts`). Per row in the dirty rect:
/// background runs (merged per resolved colour), then text — runs of the terminal font's
/// glyphs placed at their cells, with wide characters, combining sequences, fallback-font
/// characters and the tiling characters (`BoxDrawing`) drawn per cell; decorations
/// (underline styles, strikethrough, overline) on top; then the cursor and any
/// input-method composition at the cursor.
public final class TerminalView: NSView, NSTextInputClient, NSMenuItemValidation {

    public static let minColumns = 2
    public static let minRows = 2
    private static let frameInterval: TimeInterval = 0.016
    private static let syncHold: TimeInterval = 0.150
    private static let blinkInterval: TimeInterval = 0.53
    private static let wheelLines = 3

    public let emulator: TerminalEmulator
    private let output: TerminalViewOutput
    public let colors: TerminalColors
    public private(set) var fonts: TerminalFonts
    /// Swallows every wheel event (Codex navigates on wheel gestures).
    public var mouseWheelDisabled = false
    /// macOS: whether Option+letter/digit is Meta or composes (accents, dead keys).
    public var optionAsMeta = true
    /// Whether bare Page Up/Down, Home and End page the scrollback (except in a full-screen
    /// program, which gets them).
    public var pageKeysScrollback = true
    /// The window title (OSC 0/1/2) changed. Main thread.
    public var onTitleChanged: ((String) -> Void)?
    /// The scroll position or history size changed (`scrollPosition`). Main thread.
    public var onScrollChanged: (() -> Void)?
    /// Opens a ⌘-clicked link; replaceable (tests).
    public var linkOpener: (URL) -> Void = { url in
        NSWorkspace.shared.open(url)
    }

    // Frames.
    private let frameQueued = AtomicFlag()
    private var listener: WeakListener!
    private var frameTimer: Timer?
    private var lastFrame: TimeInterval = 0
    private var syncSince: TimeInterval = 0
    public private(set) var frames = 0
    public private(set) var fullFrames = 0

    // Damage tracking: what the last frame asked to be drawn (see the type comment).
    private var paintedKey: FrameKey?
    private var paintedLines: [Line?] = []
    private var paintedVersions: [Int64] = []
    private var paintedCursorRow = -1
    /// Bumped by changes that redraw everything on their own (fonts, colours, scale), so
    /// the next frame also treats its snapshot as stale.
    private var viewStamp = 0
    /// Output arrived while the view was not showing; a catch-up frame is owed.
    private var catchUpPending = false

    // Scrollback: lines back from the live screen (0 = live).
    public private(set) var scrollOffset = 0
    private var lastHistoryAdded: Int64 = 0

    // Size.
    private var resizeTimer: Timer?

    // Selection, in absolute rows (historyLinesAdded + index) and caret columns.
    private enum SelectMode { case char, word, line }

    private var selecting = false
    private var selectionActive = false
    private var selectMode = SelectMode.char
    private var anchorRow: Int64 = 0
    private var anchorColumn = 0
    private var anchorEndRow: Int64 = 0
    private var anchorEndColumn = 0
    private var selStartRow: Int64 = 0
    private var selStartColumn = 0
    private var selEndRow: Int64 = 0
    private var selEndColumn = 0

    // Mouse reporting.
    private var reportedButton = -1
    private var lastMotionColumn = -1
    private var lastMotionRow = -1
    private var wheelRemainder = 0.0
    private var trackingArea: NSTrackingArea?

    // Keyboard and input method.
    private var composedText = ""
    private var focusedState = false

    // Cursor blink and bell.
    private var blinkTimer: Timer?
    private var blinkOn = true
    private var bellUntil: TimeInterval = 0
    private var lastBell: TimeInterval = 0
    public private(set) var ended = false

    // Device pixels per point: 2 on a Retina display. The cell grid, the fonts and all
    // drawing are in device pixels; AppKit coordinates (layout, mouse, the IME caret) are in
    // points and converted at those edges, so cells can be a half point wide on a 2× screen.
    public private(set) var deviceScale: Double = 1
    private var scaleForced = false
    private var fontFamily: String
    private var fontSize: Double

    // Draw scratch, reused across rows.
    private var runGlyphs: [CGGlyph] = []
    private var runPositions: [CGPoint] = []

    public init(columns: Int, rows: Int, maxHistory: Int, output: TerminalViewOutput, palette: [Int],
                background: Int?, light: Bool, fontFamily: String, fontSize: Double) {
        emulator = TerminalEmulator(columns, rows, maxHistory)
        self.output = output
        colors = TerminalColors(palette, light)
        colors.setTheme(background, light)
        self.fontFamily = fontFamily
        self.fontSize = fontSize
        fonts = TerminalFonts(family: fontFamily, size: fontSize, scale: 1)
        super.init(frame: NSRect(x: 0, y: 0, width: 100, height: 100))
        setFrameSize(intrinsicContentSize)
        listener = WeakListener(self, frameQueued)
        emulator.setReplies({ [weak self] reply in
            self?.output.write(reply)
        }, .client)
        emulator.setColorScheme(light ? .light : .dark)
        emulator.setListener(listener)
        wantsLayer = true
        layerContentsRedrawPolicy = .onSetNeedsDisplay
        let center = NotificationCenter.default
        center.addObserver(self, selector: #selector(windowKeyChanged), name: NSWindow.didBecomeKeyNotification,
                           object: nil)
        center.addObserver(self, selector: #selector(windowKeyChanged), name: NSWindow.didResignKeyNotification,
                           object: nil)
        registerForDraggedTypes([.fileURL, .URL, .string])
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("not used")
    }

    deinit {
        NotificationCenter.default.removeObserver(self)
        frameTimer?.invalidate()
        blinkTimer?.invalidate()
        resizeTimer?.invalidate()
    }

    public override var isFlipped: Bool {
        return true
    }

    public override var isOpaque: Bool {
        return true
    }

    public override var acceptsFirstResponder: Bool {
        return true
    }

    public override func acceptsFirstMouse(for event: NSEvent?) -> Bool {
        return true
    }

    // MARK: - Public surface (main thread)

    /// Feeds program output (any thread; the transport's in practice).
    public func feed(_ data: Data) {
        data.withUnsafeBytes { raw in
            emulator.feed(raw.bindMemory(to: UInt8.self))
        }
    }

    public func feed(_ bytes: [UInt8]) {
        emulator.feed(bytes)
    }

    /// The program's output ended: the view stops blinking and draws once more.
    public func markEnded() {
        ended = true
        updateBlinkTimer()
        needsDisplay = true
    }

    /// Recolours the default foreground/background (nil background: the palette's) and
    /// reports light/dark to the program. Explicit colours keep theirs.
    public func setTheme(background: Int?, light: Bool) {
        colors.setTheme(background, light)
        emulator.setColorScheme(light ? .light : .dark)
        viewStamp += 1
        needsDisplay = true
    }

    public func setPalette(_ palette: [Int]) {
        colors.setPalette(palette)
        viewStamp += 1
        needsDisplay = true
    }

    public var defaultBackground: NSColor {
        return NSColor(cgColor: colors.color(colors.defaultBackground)) ?? .black
    }

    /// New font: re-measures the cell and reflows the grid to the view's size.
    public func setTerminalFont(family: String, size: Double) {
        fontFamily = family
        fontSize = size
        fonts = TerminalFonts(family: family, size: size, scale: deviceScale)
        viewStamp += 1
        invalidateIntrinsicContentSize()
        scheduleResize()
        needsDisplay = true
    }

    /// Cell width in device pixels.
    public var cellWidth: Int { fonts.cellWidth }

    /// Cell height in device pixels.
    public var cellHeight: Int { fonts.cellHeight }

    /// Draws at `scale` regardless of the screen (offscreen rendering, tests).
    public func setDeviceScale(_ scale: Double) {
        scaleForced = true
        applyScale(scale)
    }

    public override func viewDidChangeBackingProperties() {
        super.viewDidChangeBackingProperties()
        if !scaleForced, let window = window {
            applyScale(Double(window.backingScaleFactor))
        }
    }

    /// Re-measures the cell for a new scale (the window moved to a screen of another density).
    private func applyScale(_ newScale: Double) {
        if newScale == deviceScale || newScale <= 0 {
            return
        }
        deviceScale = newScale
        fonts = TerminalFonts(family: fontFamily, size: fontSize, scale: newScale)
        viewStamp += 1
        invalidateIntrinsicContentSize()
        scheduleResize()
        needsDisplay = true
    }

    /// Points covering `devicePixels` (rounded up).
    private func pointsCeil(_ devicePixels: Double) -> CGFloat {
        return CGFloat((devicePixels / deviceScale - 1e-9).rounded(.up))
    }

    /// Invalidates a rectangle given in device pixels.
    private func setNeedsDisplayDevice(_ x: Int, _ y: Int, _ width: Int, _ height: Int) {
        let left = (Double(x) / deviceScale).rounded(.down)
        let top = (Double(y) / deviceScale).rounded(.down)
        let right = (Double(x + width) / deviceScale).rounded(.up)
        let bottom = (Double(y + height) / deviceScale).rounded(.up)
        setNeedsDisplay(NSRect(x: left, y: top, width: right - left + 1, height: bottom - top + 1))
    }

    public func pageUp() {
        setScrollOffset(scrollOffset + emulator.rows())
    }

    public func pageDown() {
        setScrollOffset(scrollOffset - emulator.rows())
    }

    public var alternateScreen: Bool {
        return locked { emulator.alternateScreen() }
    }

    public func scrollToTop() {
        setScrollOffset(Int.max)
    }

    public func scrollToBottom() {
        setScrollOffset(0)
    }

    /// Lines scrolled back, lines of history, and rows: for a scroller.
    public var scrollPosition: (offset: Int, history: Int, rows: Int) {
        return locked { (min(scrollOffset, emulator.historySize()), emulator.historySize(), emulator.rows()) }
    }

    @inline(__always)
    private func locked<T>(_ body: () -> T) -> T {
        let lock = emulator.lock()
        lock.lock()
        defer { lock.unlock() }
        return body()
    }

    private var viewShowing: Bool {
        return window != nil && !isHiddenOrHasHiddenAncestor
    }

    public override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        if let window = window, !scaleForced {
            applyScale(Double(window.backingScaleFactor))
        }
        paintedKey = nil // (re)attached: whatever was drawn before is gone
        showingChanged()
        updateFocus()
    }

    public override func viewDidHide() {
        super.viewDidHide()
        showingChanged()
    }

    public override func viewDidUnhide() {
        super.viewDidUnhide()
        showingChanged()
    }

    /// Shown or hidden (a card switch, a window opened or closed): runs the catch-up frame
    /// owed for output that arrived while hidden, and starts or stops the cursor blink.
    private func showingChanged() {
        if viewShowing && catchUpPending {
            catchUpPending = false
            paintedKey = nil // the catch-up frame redraws everything
            frameDue()
        }
        updateBlinkTimer()
    }

    /// Scrolls the view to `offset` lines back from the live screen (clamped).
    public func setScrollOffset(_ offset: Int) {
        let history = locked { emulator.historySize() }
        let clamped = max(0, min(offset, history))
        if clamped != scrollOffset {
            scrollOffset = clamped
            needsDisplay = true
        }
        onScrollChanged?()
    }

    // MARK: - Frames (main thread)

    fileprivate func frameDue() {
        if !viewShowing {
            // Hidden: leave the frame queued (so further output doesn't post more) and catch
            // up in one frame when the view shows again.
            catchUpPending = true
            frameTimer?.invalidate()
            frameTimer = nil
            return
        }
        let now = ProcessInfo.processInfo.systemUptime
        var wait = lastFrame + TerminalView.frameInterval - now
        if locked({ emulator.synchronizedOutput() }) {
            if syncSince == 0 {
                syncSince = now
            }
            if now - syncSince < TerminalView.syncHold {
                wait = max(wait, 0.008)
            }
        } else {
            syncSince = 0
        }
        if wait > 0 {
            frameTimer?.invalidate()
            let timer = Timer(timeInterval: max(0.001, wait), repeats: false) { [weak self] _ in
                self?.frameTimer = nil
                self?.frameDue()
            }
            RunLoop.main.add(timer, forMode: .common)
            frameTimer = timer
            return
        }
        frameQueued.clear() // output arriving from here on queues the next frame
        lastFrame = now
        syncSince = 0
        frames += 1
        let damage: (Int, Int)? = locked {
            let history = emulator.historySize()
            let added = emulator.historyLinesAdded()
            let grown = Int(added - lastHistoryAdded)
            lastHistoryAdded = added
            if scrollOffset > 0 {
                // keep a scrolled-back view on the same lines while output arrives
                scrollOffset = min(history, scrollOffset + grown)
            }
            return collectDamage(history, added)
        }
        onScrollChanged?()
        blinkOn = true
        if let timer = blinkTimer {
            timer.fireDate = Date(timeIntervalSinceNow: TerminalView.blinkInterval)
        }
        updateBlinkTimer()
        if let (first, last) = damage {
            if first <= last {
                let ch = fonts.cellHeight
                setNeedsDisplayDevice(0, first * ch, Int(Double(bounds.width) * deviceScale), (last - first + 1) * ch)
            }
        } else {
            fullFrames += 1
            needsDisplay = true
        }
    }

    /// Everything outside the rows' own content that changes what a frame draws.
    private struct FrameKey: Equatable {
        var rows, columns, offset, history: Int
        var added: Int64
        var reverse, alternate, cursorVisible: Bool
        var cursorShape: Int
        var cursorBlink: Bool
        var width, height: CGFloat
        var fonts: ObjectIdentifier
        var scale: Double
        var viewStamp: Int
        var focused, ended, selectionActive: Bool
        var selStartRow: Int64
        var selStartColumn: Int
        var selEndRow: Int64
        var selEndColumn: Int
        var composed: String
    }

    /// Compares the visible rows with what the last frame drew and records them as drawn.
    /// Returns nil when everything must be redrawn, else the first and last view rows to
    /// redraw (first > last: none). Lock held.
    private func collectDamage(_ history: Int, _ added: Int64) -> (Int, Int)? {
        let rows = emulator.rows()
        let offset = min(scrollOffset, history)
        let key = FrameKey(rows: rows, columns: emulator.columns(), offset: offset, history: history, added: added,
                           reverse: emulator.reverseVideo(), alternate: emulator.alternateScreen(),
                           cursorVisible: emulator.cursorVisible(), cursorShape: emulator.cursorShape(),
                           cursorBlink: emulator.cursorBlink(), width: bounds.width, height: bounds.height,
                           fonts: ObjectIdentifier(fonts), scale: deviceScale, viewStamp: viewStamp,
                           focused: focusedState, ended: ended, selectionActive: selectionActive,
                           selStartRow: selStartRow, selStartColumn: selStartColumn, selEndRow: selEndRow,
                           selEndColumn: selEndColumn, composed: composedText)
        let full = key != paintedKey || paintedLines.count != rows
        paintedKey = key
        if full {
            paintedLines = [Line?](repeating: nil, count: rows)
            paintedVersions = [Int64](repeating: 0, count: rows)
        }
        var first = Int.max
        var last = -1
        for r in 0..<rows {
            let line = emulator.line(r - offset)
            let version = line.version()
            if paintedLines[r] !== line || paintedVersions[r] != version {
                paintedLines[r] = line
                paintedVersions[r] = version
                first = min(first, r)
                last = r
            }
        }
        let cursorRow = emulator.cursorRow() + offset
        for r in [paintedCursorRow, cursorRow] where r >= 0 && r < rows {
            first = min(first, r)
            last = max(last, r)
        }
        paintedCursorRow = cursorRow
        if full {
            return nil
        }
        // a row of margin either side: a glyph may overflow its cell into a neighbour
        return (max(0, first - 1), min(rows - 1, last + 1))
    }

    fileprivate func flashBell() {
        let now = ProcessInfo.processInfo.systemUptime
        if now - lastBell < 0.2 {
            return // a bell storm is one flash
        }
        lastBell = now
        bellUntil = now + 0.12
        needsDisplay = true
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.13) { [weak self] in
            self?.needsDisplay = true
        }
    }

    private func updateBlinkTimer() {
        let blinking = locked { cursorBlinks() }
        let run = blinking && focusedState && !ended && viewShowing
        if run && blinkTimer == nil {
            blinkOn = true
            let timer = Timer(timeInterval: TerminalView.blinkInterval, repeats: true) { [weak self] _ in
                guard let self = self else {
                    return
                }
                self.blinkOn.toggle()
                self.invalidateCursor()
            }
            RunLoop.main.add(timer, forMode: .common)
            blinkTimer = timer
        } else if !run, let timer = blinkTimer {
            timer.invalidate()
            blinkTimer = nil
            blinkOn = true
        }
    }

    /// Lock held.
    private func cursorBlinks() -> Bool {
        let shape = emulator.cursorShape()
        return shape == 0 ? emulator.cursorBlink() : shape & 1 == 1
    }

    private func invalidateCursor() {
        let (row, column) = locked { (emulator.cursorRow() + min(scrollOffset, emulator.historySize()),
                                      emulator.cursorColumn()) }
        let cw = fonts.cellWidth
        let ch = fonts.cellHeight
        setNeedsDisplayDevice(column * cw - 1, row * ch, cw * 2 + 2, ch)
    }

    // MARK: - Size

    /// Columns and rows that fit `width` × `height` device pixels, at least 2 × 2.
    public static func gridSize(_ width: Int, _ height: Int, _ cellWidth: Int, _ cellHeight: Int) -> (Int, Int) {
        return (max(minColumns, width / max(1, cellWidth)), max(minRows, height / max(1, cellHeight)))
    }

    public override var intrinsicContentSize: NSSize {
        let (columns, rows) = locked { (emulator.columns(), emulator.rows()) }
        return NSSize(width: pointsCeil(Double(columns * fonts.cellWidth)),
                      height: pointsCeil(Double(rows * fonts.cellHeight)))
    }

    public override func setFrameSize(_ newSize: NSSize) {
        super.setFrameSize(newSize)
        scheduleResize()
    }

    /// Debounces a burst of layout changes (a window drag) into one resize.
    private func scheduleResize() {
        resizeTimer?.invalidate()
        let timer = Timer(timeInterval: 0.04, repeats: false) { [weak self] _ in
            self?.resizeTimer = nil
            self?.applyResize()
        }
        RunLoop.main.add(timer, forMode: .common)
        resizeTimer = timer
    }

    /// Fits the grid to the current size now (the debounce timer; tests). Before the first
    /// layout (no size yet) the attach size stays.
    public func applyResize() {
        resizeTimer?.invalidate()
        resizeTimer = nil
        let w = Double(bounds.width)
        let h = Double(bounds.height)
        if w <= 0 || h <= 0 {
            return
        }
        // whole device pixels inside the points AppKit gave us
        let (columns, rows) = TerminalView.gridSize(Int((w * deviceScale + 1e-9).rounded(.down)),
                                                    Int((h * deviceScale + 1e-9).rounded(.down)),
                                                    fonts.cellWidth, fonts.cellHeight)
        if columns == emulator.columns() && rows == emulator.rows() {
            return
        }
        emulator.resize(columns, rows)
        output.resize(columns: columns, rows: rows)
        setScrollOffset(scrollOffset)
        needsDisplay = true
    }

    // MARK: - Drawing

    public override func draw(_ dirtyRect: NSRect) {
        guard let g = NSGraphicsContext.current?.cgContext else {
            return
        }
        if !scaleForced, let window = window {
            applyScale(Double(window.backingScaleFactor))
        }
        g.saveGState()
        let s = CGFloat(deviceScale)
        g.scaleBy(x: 1 / s, y: 1 / s) // draw in device pixels
        g.setAllowsFontSmoothing(true)
        g.setAllowsFontSubpixelPositioning(true)
        g.setShouldSubpixelPositionFonts(true)
        g.setAllowsAntialiasing(true)
        g.interpolationQuality = .high
        let visible = dirtyRect.intersection(bounds)
        if visible.isEmpty || visible.isNull {
            g.restoreGState()
            return
        }
        let clip = CGRect(x: visible.minX * s, y: visible.minY * s, width: visible.width * s,
                          height: visible.height * s).integral
        drawDevice(g, clip)
        g.restoreGState()
    }

    /// `draw` in device-pixel coordinates (y down).
    private func drawDevice(_ g: CGContext, _ clip: CGRect) {
        let cw = fonts.cellWidth
        let ch = fonts.cellHeight
        let width = Int((Double(bounds.width) * deviceScale).rounded())
        let lock = emulator.lock()
        lock.lock()
        let reverse = emulator.reverseVideo()
        let defaultBg = reverse ? colors.defaultForeground : colors.defaultBackground
        g.setFillColor(colors.color(defaultBg))
        g.fill(clip)
        let rows = emulator.rows()
        let history = emulator.historySize()
        let offset = min(scrollOffset, history)
        let added = emulator.historyLinesAdded()
        // one row beyond the clip either way, so a neighbour's glyph overflowing into the
        // clip is redrawn (the clip keeps everything else untouched)
        let firstRow = max(0, Int((clip.minY / CGFloat(ch)).rounded(.down)) - 1)
        let lastRow = min(rows - 1, Int(((clip.maxY - 1) / CGFloat(ch)).rounded(.down)) + 1)
        let columns = min(emulator.columns(), (width + cw - 1) / cw)
        g.saveGState()
        g.clip(to: clip)
        if firstRow <= lastRow {
            for r in firstRow...lastRow {
                let index = r - offset
                let line = emulator.line(index)
                drawRow(g, line, r * ch, min(columns, line.columns()), added + Int64(index), reverse, defaultBg)
            }
        }
        let cursorViewRow = emulator.cursorRow() + offset
        if cursorViewRow >= 0 && cursorViewRow < rows {
            drawCursor(g, cursorViewRow * ch, emulator.line(emulator.cursorRow()), emulator.cursorColumn(), reverse)
        }
        g.restoreGState()
        lock.unlock()
        if ProcessInfo.processInfo.systemUptime < bellUntil {
            g.setFillColor(TerminalColors.cgColor(colors.defaultForeground, alpha: 40.0 / 255))
            g.fill(clip)
        }
    }

    private func selected(_ absRow: Int64, _ column: Int) -> Bool {
        if !selectionActive || absRow < selStartRow || absRow > selEndRow {
            return false
        }
        if absRow == selStartRow && column < selStartColumn {
            return false
        }
        return absRow != selEndRow || column < selEndColumn
    }

    /// Effective background rgb of a cell (inverse, reverse video and selection applied).
    private func cellBackground(_ style: Int64, _ reverse: Bool, _ selected: Bool) -> Int {
        if selected {
            return colors.selection()
        }
        let inverse = Style.inverse(style) != reverse
        return inverse ? colors.rgb(Style.foreground(style), true) : colors.rgb(Style.background(style), false)
    }

    private func cellForeground(_ style: Int64, _ reverse: Bool, _ background: Int) -> Int {
        let inverse = Style.inverse(style) != reverse
        var fg = inverse ? colors.rgb(Style.background(style), false) : colors.rgb(Style.foreground(style), true)
        if Style.dim(style) {
            fg = TerminalColors.blend(fg, background, 0.5)
        }
        return fg
    }

    private static func fontStyle(_ style: Int64) -> Int {
        return (Style.bold(style) ? TerminalFonts.bold : 0) | (Style.italic(style) ? TerminalFonts.italic : 0)
    }

    /// Underline style, strikethrough and overline packed for run comparison; 0 = none.
    private static func decorations(_ style: Int64) -> Int {
        return Style.underline(style) | (Style.strikethrough(style) ? 8 : 0) | (Style.overline(style) ? 16 : 0)
    }

    private func drawRow(_ g: CGContext, _ line: Line, _ top: Int, _ columns: Int, _ absRow: Int64,
                         _ reverse: Bool, _ defaultBg: Int) {
        let cw = fonts.cellWidth
        let ch = fonts.cellHeight
        // backgrounds, merged into runs of one colour
        var runStart = 0
        var runColor = defaultBg
        for x in 0...columns {
            let bg = x < columns ? cellBackground(line.style(x), reverse, selected(absRow, x)) : -1
            if bg != runColor {
                if runColor != defaultBg && x > runStart {
                    g.setFillColor(colors.color(runColor))
                    g.fill(CGRect(x: runStart * cw, y: top, width: (x - runStart) * cw, height: ch))
                }
                runStart = x
                runColor = bg
            }
        }
        // text
        let baseline = top + fonts.baseline
        var runX = 0
        var runFg = 0
        var runFont = 0
        var runDecor = 0
        var runLength = 0
        runGlyphs.removeAll(keepingCapacity: true)
        runPositions.removeAll(keepingCapacity: true)
        func flush() {
            if runLength > 0 {
                flushRun(g, runX, runLength, runFg, runFont, runDecor, top, baseline)
                runLength = 0
            }
        }
        for x in 0..<columns {
            if line.isWideTail(x) {
                continue
            }
            let style = line.style(x)
            let cp = line.codePoint(x)
            let blank = line.isEmpty(x) || cp == 0x20 || cp == 0
            let decor = TerminalView.decorations(style)
            if blank && decor == 0 {
                flush()
                continue
            }
            let sel = selected(absRow, x)
            let bg = cellBackground(style, reverse, sel)
            let fg = cellForeground(style, reverse, bg)
            let invisible = Style.invisible(style)
            let fontStyle = TerminalView.fontStyle(style)
            let width = line.width(x)
            let glyph: CGGlyph? = width == 1 && !line.hasExtras(x) && !BoxDrawing.handles(cp)
                ? fonts.glyph(blank ? 0x20 : cp, fontStyle) : nil
            if let glyph = glyph {
                if runLength > 0 && (fg != runFg || fontStyle != runFont || decor != runDecor || runX + runLength != x) {
                    flush()
                }
                if runLength == 0 {
                    runX = x
                    runFg = fg
                    runFont = fontStyle
                    runDecor = decor
                }
                runLength += 1
                if !invisible && !blank {
                    let advance = fonts.advance(glyph, fontStyle)
                    runGlyphs.append(glyph)
                    runPositions.append(CGPoint(x: Double(x * cw) + (Double(cw) - advance) / 2, y: 0))
                }
                continue
            }
            flush()
            let cellX = x * cw
            let cellW = max(1, width) * cw
            if !invisible && !blank {
                let color = colors.color(fg)
                if !BoxDrawing.draw(g, cp, cellX, top, cw, ch, color) {
                    drawGlyph(g, line, x, cp, fontStyle, color, cellX, cellW, baseline)
                }
            }
            if decor != 0 {
                drawDecorations(g, decor, colors.color(fg), cellX, cellW, top)
            }
        }
        flush()
    }

    private func flushRun(_ g: CGContext, _ x: Int, _ length: Int, _ fg: Int, _ fontStyle: Int, _ decor: Int,
                          _ top: Int, _ baseline: Int) {
        let color = colors.color(fg)
        if !runGlyphs.isEmpty {
            g.saveGState()
            g.translateBy(x: 0, y: CGFloat(baseline))
            g.scaleBy(x: 1, y: -1) // glyphs draw y-up
            g.setFillColor(color)
            g.textMatrix = .identity
            runGlyphs.withUnsafeBufferPointer { glyphs in
                runPositions.withUnsafeBufferPointer { positions in
                    CTFontDrawGlyphs(fonts.font(fontStyle), glyphs.baseAddress!, positions.baseAddress!,
                                     glyphs.count, g)
                }
            }
            g.restoreGState()
            runGlyphs.removeAll(keepingCapacity: true)
            runPositions.removeAll(keepingCapacity: true)
        }
        if decor != 0 {
            let cw = fonts.cellWidth
            drawDecorations(g, decor, color, x * cw, length * cw, top)
        }
    }

    /// A cell the terminal font cannot draw on its own: a combining sequence, an emoji, a
    /// wide character, a fallback-font character. Centred in its cells, squeezed when wider.
    private func drawGlyph(_ g: CGContext, _ line: Line, _ x: Int, _ cp: Int, _ fontStyle: Int, _ color: CGColor,
                           _ cellX: Int, _ cellW: Int, _ baseline: Int) {
        let ctLine = fonts.line(line.text(x), fontStyle)
        let advance = CTLineGetTypographicBounds(ctLine, nil, nil, nil)
        if advance <= 0 {
            return
        }
        g.saveGState()
        g.setFillColor(color)
        g.textMatrix = .identity
        if BoxDrawing.tiles(cp) {
            // a tile-designed glyph from a fallback font: its line box and advance scaled to
            // the cell, so it touches the cell's edges as its font meant
            var ascent: CGFloat = 0
            var descent: CGFloat = 0
            _ = CTLineGetTypographicBounds(ctLine, &ascent, &descent, nil)
            let lineHeight = Double(ascent + descent)
            if lineHeight > 0 {
                let top = Double(baseline - fonts.baseline)
                g.translateBy(x: CGFloat(cellX), y: CGFloat(top))
                g.scaleBy(x: CGFloat(Double(cellW) / advance), y: CGFloat(Double(fonts.cellHeight) / lineHeight))
                g.translateBy(x: 0, y: ascent)
                g.scaleBy(x: 1, y: -1)
                g.textPosition = .zero
                CTLineDraw(ctLine, g)
            }
            g.restoreGState()
            return
        }
        let w = Double(cellW)
        g.translateBy(x: CGFloat(cellX), y: CGFloat(baseline))
        if advance > w + 1 {
            // a glyph wider than its cells (a fallback font's metrics): squeeze, don't overlap
            g.scaleBy(x: CGFloat(w / advance), y: -1)
        } else {
            g.translateBy(x: CGFloat(max(0, (w - advance) / 2)), y: 0)
            g.scaleBy(x: 1, y: -1)
        }
        g.textPosition = .zero
        CTLineDraw(ctLine, g)
        g.restoreGState()
    }

    private func drawDecorations(_ g: CGContext, _ decor: Int, _ color: CGColor, _ x: Int, _ width: Int, _ top: Int) {
        g.saveGState()
        defer { g.restoreGState() }
        g.setFillColor(color)
        g.setStrokeColor(color)
        let ch = fonts.cellHeight
        let base = fonts.baseline
        let t = max(1, Int(fonts.lineThickness.rounded()))
        let uy = min(top + ch - t, top + base + max(1, (ch - base) / 3))
        func rect(_ x: Int, _ y: Int, _ w: Int, _ h: Int) {
            g.fill(CGRect(x: x, y: y, width: w, height: h))
        }
        switch decor & 7 {
        case Style.underlineSingle:
            rect(x, uy, width, t)
        case Style.underlineDouble:
            let y2 = min(top + ch - t, uy + 2 * t)
            let y1 = max(top, y2 - 2 * t)
            rect(x, y1, width, t)
            rect(x, y2, width, t)
        case Style.underlineCurly:
            let amplitude = Double(max(1, t))
            let mid = min(Double(top + ch) - amplitude - Double(t), Double(uy))
            let period = max(4, Double(fonts.cellWidth) / 2)
            let wave = CGMutablePath()
            wave.move(to: CGPoint(x: Double(x), y: mid))
            var px = Double(x)
            while px < Double(x + width) {
                wave.addQuadCurve(to: CGPoint(x: px + period / 2, y: mid),
                                  control: CGPoint(x: px + period / 4, y: mid - amplitude))
                wave.addQuadCurve(to: CGPoint(x: px + period, y: mid),
                                  control: CGPoint(x: px + 3 * period / 4, y: mid + amplitude))
                px += period
            }
            g.clip(to: CGRect(x: x, y: top, width: width, height: ch))
            g.setLineWidth(CGFloat(t))
            g.addPath(wave)
            g.strokePath()
        case Style.underlineDotted:
            var px = x
            while px < x + width {
                rect(px, uy, t, t)
                px += 2 * t
            }
        case Style.underlineDashed:
            let dash = max(2, fonts.cellWidth / 2)
            var px = x
            while px < x + width {
                rect(px, uy, min(dash, x + width - px), t)
                px += dash * 2
            }
        default:
            break
        }
        if decor & 8 != 0 {
            rect(x, top + base - BoxDrawing.jround(Double(base) * 0.3), width, t)
        }
        if decor & 16 != 0 {
            rect(x, top, width, t)
        }
    }

    /// Lock held.
    private func drawCursor(_ g: CGContext, _ top: Int, _ line: Line, _ cursorColumn: Int, _ reverse: Bool) {
        var column = cursorColumn
        if ended || !emulator.cursorVisible() || column >= line.columns() {
            return
        }
        if column > 0 && line.isWideTail(column) {
            column -= 1
        }
        let focused = focusedState
        if focused && cursorBlinks() && !blinkOn && composedText.isEmpty {
            return
        }
        let cw = fonts.cellWidth
        let ch = fonts.cellHeight
        let x = column * cw
        let width = max(1, line.width(column)) * cw
        let style = line.style(column)
        let bg = cellBackground(style, reverse, false)
        let fg = cellForeground(style, reverse, bg)
        if !composedText.isEmpty {
            drawComposition(g, x, top, fg, bg)
            return
        }
        let cursorColor = colors.color(fg == bg ? colors.defaultForeground : fg)
        g.setFillColor(cursorColor)
        g.setStrokeColor(cursorColor)
        let shape = emulator.cursorShape()
        if !focused {
            let lw = max(1, deviceScale.rounded())
            g.setLineWidth(CGFloat(lw))
            g.stroke(CGRect(x: x, y: top, width: width, height: ch).insetBy(dx: CGFloat(lw / 2), dy: CGFloat(lw / 2)))
            return
        }
        if shape == 3 || shape == 4 {
            let t = max(2, BoxDrawing.jround(Double(ch) / 10))
            g.fill(CGRect(x: x, y: top + ch - t, width: width, height: t))
        } else if shape == 5 || shape == 6 {
            g.fill(CGRect(x: x, y: top, width: max(2, BoxDrawing.jround(Double(cw) / 6)), height: ch))
        } else {
            g.fill(CGRect(x: x, y: top, width: width, height: ch))
            let cp = line.codePoint(column)
            if cp != 0 && cp != 0x20 && !Style.invisible(style) {
                g.saveGState()
                g.clip(to: CGRect(x: x, y: top, width: width, height: ch))
                let glyphColor = colors.color(bg)
                let fontStyle = TerminalView.fontStyle(style)
                if !BoxDrawing.draw(g, cp, x, top, cw, ch, glyphColor) {
                    drawGlyph(g, line, column, cp, fontStyle, glyphColor, x, width, top + fonts.baseline)
                }
                g.restoreGState()
            }
        }
    }

    private func drawComposition(_ g: CGContext, _ x: Int, _ top: Int, _ fg: Int, _ bg: Int) {
        let ctLine = fonts.line(composedText, TerminalFonts.plain)
        let width = Int(CTLineGetTypographicBounds(ctLine, nil, nil, nil).rounded(.up))
        g.setFillColor(colors.color(bg))
        g.fill(CGRect(x: x, y: top, width: width, height: fonts.cellHeight))
        g.saveGState()
        g.setFillColor(colors.color(fg))
        g.textMatrix = .identity
        g.translateBy(x: CGFloat(x), y: CGFloat(top + fonts.baseline))
        g.scaleBy(x: 1, y: -1)
        g.textPosition = .zero
        CTLineDraw(ctLine, g)
        g.restoreGState()
        let t = max(1, Int(deviceScale.rounded()))
        g.setFillColor(colors.color(fg))
        g.fill(CGRect(x: x, y: top + fonts.cellHeight - t, width: width, height: t))
    }

    // MARK: - Keyboard

    private func keyModes() -> KeyEncoder.Modes {
        return locked {
            KeyEncoder.Modes(emulator.applicationCursorKeys(), emulator.applicationKeypad(),
                             emulator.newLineMode(), true, optionAsMeta)
        }
    }

    /// The modifiers that count for a chord (not Caps Lock, the Fn and keypad flags).
    private static func chordFlags(_ event: NSEvent) -> NSEvent.ModifierFlags {
        return event.modifierFlags.intersection([.shift, .control, .option, .command])
    }

    public override func keyDown(with event: NSEvent) {
        // an input method mid-composition (marked text) owns every key until it commits
        if hasMarkedText() {
            interpretKeyEvents([event])
            return
        }
        let (keyCode, location) = KeyEncoder.key(for: event)
        if pageKey(keyCode, event) {
            return
        }
        let modifiers = KeyEncoder.Modifiers(event.modifierFlags)
        if let bytes = KeyEncoder.pressed(keyCode, location: location, keyChar: KeyEncoder.keyChar(for: event),
                                          modifiers: modifiers, modes: keyModes()) {
            // An Option+dead-key chord sent as Meta never reaches the input method, so
            // unlike Java's AWT no accent composition is left open behind it.
            typeInput(bytes)
            return
        }
        if modifiers.contains(.meta) {
            super.keyDown(with: event) // the window's shortcuts
            return
        }
        interpretKeyEvents([event]) // → insertText / setMarkedText / doCommand
    }

    /// Bare Page Up/Down, Home and End page the local scrollback, except in a full-screen
    /// program (the alternate screen has no scrollback to page, and vim, less and the like
    /// read those keys themselves).
    private func pageKey(_ keyCode: Int, _ event: NSEvent) -> Bool {
        guard pageKeysScrollback, TerminalView.chordFlags(event).isEmpty, !alternateScreen else {
            return false
        }
        switch keyCode {
        case VK.pageUp: pageUp()
        case VK.pageDown: pageDown()
        case VK.home: scrollToTop()
        case VK.end: scrollToBottom()
        default: return false
        }
        return true
    }

    /// Copy, paste and select-all: Cmd+C/V/A, never sent to the program (also reachable
    /// through the responder chain's `copy:`/`paste:`/`selectAll:` from an Edit menu).
    public override func performKeyEquivalent(with event: NSEvent) -> Bool {
        guard window?.firstResponder === self, TerminalView.chordFlags(event) == .command else {
            return super.performKeyEquivalent(with: event)
        }
        switch event.charactersIgnoringModifiers?.lowercased() {
        case "c":
            copySelection()
        case "v":
            paste()
        case "a":
            selectAll()
        default:
            return super.performKeyEquivalent(with: event)
        }
        return true
    }

    /// Keyboard input: back to the live screen, selection dropped, then sent.
    private func typeInput(_ bytes: [UInt8]) {
        clearSelection()
        scrollToBottom()
        blinkOn = true
        output.write(bytes)
    }

    // MARK: - NSTextInputClient

    public func insertText(_ string: Any, replacementRange: NSRange) {
        let text = (string as? NSAttributedString)?.string ?? (string as? String) ?? ""
        let hadMarked = !composedText.isEmpty
        composedText = ""
        if hadMarked {
            invalidateCursor()
        }
        if text.isEmpty {
            return
        }
        let scalars = Array(text.unicodeScalars)
        if scalars.count == 1 {
            let flags = NSApp?.currentEvent?.modifierFlags ?? []
            var modifiers = KeyEncoder.Modifiers(flags)
            modifiers.remove(.meta)
            if let bytes = KeyEncoder.typed(scalars[0], modifiers: modifiers) {
                typeInput(bytes)
            }
            return
        }
        typeInput(Array(text.utf8))
    }

    public override func doCommand(by selector: Selector) {
        // keys the encoder did not take and that type nothing: ignore (no beep)
    }

    public func setMarkedText(_ string: Any, selectedRange: NSRange, replacementRange: NSRange) {
        composedText = (string as? NSAttributedString)?.string ?? (string as? String) ?? ""
        invalidateCursor()
        needsDisplay = true
    }

    public func unmarkText() {
        if !composedText.isEmpty {
            let text = composedText
            composedText = ""
            typeInput(Array(text.utf8))
            needsDisplay = true
        }
    }

    public func selectedRange() -> NSRange {
        return NSRange(location: (composedText as NSString).length, length: 0)
    }

    public func markedRange() -> NSRange {
        return composedText.isEmpty ? NSRange(location: NSNotFound, length: 0)
            : NSRange(location: 0, length: (composedText as NSString).length)
    }

    public func hasMarkedText() -> Bool {
        return !composedText.isEmpty
    }

    public func attributedSubstring(forProposedRange range: NSRange, actualRange: NSRangePointer?) -> NSAttributedString? {
        return nil
    }

    public func validAttributesForMarkedText() -> [NSAttributedString.Key] {
        return []
    }

    /// The cursor cell on screen: where the input method puts its candidate window.
    public func firstRect(forCharacterRange range: NSRange, actualRange: NSRangePointer?) -> NSRect {
        let (row, column) = locked { (emulator.cursorRow() + min(scrollOffset, emulator.historySize()),
                                      emulator.cursorColumn()) }
        let rect = NSRect(x: Double(column * fonts.cellWidth) / deviceScale,
                          y: Double(row * fonts.cellHeight) / deviceScale,
                          width: Double(fonts.cellWidth) / deviceScale, height: Double(fonts.cellHeight) / deviceScale)
        guard let window = window else {
            return rect
        }
        return window.convertToScreen(convert(rect, to: nil))
    }

    public func characterIndex(for point: NSPoint) -> Int {
        return NSNotFound
    }

    // MARK: - Clipboard

    @objc public func paste(_ sender: Any?) {
        paste()
    }

    @objc public func copy(_ sender: Any?) {
        copySelection()
    }

    @objc public override func selectAll(_ sender: Any?) {
        selectAll()
    }

    public func validateMenuItem(_ menuItem: NSMenuItem) -> Bool {
        if menuItem.action == #selector(copy(_:)) {
            return hasSelection
        }
        if menuItem.action == #selector(pageUpAction(_:)) {
            return scrollOffset < locked { emulator.historySize() }
        }
        if menuItem.action == #selector(pageDownAction(_:)) {
            return scrollOffset > 0
        }
        return true
    }

    public func paste() {
        if let text = NSPasteboard.general.string(forType: .string), !text.isEmpty {
            pasteText(text)
        }
    }

    public func pasteText(_ text: String) {
        let bracketed = locked { emulator.bracketedPaste() }
        typeInput(PasteEncoder.encode(text, bracketed: bracketed))
    }

    // MARK: - Drag and drop

    /// Files dropped on the terminal type their quoted paths; dropped text or a URL is
    /// pasted. Either way it goes through `pasteText`, so nothing dropped acts as keys.
    public override func draggingEntered(_ sender: NSDraggingInfo) -> NSDragOperation {
        droppedText(sender.draggingPasteboard) == nil ? [] : .copy
    }

    public override func draggingUpdated(_ sender: NSDraggingInfo) -> NSDragOperation {
        droppedText(sender.draggingPasteboard) == nil ? [] : .copy
    }

    public override func performDragOperation(_ sender: NSDraggingInfo) -> Bool {
        guard let text = droppedText(sender.draggingPasteboard) else { return false }
        window?.makeFirstResponder(self)
        pasteText(text)
        return true
    }

    private func droppedText(_ pasteboard: NSPasteboard) -> String? {
        if let urls = pasteboard.readObjects(forClasses: [NSURL.self],
                                             options: [.urlReadingFileURLsOnly: true]) as? [URL], !urls.isEmpty {
            return PasteEncoder.droppedPaths(urls.map(\.path))
        }
        if let urls = pasteboard.readObjects(forClasses: [NSURL.self], options: nil) as? [URL], !urls.isEmpty {
            return urls.map(\.absoluteString).joined(separator: " ")
        }
        if let text = pasteboard.string(forType: .string), !text.isEmpty {
            return text
        }
        return nil
    }

    public func copySelection() {
        if let text = selectedText(), !text.isEmpty {
            NSPasteboard.general.clearContents()
            NSPasteboard.general.setString(text, forType: .string)
        }
    }

    /// The selected text, or nil without a selection.
    public func selectedText() -> String? {
        if !selectionActive {
            return nil
        }
        return locked {
            let added = emulator.historyLinesAdded()
            let first = added - Int64(emulator.historySize())
            let startRow = max(selStartRow, first)
            let startColumn = startRow == selStartRow ? selStartColumn : 0
            return SelectionText.extract(emulator, Int(startRow - added), startColumn, Int(selEndRow - added),
                                         selEndColumn)
        }
    }

    public func selectAll() {
        locked {
            let added = emulator.historyLinesAdded()
            selStartRow = added - Int64(emulator.historySize())
            selStartColumn = 0
            selEndRow = added + Int64(emulator.rows()) - 1
            selEndColumn = emulator.columns()
        }
        selectionActive = true
        needsDisplay = true
    }

    public func clearSelection() {
        if selectionActive || selecting {
            selectionActive = false
            selecting = false
            needsDisplay = true
        }
    }

    public var hasSelection: Bool {
        return selectionActive
    }

    // MARK: - Context menu

    /// Copy, Paste, Select All, then Page Up / Page Down through the scrollback. Built fresh
    /// each time so Copy is enabled only with a selection.
    public func contextMenu() -> NSMenu {
        let menu = NSMenu(title: "Terminal")
        menu.autoenablesItems = false
        let copy = NSMenuItem(title: "Copy", action: #selector(copy(_:)), keyEquivalent: "c")
        copy.isEnabled = hasSelection
        let paste = NSMenuItem(title: "Paste", action: #selector(paste(_:)), keyEquivalent: "v")
        let all = NSMenuItem(title: "Select All", action: #selector(selectAll(_:)), keyEquivalent: "a")
        let history = locked { emulator.historySize() }
        let up = NSMenuItem(title: "Page Up", action: #selector(pageUpAction(_:)), keyEquivalent: "")
        up.isEnabled = scrollOffset < history
        let down = NSMenuItem(title: "Page Down", action: #selector(pageDownAction(_:)), keyEquivalent: "")
        down.isEnabled = scrollOffset > 0
        for item in [copy, paste, all] {
            item.target = self
            menu.addItem(item) // the key equivalents are shown only: the key handler owns them
        }
        menu.addItem(.separator())
        for item in [up, down] {
            item.target = self
            menu.addItem(item)
        }
        return menu
    }

    @objc private func pageUpAction(_ sender: Any?) {
        pageUp()
    }

    @objc private func pageDownAction(_ sender: Any?) {
        pageDown()
    }

    /// Right-click (Ctrl+click) opens the context menu unless the program tracks the mouse;
    /// Shift+right-click opens it even then, as Shift+drag still selects.
    public override func menu(for event: NSEvent) -> NSMenu? {
        if programTracksMouse(event) {
            return nil
        }
        window?.makeFirstResponder(self)
        return contextMenu()
    }

    // MARK: - Mouse

    private func devicePoint(_ event: NSEvent) -> (Double, Double) {
        let p = convert(event.locationInWindow, from: nil)
        return (Double(p.x) * deviceScale, Double(p.y) * deviceScale)
    }

    /// Cell column (0-based, clamped) under a point.
    private func columnAt(_ dx: Double) -> Int {
        let column = Int((dx / Double(fonts.cellWidth)).rounded(.down))
        return max(0, min(emulator.columns() - 1, column))
    }

    /// Caret column (between cells, 0..columns) nearest to a point.
    private func caretAt(_ dx: Double) -> Int {
        let cw = Double(fonts.cellWidth)
        let caret = Int(((dx + cw / 2) / cw).rounded(.down))
        return max(0, min(emulator.columns(), caret))
    }

    private func viewRowAt(_ dy: Double) -> Int {
        let row = Int((dy / Double(fonts.cellHeight)).rounded(.down))
        return max(0, min(emulator.rows() - 1, row))
    }

    /// Absolute row (historyLinesAdded + index) of a view row. Lock held.
    private func absRow(_ viewRow: Int) -> Int64 {
        return emulator.historyLinesAdded() + Int64(viewRow - min(scrollOffset, emulator.historySize()))
    }

    private func programTracksMouse(_ event: NSEvent) -> Bool {
        return locked { emulator.mouseTracking() != .none } && !event.modifierFlags.contains(.shift)
    }

    public override func updateTrackingAreas() {
        super.updateTrackingAreas()
        if let area = trackingArea {
            removeTrackingArea(area)
        }
        let area = NSTrackingArea(rect: .zero, options: [.mouseMoved, .cursorUpdate, .activeInKeyWindow,
                                                         .inVisibleRect, .mouseEnteredAndExited],
                                  owner: self, userInfo: nil)
        addTrackingArea(area)
        trackingArea = area
    }

    // Links: ⌘-click opens a web link, even where the program tracks the mouse, as in other
    // terminals; a plain click still selects.

    private static func linkModifier(_ flags: NSEvent.ModifierFlags) -> Bool {
        return flags.contains(.command) && !flags.contains(.shift)
    }

    /// The web link under a point in view coordinates, or nil.
    private func linkAt(_ point: NSPoint) -> URL? {
        let dx = Double(point.x) * deviceScale
        let dy = Double(point.y) * deviceScale
        let url: String? = locked {
            let index = viewRowAt(dy) - min(scrollOffset, emulator.historySize())
            return Links.urlAt(emulator, index, columnAt(dx))
        }
        return url.flatMap { URL(string: $0) }
    }

    /// The hand cursor while ⌘ is held over a link, else the I-beam.
    private func updateCursor(_ flags: NSEvent.ModifierFlags) {
        guard let window = window else {
            return
        }
        let point = convert(window.mouseLocationOutsideOfEventStream, from: nil)
        if !bounds.contains(point) {
            return
        }
        if TerminalView.linkModifier(flags) && linkAt(point) != nil {
            NSCursor.pointingHand.set()
        } else {
            NSCursor.iBeam.set()
        }
    }

    public override func cursorUpdate(with event: NSEvent) {
        updateCursor(event.modifierFlags)
    }

    public override func flagsChanged(with event: NSEvent) {
        updateCursor(event.modifierFlags)
        super.flagsChanged(with: event)
    }

    public override func mouseDown(with event: NSEvent) {
        window?.makeFirstResponder(self)
        if TerminalView.linkModifier(event.modifierFlags),
           let url = linkAt(convert(event.locationInWindow, from: nil)) {
            linkOpener(url)
            return
        }
        // Ctrl+click is the Mac's right-click: the menu, unless the program tracks the mouse
        if event.modifierFlags.contains(.control) && !programTracksMouse(event) {
            NSMenu.popUpContextMenu(contextMenu(), with: event, for: self)
            return
        }
        pressed(event, MouseEncoder.left)
    }

    public override func rightMouseDown(with event: NSEvent) {
        if programTracksMouse(event) {
            window?.makeFirstResponder(self)
            pressed(event, MouseEncoder.right)
            return
        }
        super.rightMouseDown(with: event) // → menu(for:)
    }

    public override func otherMouseDown(with event: NSEvent) {
        window?.makeFirstResponder(self)
        if event.buttonNumber == 2 {
            pressed(event, MouseEncoder.middle)
        }
    }

    private func pressed(_ event: NSEvent, _ button: Int) {
        if programTracksMouse(event) && sendMouse(.press, button, event) {
            reportedButton = button
            clearSelection()
            return
        }
        if button != MouseEncoder.left {
            return
        }
        let clicks = event.clickCount
        let (dx, dy) = devicePoint(event)
        locked {
            let viewRow = viewRowAt(dy)
            let row = absRow(viewRow)
            if event.modifierFlags.contains(.shift) && selectionActive && clicks == 1 {
                extendSelectionTo(row, caretAt(dx))
                selecting = true
                return
            }
            let index = viewRow - min(scrollOffset, emulator.historySize())
            if clicks >= 3 {
                selectMode = .line
                let (top, bottom) = SelectionText.logicalLine(emulator, index)
                let base = row - Int64(index)
                anchorRow = base + Int64(top)
                anchorColumn = 0
                anchorEndRow = base + Int64(bottom)
                anchorEndColumn = emulator.columns()
                setSelection(anchorRow, anchorColumn, anchorEndRow, anchorEndColumn)
            } else if clicks == 2 {
                selectMode = .word
                let (from, to) = SelectionText.word(emulator.line(index), columnAt(dx))
                anchorRow = row
                anchorColumn = from
                anchorEndRow = row
                anchorEndColumn = to
                setSelection(anchorRow, anchorColumn, anchorEndRow, anchorEndColumn)
            } else {
                selectMode = .char
                anchorRow = row
                anchorColumn = caretAt(dx)
                anchorEndRow = row
                anchorEndColumn = anchorColumn
                selectionActive = false
            }
            selecting = true
        }
        needsDisplay = true
    }

    private func setSelection(_ startRow: Int64, _ startColumn: Int, _ endRow: Int64, _ endColumn: Int) {
        selStartRow = startRow
        selStartColumn = startColumn
        selEndRow = endRow
        selEndColumn = endColumn
        selectionActive = startRow != endRow || startColumn != endColumn
    }

    /// Extends from the anchor to a point, in the current selection mode. Lock held.
    private func extendSelectionTo(_ row: Int64, _ caret: Int) {
        var headStartRow = row
        var headStart = caret
        var headEndRow = row
        var headEnd = caret
        let index = Int(row - emulator.historyLinesAdded())
        if index >= -emulator.historySize() && index < emulator.rows() {
            if selectMode == .word {
                let (from, to) = SelectionText.word(emulator.line(index), min(caret, emulator.columns() - 1))
                headStart = from
                headEnd = to
            } else if selectMode == .line {
                let (top, bottom) = SelectionText.logicalLine(emulator, index)
                headStartRow = row - Int64(index) + Int64(top)
                headStart = 0
                headEndRow = row - Int64(index) + Int64(bottom)
                headEnd = emulator.columns()
            }
        }
        if headStartRow < anchorRow || (headStartRow == anchorRow && headStart < anchorColumn) {
            setSelection(headStartRow, headStart, anchorEndRow, anchorEndColumn)
        } else {
            setSelection(anchorRow, anchorColumn, headEndRow, headEnd)
        }
    }

    public override func mouseDragged(with event: NSEvent) {
        dragged(event)
    }

    public override func rightMouseDragged(with event: NSEvent) {
        dragged(event)
    }

    public override func otherMouseDragged(with event: NSEvent) {
        dragged(event)
    }

    private func dragged(_ event: NSEvent) {
        if reportedButton >= 0 {
            sendMouseMotion(.drag, reportedButton, event)
            return
        }
        if !selecting {
            return
        }
        let p = convert(event.locationInWindow, from: nil)
        if p.y < 0 {
            setScrollOffset(scrollOffset + 1) // dragging above the top scrolls back
        } else if bounds.height > 0 && p.y >= bounds.height {
            setScrollOffset(scrollOffset - 1)
        }
        let (dx, dy) = devicePoint(event)
        locked {
            extendSelectionTo(absRow(viewRowAt(dy)), caretAt(dx))
        }
        needsDisplay = true
    }

    public override func mouseMoved(with event: NSEvent) {
        updateCursor(event.modifierFlags)
        if locked({ emulator.mouseTracking() == .anyMotion }) {
            sendMouseMotion(.move, MouseEncoder.none, event)
        }
    }

    public override func mouseUp(with event: NSEvent) {
        released(event)
    }

    public override func rightMouseUp(with event: NSEvent) {
        released(event)
    }

    public override func otherMouseUp(with event: NSEvent) {
        released(event)
    }

    private func released(_ event: NSEvent) {
        if reportedButton >= 0 {
            let button = reportedButton
            reportedButton = -1
            _ = sendMouse(.release, button, event)
            return
        }
        selecting = false
    }

    /// Motion is reported once per cell, not per pixel.
    private func sendMouseMotion(_ action: MouseEncoder.Action, _ button: Int, _ event: NSEvent) {
        let (dx, dy) = devicePoint(event)
        let column = columnAt(dx)
        let row = viewRowAt(dy)
        if column == lastMotionColumn && row == lastMotionRow {
            return
        }
        lastMotionColumn = column
        lastMotionRow = row
        _ = sendMouse(action, button, event)
    }

    @discardableResult
    private func sendMouse(_ action: MouseEncoder.Action, _ button: Int, _ event: NSEvent) -> Bool {
        let (dx, dy) = devicePoint(event)
        let column = columnAt(dx)
        let row = viewRowAt(dy)
        let report = locked {
            MouseEncoder.encode(emulator.mouseTracking(), emulator.mouseEncoding(), action, button, column, row,
                                MouseEncoder.modifiers(event.modifierFlags))
        }
        guard let bytes = report else {
            return false
        }
        lastMotionColumn = column
        lastMotionRow = row
        output.write(bytes)
        return true
    }

    /// Where a wheel event goes.
    public enum WheelRoute {
        case swallow, mouseReport, arrowKeys, scrollback
    }

    public static func wheelRoute(_ disabled: Bool, _ tracking: TerminalEmulator.MouseTracking,
                                  _ alternateScreen: Bool) -> WheelRoute {
        if disabled {
            return .swallow
        }
        if tracking != .none {
            return .mouseReport
        }
        return alternateScreen ? .arrowKeys : .scrollback
    }

    /// A trackpad scrolls by its own distance (lines of the cell height); a wheel notch is
    /// three lines. A program gets one wheel report (or three arrow keys) per three lines.
    public override func scrollWheel(with event: NSEvent) {
        var (route, appCursor) = locked {
            (TerminalView.wheelRoute(mouseWheelDisabled, emulator.mouseTracking(), emulator.alternateScreen()),
             emulator.applicationCursorKeys())
        }
        if route == .swallow {
            wheelRemainder = 0
            return
        }
        if route == .mouseReport && event.modifierFlags.contains(.shift) {
            route = .scrollback // Shift+wheel stays local, like Shift+drag
        }
        // positive: towards the history (up)
        var delta = Double(event.scrollingDeltaY)
        if event.hasPreciseScrollingDeltas {
            delta = delta * deviceScale / Double(fonts.cellHeight)
        } else {
            delta *= Double(TerminalView.wheelLines)
        }
        wheelRemainder += delta
        let lines = Int(wheelRemainder)
        let unit = route == .scrollback ? 1 : TerminalView.wheelLines
        let steps = lines / unit
        if steps == 0 {
            return
        }
        wheelRemainder -= Double(steps * unit)
        let up = steps > 0
        let count = abs(steps)
        switch route {
        case .mouseReport:
            for _ in 0..<count {
                sendMouse(.press, up ? MouseEncoder.wheelUp : MouseEncoder.wheelDown, event)
            }
        case .arrowKeys:
            let key = (appCursor ? "\u{1b}O" : "\u{1b}[") + (up ? "A" : "B")
            output.write(Array(String(repeating: key, count: count * TerminalView.wheelLines).utf8))
        case .scrollback:
            setScrollOffset(scrollOffset + (up ? 1 : -1) * count)
        case .swallow:
            break
        }
    }

    // MARK: - Focus

    public override func becomeFirstResponder() -> Bool {
        let ok = super.becomeFirstResponder()
        DispatchQueue.main.async { [weak self] in
            self?.updateFocus()
        }
        return ok
    }

    public override func resignFirstResponder() -> Bool {
        let ok = super.resignFirstResponder()
        DispatchQueue.main.async { [weak self] in
            self?.updateFocus()
        }
        return ok
    }

    @objc private func windowKeyChanged(_ note: Notification) {
        if (note.object as? NSWindow) === window {
            updateFocus()
        }
    }

    /// Focused: first responder of the key window. Reports changes to a program that asked
    /// (DECSET 1004).
    private func updateFocus() {
        let focused = window?.isKeyWindow == true && window?.firstResponder === self
        if focused == focusedState {
            return
        }
        focusedState = focused
        let reporting = locked { emulator.focusReporting() }
        if reporting && !ended {
            output.write(Array((focused ? "\u{1b}[I" : "\u{1b}[O").utf8))
        }
        blinkOn = true
        updateBlinkTimer()
        needsDisplay = true
    }

    /// Tests and offscreen rendering: draw as focused (or not) without a key window.
    public func setFocusedForTest(_ focused: Bool) {
        focusedState = focused
        needsDisplay = true
    }
}
