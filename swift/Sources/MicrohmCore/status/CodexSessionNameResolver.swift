import Foundation

/// Resolves Codex's saved `/rename` name without reading conversation content. Codex
/// keeps the name in `session_index.jsonl`; the active rollout file held by the pane's
/// Codex process supplies the thread id used to select the matching row. Public so the
/// MCP session controller can also point agents at a live Codex session's transcript
/// (`transcript`). Thread-safe. A call may block for a couple of seconds (`lsof`) the
/// first time it meets a Codex process, so never call it on the main thread; after that
/// the process's rollout and the parsed index are cached (`OpenFileLocator`,
/// `CodexSessionIndex`).
public final class CodexSessionNameResolver: @unchecked Sendable {

    private static let threadId = JRegex(
        #"([0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12})\.jsonl$"#)

    /// Bound on remembered first-prompt previews: one per recently seen rollout.
    static let previewCacheLimit = 128

    private let codexHome: URL
    private let rolloutLocator: (Int64) -> URL?
    private let sessionIndex: CodexSessionIndex

    /// Rollout → first-prompt preview, least recently used dropped first. An empty
    /// preview remembers the rollout's size so it is retried once the file grows.
    private let previewLock = NSLock()
    private var previewCache: [String: Preview] = [:]
    private var previewOrder: [String] = []

    private struct Preview {
        let text: String
        let rolloutSize: Int64
    }

    /// Over `$CODEX_HOME`, else `~/.codex`.
    public convenience init() {
        let home = CodexSessionNameResolver.defaultCodexHome()
        let sessionsRoot = PathCompat.normalize(home).appendingPathComponent("sessions")
        let locator = CodexSessionNameResolver.rolloutLocator(sessionsRoot)
        self.init(home, { locator.apply($0) })
    }

    /// The `rollout-*.jsonl` under `sessionsRoot` a `codex` process has open.
    private static func rolloutLocator(_ sessionsRoot: URL) -> OpenFileLocator {
        OpenFileLocator.overLsof({ $0 == "codex" }, { open in
            let file = open.lastPathComponent
            return file.hasPrefix("rollout-") && file.hasSuffix(".jsonl") && PathCompat.startsWith(open, sessionsRoot)
                ? open : nil
        })
    }

    /// Over an explicit Codex home, finding a pane's open rollout file with
    /// `rolloutLocator` — tests inject one instead of `lsof`.
    public init(_ codexHome: URL, _ rolloutLocator: @escaping (Int64) -> URL?) {
        self.codexHome = PathCompat.normalize(codexHome)
        self.rolloutLocator = rolloutLocator
        self.sessionIndex = CodexSessionIndex(self.codexHome.appendingPathComponent("session_index.jsonl"))
    }

    /// The rollout (`rollout-…-<thread id>.jsonl`) the Codex process under the pane's
    /// shell `paneProcessId` currently has open — the session's transcript — or nil when
    /// no Codex runs there or it cannot be told.
    public func transcript(_ paneProcessId: Int64) -> URL? {
        if paneProcessId <= 0 {
            return nil
        }
        return rolloutLocator(paneProcessId).map(PathCompat.normalize)
    }

    /// The session's saved `/rename` name, else its first real prompt, else nil.
    public func resolve(_ paneProcessId: Int64) -> String? {
        if paneProcessId <= 0 {
            return nil
        }
        guard let rollout = rolloutLocator(paneProcessId) else {
            return nil
        }
        guard let groups = CodexSessionNameResolver.threadId.firstGroups(rollout.lastPathComponent),
              let id = groups[1] else {
            return nil
        }
        if let savedName = sessionIndex.name(id) {
            return savedName
        }
        // Codex's history UI uses the first real user prompt as the preview for an
        // unnamed thread. Mirror that instead of falling all the way back to the cwd.
        let preview = self.preview(PathCompat.normalize(rollout))
        return preview.isEmpty ? nil : preview
    }

    /// Remembered previews (for tests).
    func previewCacheSize() -> Int {
        previewLock.lock(); defer { previewLock.unlock() }
        return previewCache.count
    }

    private func preview(_ rollout: URL) -> String {
        let key = rollout.path
        previewLock.lock()
        if let cached = previewCache[key],
           !cached.text.isEmpty || cached.rolloutSize == CodexSessionNameResolver.size(rollout) {
            touch(key)
            previewLock.unlock()
            return cached.text
        }
        previewLock.unlock()
        let size = CodexSessionNameResolver.size(rollout)
        let text = CodexSessionNameResolver.previewFromRollout(rollout) ?? ""
        previewLock.lock()
        previewCache[key] = Preview(text: text, rolloutSize: size)
        touch(key)
        while previewCache.count > CodexSessionNameResolver.previewCacheLimit, let eldest = previewOrder.first {
            previewOrder.removeFirst()
            previewCache.removeValue(forKey: eldest)
        }
        previewLock.unlock()
        return text
    }

    /// Moves `key` to the most-recently-used end (caller holds `previewLock`).
    private func touch(_ key: String) {
        if let i = previewOrder.firstIndex(of: key) {
            previewOrder.remove(at: i)
        }
        previewOrder.append(key)
    }

    private static func size(_ path: URL) -> Int64 {
        var st = stat()
        return stat(path.path, &st) == 0 ? Int64(st.st_size) : -1
    }

    private static let lineBreaks = JRegex(#"[\r\n\t]+"#)
    private static let spaceRuns = JRegex(" {2,}")

    private static func previewFromRollout(_ rollout: URL) -> String? {
        guard PathCompat.isRegularFile(rollout), let data = try? Data(contentsOf: rollout) else {
            return nil
        }
        for line in JavaText.lines(String(decoding: data, as: UTF8.self)) {
            guard let row = try? CoreJSON.parse(line) else {
                continue
            }
            let payload = row.path("payload")
            if row.path("type").asText() != "response_item"
                || payload.path("type").asText() != "message"
                || payload.path("role").asText() != "user" {
                continue
            }
            for content in payload.path("content").elements {
                if content.path("type").asText() != "input_text" {
                    continue
                }
                let text = JavaText.strip(content.path("text").asText())
                // The CLI records launch context as a synthetic user item before the
                // user's actual prompt. It is metadata, never a chat preview.
                if text.isEmpty || text.hasPrefix("<environment_context>") {
                    continue
                }
                let oneLine = JavaText.strip(spaceRuns.replaceAll(lineBreaks.replaceAll(text, with: " "), with: " "))
                return oneLine
            }
        }
        return nil
    }

    private static func defaultCodexHome() -> URL {
        if let configured = PathCompat.env("CODEX_HOME"), !JavaText.isBlank(configured) {
            return URL(fileURLWithPath: configured)
        }
        return PathCompat.userHome.appendingPathComponent(".codex")
    }
}
