import Foundation

/// java.lang.String semantics the ported patterns and heuristics depend on. Swift's own
/// whitespace and line handling differ in ways that matter here (Swift treats "\r\n" as
/// one Character, and its whitespace set includes U+00A0, which Java's `isBlank`/`strip`
/// do not), so the ports call these instead.
enum JavaText {

    /// `Character.isWhitespace(int)`: Unicode space separators except the non-breaking
    /// ones (U+00A0, U+2007, U+202F), plus \t \n \u000B \f \r and \u001C–\u001F.
    static func isWhitespace(_ s: Unicode.Scalar) -> Bool {
        switch s.value {
        case 0x09...0x0D, 0x1C...0x1F: return true
        case 0x00A0, 0x2007, 0x202F: return false
        default:
            switch s.properties.generalCategory {
            case .spaceSeparator, .lineSeparator, .paragraphSeparator: return true
            default: return false
            }
        }
    }

    /// `String.startsWith` compared scalar by scalar (Swift's `hasPrefix` compares
    /// grapheme clusters, so a combining mark after the prefix would defeat it).
    static func hasPrefix(_ s: String, _ prefix: String) -> Bool {
        s.unicodeScalars.starts(with: prefix.unicodeScalars)
    }

    /// `String.endsWith`, scalar by scalar.
    static func hasSuffix(_ s: String, _ suffix: String) -> Bool {
        s.unicodeScalars.reversed().starts(with: suffix.unicodeScalars.reversed())
    }

    /// `s` without its leading `prefix` (which the caller checked is there).
    static func dropPrefix(_ s: String, _ prefix: String) -> String {
        String(String.UnicodeScalarView(s.unicodeScalars.dropFirst(prefix.unicodeScalars.count)))
    }

    /// `String.isBlank()`.
    static func isBlank(_ s: String) -> Bool {
        s.unicodeScalars.allSatisfy(isWhitespace)
    }

    /// `String.strip()`.
    static func strip(_ s: String) -> String {
        stripTrailing(stripLeading(s))
    }

    /// `String.stripLeading()`.
    static func stripLeading(_ s: String) -> String {
        let scalars = s.unicodeScalars
        guard let first = scalars.firstIndex(where: { !isWhitespace($0) }) else { return "" }
        return String(scalars[first...])
    }

    /// `String.stripTrailing()`.
    static func stripTrailing(_ s: String) -> String {
        let scalars = s.unicodeScalars
        guard let last = scalars.lastIndex(where: { !isWhitespace($0) }) else { return "" }
        return String(scalars[...last])
    }

    /// `String.trim()`: strips every char <= U+0020 at both ends.
    static func trim(_ s: String) -> String {
        let scalars = s.unicodeScalars
        guard let first = scalars.firstIndex(where: { $0.value > 0x20 }),
              let last = scalars.lastIndex(where: { $0.value > 0x20 }) else { return "" }
        return String(scalars[first...last])
    }

    /// `String.lines()`: split on \n, \r and \r\n; no trailing empty element.
    static func lines(_ s: String) -> [String] {
        var out: [String] = []
        var current = String.UnicodeScalarView()
        var pendingCR = false
        for scalar in s.unicodeScalars {
            if pendingCR {
                pendingCR = false
                if scalar == "\n" { continue }
            }
            if scalar == "\n" || scalar == "\r" {
                out.append(String(current))
                current = String.UnicodeScalarView()
                pendingCR = scalar == "\r"
            } else {
                current.append(scalar)
            }
        }
        if !current.isEmpty { out.append(String(current)) }
        return out
    }

    /// `String.split("\n", -1)` for a single-scalar separator: keeps empty elements.
    static func splitKeepingEmpty(_ s: String, on separator: Unicode.Scalar) -> [String] {
        var out: [String] = []
        var current = String.UnicodeScalarView()
        for scalar in s.unicodeScalars {
            if scalar == separator {
                out.append(String(current))
                current = String.UnicodeScalarView()
            } else {
                current.append(scalar)
            }
        }
        out.append(String(current))
        return out
    }

    /// Whether the first UTF-16 unit of `s` is whitespace per `Character.isWhitespace(char)`.
    static func startsWithWhitespace(_ s: String) -> Bool {
        guard let first = s.unicodeScalars.first else { return false }
        return isWhitespace(first)
    }

    /// `Math.round(double)` narrowed like Java's `(int)` cast.
    static func round(_ d: Double) -> Int {
        if d.isNaN { return 0 }
        let r = (d + 0.5).rounded(.down)
        if r >= Double(Int32.max) { return Int(Int32.max) }
        if r <= Double(Int32.min) { return Int(Int32.min) }
        return Int(r)
    }
}

