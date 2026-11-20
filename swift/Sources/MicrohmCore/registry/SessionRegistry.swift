import Foundation
import MicrohmShared

/// The session registry: session name -> `SessionEntry`, backed by a JSON file at
/// `<home>/sessions.json` (see `RegistryPaths`). Loaded once on startup; every mutating
/// call re-saves immediately, so the file on disk is never more than one mutation stale.
///
/// The file format is the Java app's (Jackson, `INDENT_OUTPUT`, ISO-8601 `createdAt`):
/// `{"sessions": [{"sessionName", "projectPath", "harnessType", "harnessSessionId",
/// "createdAt", "displayName"}, …]}`. Jackson's numeric-timestamp encoding round-trips
/// an Instant through a double, which can't hold nanosecond precision at today's epoch
/// magnitude and silently rounds it — ISO-8601 strings round-trip exactly.
public final class SessionRegistry: @unchecked Sendable {

    private let file: URL
    private let lock = NSLock()
    private var order: [String]
    private var entries: [String: SessionEntry]

    /// Raw `sessions[]` elements this build could not bind (most plausibly an entry
    /// written by a newer build with a harness type this one doesn't know). Preserved
    /// verbatim and written back on every save, so a mutation here never destroys another
    /// build's entries — resume ids are not recoverable once lost. A `put` or `remove`
    /// under the same session-name key supersedes the preserved node (the user's explicit
    /// action wins over a stale foreign entry).
    private var unknownEntries: [CoreJSON]

    /// The raw node each bound entry was loaded from, keyed by session name. On save,
    /// fields a newer build wrote that this build's `SessionEntry` doesn't know (silently
    /// dropped by binding) are merged back from here, so rewriting an entry doesn't strip
    /// them.
    private var originalNodes: [String: CoreJSON]

    /// False when the file on disk couldn't be read *and* couldn't be backed up — the
    /// only copy of its contents is still that file, so this run keeps its registry in
    /// memory and never overwrites it. Resume ids are not recoverable once lost.
    private let persistent: Bool

    private init(file: URL, order: [String], entries: [String: SessionEntry], unknownEntries: [CoreJSON],
                 originalNodes: [String: CoreJSON], persistent: Bool = true) {
        self.file = file
        self.order = order
        self.entries = entries
        self.unknownEntries = unknownEntries
        self.originalNodes = originalNodes
        self.persistent = persistent
    }

    /// The registry at `RegistryPaths.resolve()`.
    public static func load() -> SessionRegistry {
        load(RegistryPaths.resolve())
    }

    /// Loads the registry from `file`. A missing file is a fresh install (empty registry,
    /// no warning). Tolerance is per-entry, not per-file: an element that fails to bind is
    /// kept as raw JSON (see `unknownEntries`) rather than discarded, and a null element
    /// or missing/null `sessions` list is simply empty. Only a file that isn't parseable
    /// JSON at all is treated as corrupt — and even then it is backed up beside itself
    /// before the empty registry's first save can overwrite it, because whatever wrote
    /// garbage there, the user still needs a working session manager *and* a shot at
    /// recovering the old contents.
    ///
    /// Binding differs from Jackson in one place: an entry with no `harnessType` (null in
    /// Java, which every caller would then trip over) is preserved as unknown instead.
    public static func load(_ file: URL) -> SessionRegistry {
        if !FileManager.default.fileExists(atPath: file.path) {
            return empty(file)
        }
        let root: CoreJSON
        do {
            root = try CoreJSON.parse(try Data(contentsOf: file))
        } catch {
            // Also reached on an I/O error (permissions, EIO), where the backup copy is
            // likely to fail too — then the file must survive this run untouched.
            return emptyReplacing(file, "\(error)")
        }
        if root == .missing || root == .null {
            // an empty file — nothing to preserve
            return empty(file)
        }
        if !root.isObject {
            return emptyReplacing(file, "top-level value is not an object")
        }

        var order: [String] = []
        var byName: [String: SessionEntry] = [:]
        var unknown: [CoreJSON] = []
        var originals: [String: CoreJSON] = [:]
        let sessions = root.path("sessions")
        if sessions == .missing || sessions == .null {
            // "{}" or {"sessions": null} — a valid, empty registry
            return SessionRegistry(file: file, order: order, entries: byName, unknownEntries: unknown,
                                   originalNodes: originals)
        }
        if !sessions.isArray {
            return emptyReplacing(file, "\"sessions\" is not an array")
        }
        for node in sessions.elements {
            if node == .null {
                Log.warn("session registry at \(file.path) contains a null entry — skipping it", tag: "registry")
                continue
            }
            let entry: SessionEntry?
            do {
                entry = try bind(node)
            } catch {
                Log.warn("session registry at \(file.path) has an entry this build can't read (\(error)) — keeping it"
                         + " as-is; it will be preserved unchanged on save", tag: "registry")
                unknown.append(node)
                continue
            }
            guard let entry else {
                Log.warn("session registry at \(file.path) has an entry with no sessionName — keeping it"
                         + " as-is; it will be preserved unchanged on save", tag: "registry")
                unknown.append(node)
                continue
            }
            if byName[entry.sessionName] == nil {
                order.append(entry.sessionName)
            }
            byName[entry.sessionName] = entry
            originals[entry.sessionName] = node
        }
        return SessionRegistry(file: file, order: order, entries: byName, unknownEntries: unknown,
                               originalNodes: originals)
    }

