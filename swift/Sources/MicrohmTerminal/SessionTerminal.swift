import AppKit
import Foundation

/// A byte stream to one session plus resize — what a terminal renders. The daemon client
/// (mux attach) implements it; tests use a fake. Java's `SessionConnection`, turned
/// push-style: instead of a blocking `read`, the transport calls `onBytes` with program
/// output.
public protocol TerminalTransport: AnyObject {

    /// Sends input bytes. May be called on any thread; `SessionTerminal` calls it from one
    /// serial writer queue, in order. A read-only transport drops them silently.
    func send(_ bytes: Data)

    /// The terminal grid changed size.
    func resize(cols: Int, rows: Int)

    /// Program output, called by the transport on any thread, in order. Set by
    /// `SessionTerminal` before it calls `start()`.
    var onBytes: ((Data) -> Void)? { get set }

    /// The stream ended (EOF, an error, or after `close()`). Called once, on any thread.
    var onEnd: (() -> Void)? { get set }

    /// Begins delivering `onBytes` (the callbacks are installed). Default: nothing to do.
    func start()

    /// Whether the stream is still open. Default: true.
    var isAlive: Bool { get }

    /// Detaches. Idempotent; never kills the session. Default: nothing to do.
    func close()
}

public extension TerminalTransport {
    func start() {
    }

    var isAlive: Bool { true }

    func close() {
    }
}

/// The embedded terminal over an already-open `TerminalTransport` (a daemon attach stream).
/// One of these is created per session, lazily, once its connection lands, and then kept
/// alive for the app's lifetime — switching sessions only changes which view is visible.
/// Main thread only, apart from the transport's callbacks.
///
/// It adapts the app's settings to a `TerminalView` and pumps the transport:
/// - program output (`onBytes`, on the transport's thread) goes straight into the view's
///   emulator, which is thread-safe and only queues a frame; the end of the stream marks
///   the view ended (the window polls `isAlive` to drop it);
/// - a single serial **writer** queue sends input, replies and resizes in order, so a large
///   paste or a slow daemon never blocks the main thread.
public final class SessionTerminal {

    public static let columns = 120
    public static let rows = 32
    /// Lines of local scrollback per terminal.
    public static let historyLines = 5000
    public static let minFontSize = 8
    public static let maxFontSize = 36

    public static func clampFontSize(_ size: Int) -> Int {
        return max(minFontSize, min(maxFontSize, size))
    }

    /// The settings a terminal is built with. `background` nil: the palette's own black or
    /// white (by `light`); otherwise `0xRRGGBB` matching a UI surface.
    public struct Config {
        public var background: Int?
        public var light: Bool
        public var palette: [Int]
        public var scrollbarHidden: Bool
        public var mouseWheelDisabled: Bool
        public var fontFamily: String
        public var fontSize: Int
        public var optionAsMeta: Bool

        public init(background: Int? = nil, light: Bool = false,
                    palette: [Int] = AnsiPalettes.forSetting(.macosTerminal), scrollbarHidden: Bool = false,
                    mouseWheelDisabled: Bool = false, fontFamily: String = "Menlo", fontSize: Int = 14,
                    optionAsMeta: Bool = true) {
            self.background = background
            self.light = light
            self.palette = palette
            self.scrollbarHidden = scrollbarHidden
            self.mouseWheelDisabled = mouseWheelDisabled
            self.fontFamily = fontFamily
            self.fontSize = fontSize
            self.optionAsMeta = optionAsMeta
        }
    }

    private let transport: TerminalTransport
    public let terminalView: TerminalView
    private let container: TerminalContainerView
    private let writer: DispatchQueue
    private let stateLock = NSLock()
    private var detachedFlag = false
    private var endedFlag = false
    /// Run on the main thread when the stream ends by itself (the session ended, or the
    /// daemon went away), not when `detach` closed it.
    private var onEndedAction: () -> Void = {}

