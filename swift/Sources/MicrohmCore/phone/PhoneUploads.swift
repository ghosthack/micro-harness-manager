import Foundation

/// Files sent from the phone page (a screenshot of the problem, say), kept in one folder so a
/// prompt can name them by path. Each gets a fresh name; files older than `keep` are removed
/// as new ones arrive. Java's `PhoneUploads`.
struct PhoneUploads {

    /// Big enough for a phone photo or a short screen recording.
    static let maxBytes = 25 * 1024 * 1024
    static let keep: TimeInterval = 7 * 24 * 3600
    static let tooLargeMessage = "that file is larger than \(maxBytes / (1024 * 1024)) MB"

    private static let maxStem = 60
    private static let extensions: [String: String] = [
        "image/png": ".png", "image/jpeg": ".jpg", "image/gif": ".gif", "image/webp": ".webp",
        "image/heic": ".heic", "application/pdf": ".pdf", "text/plain": ".txt", "video/quicktime": ".mov",
        "video/mp4": ".mp4",
    ]

    let dir: URL
    var now: () -> Date = Date.init

    struct Failure: LocalizedError {
        let errorDescription: String?
    }

    /// Saves `body` and answers the absolute path it was saved at.
    func save(_ body: Data, name: String?, contentType: String?) throws -> URL {
        if body.isEmpty {
            throw Failure(errorDescription: "the file was empty")
        }
        if body.count > PhoneUploads.maxBytes {
            throw Failure(errorDescription: PhoneUploads.tooLargeMessage)
        }
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        prune()
        let target = dir.appendingPathComponent(fileName(name, contentType))
        try body.write(to: target, options: .withoutOverwriting)
        return target.standardizedFileURL
    }

    /// `20261120-153012-a1b2-<name>`: sortable, unique, and safe in a prompt or a shell
    /// (letters, digits, dot, dash and underscore only).
    func fileName(_ name: String?, _ contentType: String?) -> String {
        var base = (name ?? "").replacingOccurrences(of: "\\", with: "/")
        if let slash = base.lastIndex(of: "/") {
            base = String(base[base.index(after: slash)...])
        }
        var ext = ""
        if let dot = base.lastIndex(of: "."), dot > base.startIndex {
            ext = PhoneUploads.clean(String(base[dot...])).lowercased()
            base = String(base[..<dot])
            if ext.count > 10 || ext.count < 2 {
                ext = ""
            }
        }
        if ext.isEmpty, let type = contentType {
            let bare = type.split(separator: ";").first.map { $0.trimmingCharacters(in: .whitespaces).lowercased() } ?? ""
            ext = PhoneUploads.extensions[bare] ?? ""
        }
        var stem = PhoneUploads.clean(base)
        while let first = stem.first, ".-_".contains(first) {
            stem.removeFirst()
        }
        if stem.count > PhoneUploads.maxStem {
            stem = String(stem.prefix(PhoneUploads.maxStem))
        }
        if stem.isEmpty {
            stem = "upload"
        }
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = "yyyyMMdd-HHmmss"
        let tag = String(format: "%04x", UInt16.random(in: 0...UInt16.max))
        return "\(formatter.string(from: now()))-\(tag)-\(stem)\(ext)"
    }

    private static func clean(_ text: String) -> String {
        var out = ""
        var lastWasRun = false
        for scalar in text.unicodeScalars {
            let ok = scalar.isASCII && (CharacterSet.alphanumerics.contains(scalar) || ".-_".unicodeScalars.contains(scalar))
            if ok {
                out.unicodeScalars.append(scalar)
                lastWasRun = false
            } else if !lastWasRun {
                out += "_"
                lastWasRun = true
            }
        }
        return out
    }

    /// Removes files older than `keep`; best effort.
    func prune() {
        let cutoff = now().addingTimeInterval(-PhoneUploads.keep)
        let fm = FileManager.default
        guard let files = try? fm.contentsOfDirectory(at: dir, includingPropertiesForKeys: [.contentModificationDateKey, .isRegularFileKey]) else {
            return
        }
        for file in files {
            guard let values = try? file.resourceValues(forKeys: [.contentModificationDateKey, .isRegularFileKey]),
                  values.isRegularFile == true, let modified = values.contentModificationDate, modified < cutoff else {
                continue
            }
            try? fm.removeItem(at: file)
        }
    }
}
