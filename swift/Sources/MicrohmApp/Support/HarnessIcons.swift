import AppKit
import MicrohmCore

/// The app's resources, found without `Bundle.module`: SwiftPM's generated accessor
/// traps when its bundle is not where it expects, and the .app built by
/// `scripts/build-app.sh` keeps resource bundles in Contents/Resources. A missing
/// resource here only ever means a missing icon.
enum AppResources {
    static let bundleName = "Microhm_MicrohmApp.bundle"

    static let bundle: Bundle? = {
        let exe = Bundle.main.executableURL?.resolvingSymlinksInPath().deletingLastPathComponent()
        let candidates = [
            Bundle.main.resourceURL?.appendingPathComponent(bundleName),
            Bundle.main.bundleURL.appendingPathComponent(bundleName),
            exe?.appendingPathComponent(bundleName),
            exe?.deletingLastPathComponent().appendingPathComponent("Resources").appendingPathComponent(bundleName),
        ].compactMap { $0 }
        for url in candidates where FileManager.default.fileExists(atPath: url.path) {
            if let bundle = Bundle(url: url) { return bundle }
        }
        return nil
    }()

    static func url(_ relativePath: String) -> URL? {
        guard let base = bundle?.resourceURL ?? bundle?.bundleURL else { return nil }
        let url = base.appendingPathComponent(relativePath)
        return FileManager.default.fileExists(atPath: url.path) ? url : nil
    }

    static let appIcon: NSImage? = url("app-icon.png").flatMap { NSImage(contentsOf: $0) }
}

/// Harness identities: the providers' flat marks (SVG, tinted as template images) and an
/// SF Symbol for the plain shell. Cached per type and size.
enum HarnessIcons {
    private static var cache: [String: NSImage] = [:]

    private static func svgName(_ type: HarnessType) -> String? {
        switch type {
        case .claudeCode: return "anthropic"
        case .codex: return "openai"
        case .cursorAgent: return "cursor"
        case .grok: return "grok"
        case .opencode: return "opencode"
        case .pi: return "pi"
        case .muse: return "muse"
        case .shell: return nil
        }
    }

    /// A template image (tints with the surrounding text colour) `size` points square.
    static func image(_ type: HarnessType, size: CGFloat = 16) -> NSImage {
        let key = "\(type.id)@\(size)"
        if let cached = cache[key] { return cached }
        let image: NSImage
        if let name = svgName(type), let url = AppResources.url("provider-icons/\(name).svg"),
           let svg = NSImage(contentsOf: url) {
            image = NSImage(size: NSSize(width: size, height: size), flipped: false) { rect in
                svg.draw(in: rect)
                return true
            }
        } else {
            let config = NSImage.SymbolConfiguration(pointSize: size * 0.82, weight: .medium)
            image = NSImage(systemSymbolName: "terminal", accessibilityDescription: type.id)?
                .withSymbolConfiguration(config) ?? NSImage(size: NSSize(width: size, height: size))
        }
        image.isTemplate = true
        image.accessibilityDescription = SidebarView.label(type)
        cache[key] = image
        return image
    }

    /// An SF Symbol, or an empty image if the system lacks it (never nil).
    static func symbol(_ name: String, _ description: String? = nil, pointSize: CGFloat? = nil,
                       weight: NSFont.Weight = .regular) -> NSImage {
        var image = NSImage(systemSymbolName: name, accessibilityDescription: description)
            ?? NSImage(systemSymbolName: "questionmark.square.dashed", accessibilityDescription: description)
            ?? NSImage(size: NSSize(width: 16, height: 16))
        if let pointSize, let configured = image.withSymbolConfiguration(.init(pointSize: pointSize, weight: weight)) {
            image = configured
        }
        return image
    }
}
