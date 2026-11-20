import AppKit
import Darwin

/// Development aid for UI work, inert unless `MICROHM_UI_DEBUG` names a directory: on
/// SIGUSR1 the app reads `<dir>/command` and runs its lines — `snapshot <name>` writes
/// every visible window of the app to `<dir>/<name>-<n>.png`; `dark`, `light`, `system`
/// switch the appearance; `select <session>`, `settings [tab]`, `new`, `usage`, `about`,
/// `menu <session>`, `key` drive the UI — so a session can be screenshotted without
/// screen-recording permission or accessibility scripting.
enum DebugHooks {
    nonisolated(unsafe) private static var source: DispatchSourceSignal?

    static func install(_ handler: @escaping (String, [String]) -> Void) {
        guard let dir = ProcessInfo.processInfo.environment["MICROHM_UI_DEBUG"], !dir.isEmpty else { return }
        signal(SIGUSR1, SIG_IGN)
        let source = DispatchSource.makeSignalSource(signal: SIGUSR1, queue: .main)
        source.setEventHandler {
            let file = URL(fileURLWithPath: dir).appendingPathComponent("command")
            guard let text = try? String(contentsOf: file, encoding: .utf8) else { return }
            var delay = 0.0
            for line in text.split(separator: "\n") {
                let words = line.split(separator: " ").map(String.init)
                guard let verb = words.first else { continue }
                if verb == "wait", let seconds = words.dropFirst().first.flatMap(Double.init) {
                    delay += seconds
                    continue
                }
                if verb == "snapshot" {
                    let name = words.dropFirst().first ?? "snapshot"
                    DispatchQueue.main.asyncAfter(deadline: .now() + delay) { snapshot(dir: dir, name: name) }
                } else {
                    DispatchQueue.main.asyncAfter(deadline: .now() + delay) { handler(verb, Array(words.dropFirst())) }
                }
            }
        }
        source.resume()
        self.source = source
    }

    /// Every visible window, rendered by the app itself.
    static func snapshot(dir: String, name: String) {
        var index = 0
        for window in NSApp.orderedWindows where window.isVisible {
            guard let frameView = window.contentView?.superview else { continue }
            let bounds = frameView.bounds
            guard let rep = frameView.bitmapImageRepForCachingDisplay(in: bounds) else { continue }
            frameView.cacheDisplay(in: bounds, to: rep)
            guard let png = rep.representation(using: .png, properties: [:]) else { continue }
            index += 1
            let url = URL(fileURLWithPath: dir).appendingPathComponent("\(name)-\(index).png")
            try? png.write(to: url)
        }
        // also sheets attached to windows
        for window in NSApp.windows {
            guard let sheet = window.attachedSheet, let frameView = sheet.contentView?.superview else { continue }
            let bounds = frameView.bounds
            guard let rep = frameView.bitmapImageRepForCachingDisplay(in: bounds) else { continue }
            frameView.cacheDisplay(in: bounds, to: rep)
            guard let png = rep.representation(using: .png, properties: [:]) else { continue }
            index += 1
            try? png.write(to: URL(fileURLWithPath: dir).appendingPathComponent("\(name)-sheet-\(index).png"))
        }
    }
}
