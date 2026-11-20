import Foundation

/// `java.util.Properties` load/store over ISO-8859-1 bytes, so `settings.properties`
/// keeps the Java app's format: `\uXXXX` escapes for anything outside printable ASCII,
/// `#`/`!` comments, `=`/`:`/whitespace key terminators, backslash line continuations.
struct JavaProperties: Equatable {

    struct MalformedEscape: Error, CustomStringConvertible {
        var description: String { "Malformed \\uxxxx encoding." }
    }

    private(set) var values: [String: String] = [:]

    subscript(key: String) -> String? {
        get { values[key] }
        set { values[key] = newValue }
    }

    func getProperty(_ key: String) -> String? { values[key] }

    func getProperty(_ key: String, _ defaultValue: String) -> String { values[key] ?? defaultValue }

    mutating func setProperty(_ key: String, _ value: String) { values[key] = value }

    mutating func remove(_ key: String) { values.removeValue(forKey: key) }

    mutating func clear() { values.removeAll() }

    // MARK: - load

    /// `Properties.load(InputStream)`: bytes read as ISO-8859-1.
    static func load(_ bytes: Data) throws -> JavaProperties {
        try load(chars: bytes.map { UInt16($0) })
    }

    /// `Properties.load(Reader)` over UTF-16 units — Java's `LineReader` + `load0`.
    static func load(chars: [UInt16]) throws -> JavaProperties {
        var props = JavaProperties()
        var reader = LineReader(chars: chars)
        func isWs(_ c: UInt16) -> Bool { c == 0x20 || c == 0x09 || c == 0x0C }
        while let line = reader.readLine() {
            let limit = line.count
            var keyLen = 0
            var valueStart = limit
            var hasSeparator = false
            var precedingBackslash = false
            while keyLen < limit {
                let c = line[keyLen]
                if (c == 0x3D || c == 0x3A) && !precedingBackslash {
                    valueStart = keyLen + 1
                    hasSeparator = true
                    break
                } else if isWs(c) && !precedingBackslash {
                    valueStart = keyLen + 1
                    break
                }
                precedingBackslash = c == 0x5C ? !precedingBackslash : false
                keyLen += 1
            }
            while valueStart < limit {
                let c = line[valueStart]
                if !isWs(c) {
                    if !hasSeparator && (c == 0x3D || c == 0x3A) {
                        hasSeparator = true
                    } else {
                        break
                    }
                }
                valueStart += 1
            }
            let key = try loadConvert(Array(line[0..<keyLen]))
            let value = try loadConvert(Array(line[valueStart..<limit]))
            props.values[key] = value
        }
        return props
    }

    /// Java's `Properties.LineReader`: logical lines with comments and blank lines
    /// skipped, leading whitespace dropped, and backslash-newline continuations joined.
    private struct LineReader {
        let chars: [UInt16]
        var i = 0

        mutating func readLine() -> [UInt16]? {
            var buf: [UInt16] = []
            var skipWhiteSpace = true
            var isCommentLine = false
            var isNewLine = true
            var appendedLineBegin = false
            var precedingBackslash = false
            var skipLF = false
            while i < chars.count {
                let c = chars[i]
                i += 1
                if skipLF {
                    skipLF = false
                    if c == 0x0A { continue }
                }
                if skipWhiteSpace {
                    if c == 0x20 || c == 0x09 || c == 0x0C { continue }
                    if !appendedLineBegin && (c == 0x0D || c == 0x0A) { continue }
                    skipWhiteSpace = false
                    appendedLineBegin = false
                }
                if isNewLine {
                    isNewLine = false
                    if c == 0x23 || c == 0x21 {
                        isCommentLine = true
                        continue
                    }
                }
                if c != 0x0A && c != 0x0D {
                    buf.append(c)
                    precedingBackslash = c == 0x5C ? !precedingBackslash : false
                } else {
                    if isCommentLine || buf.isEmpty {
                        isCommentLine = false
                        isNewLine = true
                        skipWhiteSpace = true
                        precedingBackslash = false
                        buf.removeAll()
                        continue
                    }
                    if precedingBackslash {
                        buf.removeLast()
                        skipWhiteSpace = true
                        appendedLineBegin = true
                        precedingBackslash = false
                        if c == 0x0D { skipLF = true }
                    } else {
                        return buf
                    }
                }
            }
            if buf.isEmpty || isCommentLine {
                return nil
            }
            if precedingBackslash {
                buf.removeLast()
            }
            return buf
        }
    }