    private static func empty(_ file: URL) -> SessionRegistry {
        SessionRegistry(file: file, order: [], entries: [:], unknownEntries: [], originalNodes: [:])
    }

    /// An empty registry in place of an unusable file: saved over it only once the
    /// original is safely backed up, otherwise kept in memory for this run.
    private static func emptyReplacing(_ file: URL, _ why: String) -> SessionRegistry {
        let backedUp = backUpCorrupt(file, why)
        return SessionRegistry(file: file, order: [], entries: [:], unknownEntries: [], originalNodes: [:],
                               persistent: backedUp)
    }

    public func sessions() -> [SessionEntry] {
        lock.lock(); defer { lock.unlock() }
        return order.compactMap { entries[$0] }
    }

    public func find(_ sessionName: String) -> SessionEntry? {
        lock.lock(); defer { lock.unlock() }
        return entries[sessionName]
    }

    /// Adds a new entry, or overwrites the existing one for that session (keeping its
    /// place in the order). Also supersedes any preserved unknown entry under the same key
    /// — otherwise the file would carry duplicate keys and a build that can bind both
    /// would resolve them by array order, letting the stale foreign node win.
    public func put(_ entry: SessionEntry) {
        lock.lock(); defer { lock.unlock() }
        if entries[entry.sessionName] == nil {
            order.append(entry.sessionName)
        }
        entries[entry.sessionName] = entry
        unknownEntries.removeAll { SessionRegistry.unknownKeyOf($0) == entry.sessionName }
        save()
    }

    public func remove(_ sessionName: String) {
        lock.lock(); defer { lock.unlock() }
        entries.removeValue(forKey: sessionName)
        order.removeAll { $0 == sessionName }
        originalNodes.removeValue(forKey: sessionName)
        unknownEntries.removeAll { SessionRegistry.unknownKeyOf($0) == sessionName }
        save()
    }

    /// Persists a conversation id/name recovered from a harness's graceful-exit receipt.
    /// This is atomic with respect to other registry mutations, so a concurrent rename
    /// cannot be overwritten by a stale `SessionEntry` snapshot from close.
    public func recordHarnessSessionId(_ sessionName: String, _ harnessSessionId: String?) {
        lock.lock(); defer { lock.unlock() }
        guard let current = entries[sessionName], let id = harnessSessionId, !JavaText.isBlank(id),
              JavaText.strip(id) != current.harnessSessionId else {
            return
        }
        entries[sessionName] = current.withHarnessSessionId(id)
        save()
    }

    private static func unknownKeyOf(_ node: CoreJSON) -> String? {
        if case .string(let key) = node.path("sessionName") {
            return key
        }
        return nil
    }

    // MARK: - binding

    private struct BindError: Error, CustomStringConvertible {
        let description: String
    }

