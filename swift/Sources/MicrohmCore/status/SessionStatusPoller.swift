import Foundation

/// Drives `StateDetector` classification for the sidebar's status badges. Each live
/// session gets its own `StateDetector` instance, kept across polls (in `detectors`) so
/// quiescence timing accumulates correctly instead of resetting every tick.
///
/// `backgroundExecutor` is where the blocking daemon capture call runs — never the main
/// thread. `resultDispatcher` is where `onResult` is invoked; production wires this to
/// the main queue, tests can pass a same-thread executor (`{ $0() }`) for determinism.
///
/// Polls are serialized per session: a tick whose capture for a session is still in
/// flight skips that session instead of stacking a second task on it. This is what makes
/// the per-session `StateDetector` safe (exactly one task touches it at a time), keeps
/// captures classifying in the order they were taken, and bounds the pileup from a slow
/// or wedged daemon to one task per session no matter how many ticks elapse.
public final class SessionStatusPoller: @unchecked Sendable {

    /// Java's `java.util.concurrent.Executor`: runs (or schedules) a task.
    public typealias Executor = (@escaping () -> Void) -> Void

    public static let defaultShortQuiescence: TimeInterval = 5
    public static let defaultLongQuiescence: TimeInterval = 20

    private let host: StatusSessionHost
    private let backgroundExecutor: Executor
    private let resultDispatcher: Executor
    private let clock: MicrohmClock
    private let shortQuiescence: TimeInterval
    private let longQuiescence: TimeInterval
    private let codexSessionNameResolver: CodexSessionNameResolver
    private let lock = NSLock()
    private var detectors: [String: StateDetector] = [:]
    private var inFlight: Set<String> = []

    /// Bumped by `forget` so a poll task launched before the forget can tell its session's
    /// lifecycle ended while it was capturing: such a task discards its result and does
    /// not re-insert a detector seeded with the dead lifecycle's screen.
    private var generations: [String: Int] = [:]

    /// Quiescence thresholds in seconds (defaults 5 and 20).
    public convenience init(_ host: StatusSessionHost, _ backgroundExecutor: @escaping Executor,
                            _ resultDispatcher: @escaping Executor, _ clock: MicrohmClock,
                            _ shortQuiescence: TimeInterval = defaultShortQuiescence,
                            _ longQuiescence: TimeInterval = defaultLongQuiescence) {
        self.init(host, backgroundExecutor, resultDispatcher, clock, shortQuiescence, longQuiescence,
                  CodexSessionNameResolver())
    }

    init(_ host: StatusSessionHost, _ backgroundExecutor: @escaping Executor, _ resultDispatcher: @escaping Executor,
         _ clock: MicrohmClock, _ shortQuiescence: TimeInterval, _ longQuiescence: TimeInterval,
         _ codexSessionNameResolver: CodexSessionNameResolver) {
        self.host = host
        self.backgroundExecutor = backgroundExecutor
        self.resultDispatcher = resultDispatcher
        self.clock = clock
        self.shortQuiescence = shortQuiescence
        self.longQuiescence = longQuiescence
        self.codexSessionNameResolver = codexSessionNameResolver
    }

    /// One poll's published result: the provisional detector classification, whether it
    /// is ready to present as a status, and the best provider session title (Codex's
    /// saved chat name, otherwise the pane's OSC title). The first ordinary screen is not
    /// confirmed: without a previous capture, "different from nothing" is not proof that
    /// a harness is working.
    public struct PollResult: Equatable, Sendable {
        public let classification: Classification
        public let stateConfirmed: Bool
        public let paneTitle: String
        public let sessionGone: Bool
    }

    /// Kicks off one background capture+classify per session, each independently
    /// dispatching its result as it completes — a slow/hung capture for one session must
    /// not delay the others' badges. Sessions with a capture still in flight from an
    /// earlier tick are skipped this round (see the class comment).
    public func pollAll(_ liveSessions: [SessionEntry], _ onResult: @escaping (String, PollResult) -> Void) {
        for entry in liveSessions {
            let name = entry.sessionName
            lock.lock()
            let inserted = inFlight.insert(name).inserted
            lock.unlock()
            if !inserted {
                continue
            }
            let generation = generationOf(name)
            let task: () -> Void = { [self] in
                defer {
                    lock.lock()
                    inFlight.remove(name)
                    lock.unlock()
                }
                let classification: Classification
                let stateConfirmed: Bool
                let sessionTitle: String
                let sessionGone: Bool
                do {
                    let screen = try host.capture(name)
                    if generationOf(name) != generation {
                        return // forgotten mid-capture — stale lifecycle, drop it
                    }
                    let detector = detectorFor(name, entry.harnessType)
                    let hadBaseline = detector.hasScreenBaseline()
                    classification = detector.classify(screen)
                    sessionGone = screen.paneDead
                    stateConfirmed = classification.confidence != .medium
                        && (hadBaseline || classification.state != .working)
                    sessionTitle = entry.harnessType == .codex
                        ? codexSessionNameResolver.resolve(screen.paneProcessId) ?? screen.paneTitle
                        : screen.paneTitle
                    if generationOf(name) != generation {
                        // forget() ran between the check above and here; its detector
                        // removal may have lost the race with our insert, so evict our own
                        // (conditionally — a successor lifecycle's fresh detector must
                        // survive) and drop the stale result.
                        lock.lock()
                        if detectors[name] === detector {
                            detectors.removeValue(forKey: name)
                        }
                        lock.unlock()
                        return
                    }
                } catch {
                    // transient — the next tick retries; nothing to publish this round
                    return
                }
                // Re-checked inside the dispatched task as well: every forget() call site
                // runs on the main thread (= the production resultDispatcher), so a forget
                // landing while this result sits in the dispatch queue is observed here —
                // the dead lifecycle's badge is never published.
                let result = PollResult(classification: classification, stateConfirmed: stateConfirmed,
                                        paneTitle: sessionTitle, sessionGone: sessionGone)
                resultDispatcher { [self] in
                    if generationOf(name) == generation {
                        onResult(name, result)
                    }
                }
            }
            backgroundExecutor(task)
        }
    }

    /// `computeIfAbsent`.
    private func detectorFor(_ name: String, _ type: HarnessType) -> StateDetector {
        lock.lock(); defer { lock.unlock() }
        if let existing = detectors[name] {
            return existing
        }
        let created = StateDetector(HarnessPlugins.of(type), clock, shortQuiescence, longQuiescence)
        detectors[name] = created
        return created
    }

    private func generationOf(_ sessionName: String) -> Int {
        lock.lock(); defer { lock.unlock() }
        return generations[sessionName] ?? 0
    }

    /// Drops the detector for a session so its quiescence timing doesn't leak into a
    /// future, unrelated session of the same name (kill, remove-from-registry, resume —
    /// anywhere the underlying session's lifecycle actually ends). The generation bump
    /// comes first so an in-flight poll task observes it before it could re-insert the
    /// dead lifecycle's detector.
    public func forget(_ sessionName: String) {
        lock.lock(); defer { lock.unlock() }
        generations[sessionName, default: 0] += 1
        detectors.removeValue(forKey: sessionName)
    }

    /// Test hook: whether a detector currently exists for `sessionName`.
    func hasDetector(_ sessionName: String) -> Bool {
        lock.lock(); defer { lock.unlock() }
        return detectors[sessionName] != nil
    }
}