    private static func loadConvert(_ s: [UInt16]) throws -> String {
        var out: [UInt16] = []
        var i = 0
        while i < s.count {
            let c = s[i]
            i += 1
            if c != 0x5C {
                out.append(c)
                continue
            }
            guard i < s.count else { break }
            let e = s[i]
            i += 1
            switch e {
            case 0x75: // u
                var value: UInt16 = 0
                for _ in 0..<4 {
                    guard i < s.count else { throw MalformedEscape() }
                    let h = s[i]
                    i += 1
                    let digit: UInt16
                    switch h {
                    case 0x30...0x39: digit = h - 0x30
                    case 0x41...0x46: digit = h - 0x41 + 10
                    case 0x61...0x66: digit = h - 0x61 + 10
                    default: throw MalformedEscape()
                    }
                    value = value << 4 | digit
                }
                out.append(value)
            case 0x74: out.append(0x09)
            case 0x72: out.append(0x0D)
            case 0x6E: out.append(0x0A)
            case 0x66: out.append(0x0C)
            default: out.append(e)
            }
        }
        return String(decoding: out, as: UTF16.self)
    }

    // MARK: - store

    /// `Properties.store(OutputStream, comments)`: ISO-8859-1, `\uXXXX` for the rest, a
    /// comment line, a date line, then `key=value` lines. Keys are written sorted (Java's
    /// order is the hash table's, i.e. unspecified).
    func store(comments: String?, date: Date = Date()) -> Data {
        var text = ""
        if let comments {
            text += "#" + JavaProperties.escapeComment(comments) + "\n"
        }
        text += "#" + JavaProperties.javaDateString(date) + "\n"
        for key in values.keys.sorted() {
            text += JavaProperties.saveConvert(key, isKey: true) + "=" + JavaProperties.saveConvert(values[key]!, isKey: false) + "\n"
        }
        return Data(text.unicodeScalars.map { UInt8(truncatingIfNeeded: $0.value) })
    }

    private static func hex(_ unit: UInt16) -> String {
        String(format: "\\u%04X", Int(unit))
    }

    private static func saveConvert(_ s: String, isKey: Bool) -> String {
        var out = ""
        for (index, unit) in s.utf16.enumerated() {
            switch unit {
            case 0x20:
                out += (index == 0 || isKey) ? "\\ " : " "
            case 0x09: out += "\\t"
            case 0x0A: out += "\\n"
            case 0x0D: out += "\\r"
            case 0x0C: out += "\\f"
            case 0x3D, 0x3A, 0x23, 0x21, 0x5C:
                out += "\\" + String(UnicodeScalar(UInt8(unit)))
            default:
                if unit < 0x20 || unit > 0x7E {
                    out += hex(unit)
                } else {
                    out += String(UnicodeScalar(UInt8(unit)))
                }
            }
        }
        return out
    }

    /// The comment line (our comments are plain ASCII; Java escapes only non-Latin-1
    /// characters and turns embedded newlines into further comment lines).
    private static func escapeComment(_ s: String) -> String {
        var out = ""
        for unit in s.utf16 {
            if unit > 0xFF {
                out += hex(unit)
            } else if unit == 0x0A || unit == 0x0D {
                out += "\n#"
            } else {
                out += String(UnicodeScalar(UInt8(unit)))
            }
        }
        return out
    }

    /// `java.util.Date.toString()`: `EEE MMM dd HH:mm:ss zzz yyyy`.
    private static func javaDateString(_ date: Date) -> String {
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US_POSIX")
        f.dateFormat = "EEE MMM dd HH:mm:ss zzz yyyy"
        return f.string(from: date)
    }
}