/// A `java.util.regex.Pattern` on top of NSRegularExpression (ICU). ICU's syntax is close
/// to Java's; the differences that could change a match are translated away: Java's
/// `\s \d \w` (and negations) are ASCII-only by default where ICU's are Unicode-wide, so
/// they are rewritten to explicit ASCII sets. `matches()` anchors at both ends with `\z`
/// (Java's whole-region match), `find()` is an unanchored search.
final class JRegex: @unchecked Sendable {
    let pattern: String
    private let regex: NSRegularExpression
    private let whole: NSRegularExpression

    /// `multiline` is `Pattern.MULTILINE`; inline flags such as `(?i)` stay in the pattern.
    init(_ pattern: String, multiline: Bool = false) {
        self.pattern = pattern
        let translated = JRegex.translate(pattern)
        let options: NSRegularExpression.Options = multiline ? [.anchorsMatchLines] : []
        do {
            regex = try NSRegularExpression(pattern: translated, options: options)
            whole = try NSRegularExpression(pattern: "(?:" + translated + ")\\z", options: options)
        } catch {
            fatalError("bad pattern \(pattern): \(error)")
        }
    }

    private static func range(_ s: String) -> NSRange { NSRange(location: 0, length: (s as NSString).length) }

    /// `Matcher.find()` from the start.
    func find(_ s: String) -> Bool {
        regex.firstMatch(in: s, options: [], range: JRegex.range(s)) != nil
    }

    /// `Matcher.matches()`.
    func matches(_ s: String) -> Bool {
        whole.firstMatch(in: s, options: [.anchored], range: JRegex.range(s)) != nil
    }

    /// Every match's capture groups (index 0 = whole match), nil for a group that did not
    /// participate — Java's `while (matcher.find()) matcher.group(n)`.
    func allGroups(_ s: String) -> [[String?]] {
        let ns = s as NSString
        return regex.matches(in: s, options: [], range: JRegex.range(s)).map { m in
            (0..<m.numberOfRanges).map { i in
                let r = m.range(at: i)
                return r.location == NSNotFound ? nil : ns.substring(with: r)
            }
        }
    }

    /// The first match's capture groups, or nil when nothing matches.
    func firstGroups(_ s: String) -> [String?]? {
        let ns = s as NSString
        guard let m = regex.firstMatch(in: s, options: [], range: JRegex.range(s)) else { return nil }
        return (0..<m.numberOfRanges).map { i in
            let r = m.range(at: i)
            return r.location == NSNotFound ? nil : ns.substring(with: r)
        }
    }

    /// `Matcher.replaceAll(literal)` — the replacement is taken literally.
    func replaceAll(_ s: String, with literal: String) -> String {
        regex.stringByReplacingMatches(in: s, options: [], range: JRegex.range(s),
                                       withTemplate: NSRegularExpression.escapedTemplate(for: literal))
    }

    private static let space = #"\t\n\x0B\f\r\x20"#
    private static let digit = "0-9"
    private static let word = "a-zA-Z0-9_"

    /// Rewrites Java's ASCII-only predefined classes for ICU.
    static func translate(_ p: String) -> String {
        var out = ""
        var depth = 0
        var chars = Array(p)
        var i = 0
        // a ']' right after '[' or '[^' is literal in Java
        var classStart = false
        while i < chars.count {
            let c = chars[i]
            if c == "\\", i + 1 < chars.count {
                let n = chars[i + 1]
                let inside = depth > 0
                var set: String?
                var negated = false
                switch n {
                case "s": set = space
                case "S": set = space; negated = true
                case "d": set = digit
                case "D": set = digit; negated = true
                case "w": set = word
                case "W": set = word; negated = true
                default: break
                }
                if let set {
                    if inside && !negated {
                        out += set
                    } else {
                        out += negated ? "[^" + set + "]" : "[" + set + "]"
                    }
                } else {
                    out.append(c)
                    out.append(n)
                }
                i += 2
                classStart = false
                continue
            }
            if c == "[" {
                depth += 1
                out.append(c)
                i += 1
                if i < chars.count, chars[i] == "^" {
                    out.append("^")
                    i += 1
                }
                classStart = true
                continue
            }
            if c == "]", depth > 0, !classStart {
                depth -= 1
                out.append(c)
                i += 1
                continue
            }
            if c == "]", depth > 0, classStart {
                out += "\\]"
                i += 1
                classStart = false
                continue
            }
            classStart = false
            out.append(c)
            i += 1
        }
        chars.removeAll()
        return out
    }
}