    /// Builds the terminal over `transport` and starts reading from it. The transport was
    /// opened at `columns` × `rows`; the view's first real layout resizes it. Main thread.
    public init(transport: TerminalTransport, config: Config, name: String = "session") {
        self.transport = transport
        self.writer = DispatchQueue(label: "microhm-terminal-writer-" + name)
        let output = Output()
        terminalView = TerminalView(columns: SessionTerminal.columns, rows: SessionTerminal.rows,
                                    maxHistory: SessionTerminal.historyLines, output: output,
                                    palette: config.palette, background: config.background, light: config.light,
                                    fontFamily: config.fontFamily,
                                    fontSize: Double(SessionTerminal.clampFontSize(config.fontSize)))
        terminalView.mouseWheelDisabled = config.mouseWheelDisabled
        terminalView.optionAsMeta = config.optionAsMeta
        container = TerminalContainerView(terminalView, scrollbarHidden: config.scrollbarHidden)
        output.terminal = self

        transport.onBytes = { [weak self] data in
            self?.terminalView.feed(data)
        }
        transport.onEnd = { [weak self] in
            DispatchQueue.main.async {
                self?.streamEnded()
            }
        }
        transport.start()
    }

    /// Routes the view's input to the writer queue.
    private final class Output: TerminalViewOutput {
        weak var terminal: SessionTerminal?

        func write(_ bytes: [UInt8]) {
            terminal?.send { $0.send(Data(bytes)) }
        }

        func resize(columns: Int, rows: Int) {
            terminal?.send { $0.resize(cols: columns, rows: rows) }
        }
    }

    private func send(_ action: @escaping (TerminalTransport) -> Void) {
        stateLock.lock()
        let detached = detachedFlag
        stateLock.unlock()
        if detached {
            return // input after detach goes nowhere
        }
        let transport = self.transport
        writer.async {
            action(transport)
        }
    }

    private func streamEnded() {
        if endedFlag {
            return
        }
        endedFlag = true
        terminalView.markEnded()
        stateLock.lock()
        let detached = detachedFlag
        stateLock.unlock()
        if !detached {
            onEndedAction()
        }
    }

    /// Sets what runs when the stream ends without a `detach`. Main thread.
    public func onEnded(_ action: @escaping () -> Void) {
        onEndedAction = action
    }

    /// The view to show as the session's card: the terminal and its scroller.
    public var view: NSView {
        return container
    }

    /// Gives the terminal keyboard focus, so typing goes to the session.
    public func focus() {
        terminalView.window?.makeFirstResponder(terminalView)
    }

    /// Recolours this live terminal's default fg/bg pair (theme toggle): the palette's own
    /// white (`light`) or black. Only the defaults flip — cells a program painted with
    /// explicit colours keep them. Also reports light/dark to programs that ask
    /// (`CSI ?996n`).
    public func applyBackground(light: Bool) {
        terminalView.setTheme(background: nil, light: light)
        container.syncChrome()
    }

    /// Matches a UI surface (`0xRRGGBB`) while preserving explicit ANSI colours and
    /// reporting its theme.
    public func applyBackground(_ background: Int, light: Bool) {
        terminalView.setTheme(background: background, light: light)
        container.syncChrome()
    }

    /// Swaps this live terminal's 16-slot ANSI palette. Cells hold colour indexes resolved on
    /// every paint, so already painted output recolours too.
    public func applyPalette(_ palette: AnsiPalettes.Palette) {
        terminalView.setPalette(AnsiPalettes.forSetting(palette))
        container.syncChrome()
    }

    /// Changes the font and reflows this live connection to its new row/column dimensions.
    public func applyFont(family: String, size: Int) {
        terminalView.setTerminalFont(family: family, size: Double(SessionTerminal.clampFontSize(size)))
    }

    /// macOS: Option+letter/digit as Meta, or composing characters. Applies live.
    public func applyOptionAsMeta(_ on: Bool) {
        terminalView.optionAsMeta = on
    }

    /// Enables or disables the wheel-event filter immediately.
    public func applyMouseWheelDisabled(_ disabled: Bool) {
        terminalView.mouseWheelDisabled = disabled
    }