    /// Jackson's binding of one `sessions[]` element; nil when it has no sessionName.
    private static func bind(_ node: CoreJSON) throws -> SessionEntry? {
        guard node.isObject else {
            throw BindError(description: "entry is not an object")
        }
        guard let sessionName = try text(node, "sessionName") else {
            return nil
        }
        guard let typeId = try text(node, "harnessType") else {
            throw BindError(description: "entry has no harnessType")
        }
        let type: HarnessType
        do {
            type = try HarnessType.fromId(typeId)
        } catch {
            throw BindError(description: "\(error)")
        }
        let createdAt: Date
        switch node.path("createdAt") {
        case .missing, .null:
            createdAt = Date(timeIntervalSince1970: 0)
        case .string(let s):
            guard let d = IsoInstant.parse(JavaText.trim(s)) else {
                throw BindError(description: "createdAt is not an ISO-8601 instant: \(s)")
            }
            createdAt = d
        case .int(let seconds):
            createdAt = Date(timeIntervalSince1970: Double(seconds))
        case .double(let seconds):
            createdAt = Date(timeIntervalSince1970: seconds)
        default:
            throw BindError(description: "createdAt is not an instant")
        }
        return SessionEntry(sessionName, try text(node, "projectPath") ?? "", type,
                            try text(node, "harnessSessionId"), createdAt, try text(node, "displayName"))
    }

    /// A String property as Jackson binds it: null/missing is nil, scalars coerce to text,
    /// containers fail.
    private static func text(_ node: CoreJSON, _ key: String) throws -> String? {
        switch node.path(key) {
        case .missing, .null: return nil
        case .array, .object: throw BindError(description: "\(key) is not a string")
        case let scalar: return scalar.asText()
        }
    }

    private static func serialize(_ entry: SessionEntry) -> CoreJSON {
        func str(_ s: String?) -> CoreJSON { s.map { .string($0) } ?? .null }
        return CoreJSON.obj([
            ("sessionName", .string(entry.sessionName)),
            ("projectPath", .string(entry.projectPath)),
            ("harnessType", .string(entry.harnessType.id)),
            ("harnessSessionId", str(entry.harnessSessionId)),
            ("createdAt", .string(IsoInstant.format(entry.createdAt))),
            ("displayName", str(entry.displayName)),
        ])
    }

    // MARK: - saving

    /// Caller holds `lock`.
    private func save() {
        if !persistent {
            Log.warn("not saving session registry to \(file.path): its unreadable original could not be"
                     + " backed up, so this run's changes are kept in memory only", tag: "registry")
            return
        }
        var sessions: [CoreJSON] = []
        for name in order {
            guard let entry = entries[name] else { continue }
            var serialized = SessionRegistry.serialize(entry)
            // fields a newer build wrote that binding dropped are merged back in
            if let original = originalNodes[name] {
                for field in original.fields where serialized.get(field.key) == nil {
                    serialized.set(field.key, field.value)
                }
            }
            sessions.append(serialized)
        }
        for node in unknownEntries {
            // put()/remove() already supersede same-key unknowns; this guards a
            // foreign-written file that carried the duplicate from the start
            let key = SessionRegistry.unknownKeyOf(node)
            if key == nil || entries[key!] == nil {
                sessions.append(node)
            }
        }
        let root = CoreJSON.obj([("sessions", .array(sessions))])
        do {
            try AtomicFile.write(Data(root.pretty().utf8), to: file, tempPrefix: "sessions-", tempSuffix: ".json.tmp")
        } catch {
            // A failed save must not crash a UI mutation the user already sees reflected in
            // the sidebar; the in-memory registry stays authoritative for this run either way.
            Log.error("failed to save session registry to \(file.path): \(error)", tag: "registry")
        }
    }

    /// Copies an unparseable registry file aside so the next save can't destroy it.
    /// Returns whether the copy was made.
    private static func backUpCorrupt(_ file: URL, _ why: String) -> Bool {
        let millis = Int64(Date().timeIntervalSince1970 * 1000)
        let backup = file.deletingLastPathComponent()
            .appendingPathComponent(file.lastPathComponent + ".corrupt-\(millis)")
        do {
            let data = try Data(contentsOf: file)
            try data.write(to: backup)
            Log.warn("session registry at \(file.path) is unreadable (\(why)) — starting with an empty registry;"
                     + " the original was backed up to \(backup.path)", tag: "registry")
            return true
        } catch {
            Log.error("session registry at \(file.path) is unreadable (\(why)) and could not be backed up (\(error))"
                      + " — starting with an empty registry that will not be saved this run,"
                      + " so the original is left intact", tag: "registry")
            return false
        }
    }
}