    /// Whether Page Up/Down, Home and End page the scrollback (except in a full-screen
    /// program, which gets them).
    public func applyPageKeys(_ on: Bool) {
        terminalView.pageKeysScrollback = on
    }

    public func applyScrollbarHidden(_ hidden: Bool) {
        container.scrollbarHidden = hidden
    }

    public var isAlive: Bool {
        return !endedFlag && transport.isAlive
    }

    /// Detaches: stops input and closes the transport. The session itself keeps running.
    /// Idempotent.
    public func detach() {
        stateLock.lock()
        if detachedFlag {
            stateLock.unlock()
            return
        }
        detachedFlag = true
        stateLock.unlock()
        let transport = self.transport
        writer.async {
            transport.close() // after any input already queued
        }
        terminalView.markEnded()
    }

    /// Local scrollback paging — the daemon keeps no server-side history to navigate.
    public func pageUp() {
        terminalView.pageUp()
    }

    public func pageDown() {
        terminalView.pageDown()
    }

    /// Whether the program is on the alternate screen (a full-screen program).
    public var alternateScreen: Bool {
        return terminalView.alternateScreen
    }

    public func scrollToTop() {
        terminalView.scrollToTop()
    }

    public func scrollToBottom() {
        terminalView.scrollToBottom()
    }
}

/// The terminal view with a vertical scroller over its scrollback at the right edge, both
/// on the terminal's background.
final class TerminalContainerView: NSView {

    let terminal: TerminalView
    private let scroller: NSScroller
    var scrollbarHidden: Bool {
        didSet {
            needsLayout = true
        }
    }

    init(_ terminal: TerminalView, scrollbarHidden: Bool) {
        self.terminal = terminal
        self.scrollbarHidden = scrollbarHidden
        scroller = NSScroller(frame: NSRect(x: 0, y: 0, width: 15, height: 100))
        super.init(frame: NSRect(origin: .zero, size: terminal.intrinsicContentSize))
        wantsLayer = true
        scroller.scrollerStyle = .legacy
        scroller.controlSize = .small
        scroller.knobStyle = terminal.colors.light ? .dark : .light
        scroller.isEnabled = true
        scroller.target = self
        scroller.action = #selector(scrolled(_:))
        addSubview(terminal)
        addSubview(scroller)
        terminal.onScrollChanged = { [weak self] in
            self?.updateScroller()
        }
        syncChrome()
        updateScroller()
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("not used")
    }

    override var isFlipped: Bool {
        return true
    }

    override func layout() {
        super.layout()
        let width = scrollbarHidden ? 0 : NSScroller.scrollerWidth(for: .small, scrollerStyle: .legacy)
        scroller.isHidden = scrollbarHidden
        terminal.frame = NSRect(x: 0, y: 0, width: max(0, bounds.width - width), height: bounds.height)
        scroller.frame = NSRect(x: bounds.width - width, y: 0, width: width, height: bounds.height)
    }

    func syncChrome() {
        layer?.backgroundColor = terminal.colors.color(terminal.colors.defaultBackground)
        scroller.knobStyle = terminal.colors.light ? .dark : .light
    }

    private func updateScroller() {
        let (offset, history, rows) = terminal.scrollPosition
        if history <= 0 {
            scroller.knobProportion = 1
            scroller.doubleValue = 1
            scroller.isEnabled = false
            return
        }
        scroller.isEnabled = true
        scroller.knobProportion = CGFloat(rows) / CGFloat(history + rows)
        scroller.doubleValue = 1 - Double(offset) / Double(history)
    }

    @objc private func scrolled(_ sender: NSScroller) {
        let (offset, history, rows) = terminal.scrollPosition
        switch sender.hitPart {
        case .decrementPage:
            terminal.setScrollOffset(offset + rows)
        case .incrementPage:
            terminal.setScrollOffset(offset - rows)
        default:
            terminal.setScrollOffset(Int(((1 - sender.doubleValue) * Double(history)).rounded()))
        }
    }
}
