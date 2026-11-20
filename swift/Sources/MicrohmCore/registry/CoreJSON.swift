import Foundation

/// An ordered JSON tree with Jackson `JsonNode` reading semantics (`path`, `asText`,
/// `asInt(default)`, …), so the ported parsers coerce and default exactly as the Java
/// ones did, and a writer that reproduces Jackson's output — compact, or the
/// `DefaultPrettyPrinter` layout `sessions.json` has always been written in. Object
/// members keep their order (JSONSerialization would lose it).
public indirect enum CoreJSON: Equatable, Sendable {
    case missing
    case null
    case bool(Bool)
    case int(Int64)
    case double(Double)
    case string(String)
    case array([CoreJSON])
    case object([Member])

    public struct Member: Equatable, Sendable {
        public var key: String
        public var value: CoreJSON
        public init(_ key: String, _ value: CoreJSON) {
            self.key = key
            self.value = value
        }
    }

    public struct ParseError: Error, CustomStringConvertible {
        public let message: String
        public var description: String { message }
    }

    // MARK: - building

    /// An object from ordered pairs.
    public static func obj(_ pairs: [(String, CoreJSON)]) -> CoreJSON {
        .object(pairs.map { Member($0.0, $0.1) })
    }

    /// `ObjectNode.set`/`put`: replaces an existing member in place, else appends.
    public mutating func set(_ key: String, _ value: CoreJSON) {
        guard case .object(var members) = self else { return }
        if let i = members.firstIndex(where: { $0.key == key }) {
            members[i].value = value
        } else {
            members.append(Member(key, value))
        }
        self = .object(members)
    }

    // MARK: - Jackson reading

    /// `JsonNode.get(field)`: the member, or nil when absent or not an object.
    public func get(_ key: String) -> CoreJSON? {
        guard case .object(let members) = self else { return nil }
        return members.first(where: { $0.key == key })?.value
    }

    /// `JsonNode.path(field)`: the member, else `.missing`.
    public func path(_ key: String) -> CoreJSON {
        get(key) ?? .missing
    }

    /// `JsonNode.path(index)`.
    public func path(_ index: Int) -> CoreJSON {
        guard case .array(let items) = self, index >= 0, index < items.count else { return .missing }
        return items[index]
    }

    public func has(_ key: String) -> Bool { get(key) != nil }

    public func hasNonNull(_ key: String) -> Bool {
        guard let v = get(key) else { return false }
        return v != .null
    }

    public var isMissing: Bool { self == .missing }
    public var isNull: Bool { self == .null }
    public var isObject: Bool { if case .object = self { return true }; return false }
    public var isArray: Bool { if case .array = self { return true }; return false }
    public var isTextual: Bool { if case .string = self { return true }; return false }
    public var isBoolean: Bool { if case .bool = self { return true }; return false }
    public var isNumber: Bool {
        switch self {
        case .int, .double: return true
        default: return false
        }
    }
    public var isIntegralNumber: Bool { if case .int = self { return true }; return false }

    /// `JsonNode.isEmpty()`: no elements (true for every scalar).
    public var isEmpty: Bool {
        switch self {
        case .array(let a): return a.isEmpty
        case .object(let o): return o.isEmpty
        default: return true
        }
    }

    /// Iterating a `JsonNode`: an array's items, an object's values, else nothing.
    public var elements: [CoreJSON] {
        switch self {
        case .array(let a): return a
        case .object(let o): return o.map(\.value)
        default: return []
        }
    }

    /// `JsonNode.fields()`: an object's members in order.
    public var fields: [Member] {
        if case .object(let o) = self { return o }
        return []
    }

    /// `JsonNode.asText()`.
    public func asText() -> String {
        switch self {
        case .missing: return ""
        case .null: return "null"
        case .bool(let b): return b ? "true" : "false"
        case .int(let i): return String(i)
        case .double(let d): return CoreJSON.javaDouble(d)
        case .string(let s): return s
        case .array, .object: return ""
        }
    }

    /// `JsonNode.asText(defaultValue)`: the default for missing and null.
    public func asText(_ defaultValue: String?) -> String? {
        switch self {
        case .missing, .null: return defaultValue
        default: return asText()
        }
    }

    /// `JsonNode.asLong(defaultValue)`.
    public func asLong(_ defaultValue: Int64 = 0) -> Int64 {
        switch self {
        case .int(let i): return i
        case .double(let d): return CoreJSON.javaLong(d)
        case .bool(let b): return b ? 1 : 0
        case .string(let s): return CoreJSON.parseLong(s) ?? defaultValue
        default: return defaultValue
        }
    }

    /// `JsonNode.asInt(defaultValue)`.
    public func asInt(_ defaultValue: Int = 0) -> Int {
        switch self {
        case .int(let i): return Int(Int32(truncatingIfNeeded: i))
        case .double(let d): return Int(CoreJSON.javaInt(d))
        case .bool(let b): return b ? 1 : 0
        case .string(let s): return CoreJSON.parseLong(s).map { Int(Int32(truncatingIfNeeded: $0)) } ?? defaultValue
        default: return defaultValue
        }
    }

    /// `JsonNode.asDouble(defaultValue)`.
    public func asDouble(_ defaultValue: Double = 0) -> Double {
        switch self {
        case .int(let i): return Double(i)
        case .double(let d): return d
        case .bool(let b): return b ? 1 : 0
        case .string(let s): return Double(JavaText.trim(s)) ?? defaultValue
        default: return defaultValue
        }
    }

    /// `JsonNode.asBoolean(defaultValue)`.
    public func asBoolean(_ defaultValue: Bool = false) -> Bool {
        switch self {
        case .bool(let b): return b
        case .int(let i): return i != 0
        case .string(let s):
            let t = JavaText.trim(s)
            if t == "true" { return true }
            if t == "false" { return false }
            return defaultValue
        default: return defaultValue
        }
    }

    private static func parseLong(_ s: String) -> Int64? {
        let t = JavaText.trim(s)
        if t.isEmpty { return nil }
        if let i = Int64(t) { return i }
        if let d = Double(t) { return javaLong(d) }
        return nil
    }

    private static func javaLong(_ d: Double) -> Int64 {
        if d.isNaN { return 0 }
        if d >= 9.223372036854775807e18 { return Int64.max }
        if d <= -9.223372036854775808e18 { return Int64.min }
        return Int64(d.rounded(.towardZero))
    }

    private static func javaInt(_ d: Double) -> Int32 {
        if d.isNaN { return 0 }
        if d >= Double(Int32.max) { return Int32.max }
        if d <= Double(Int32.min) { return Int32.min }
        return Int32(d.rounded(.towardZero))
    }

    /// `Double.toString(double)`, close enough for the values JSON carries: plain decimal
    /// with at least one fraction digit in [1e-3, 1e7), computerized scientific outside.
    static func javaDouble(_ d: Double) -> String {
        if d.isNaN { return "NaN" }
        if d.isInfinite { return d > 0 ? "Infinity" : "-Infinity" }
        if d == 0 { return d.sign == .minus ? "-0.0" : "0.0" }
        let a = abs(d)
        if a >= 1e-3 && a < 1e7 {
            var s = "\(d)"
            if !s.contains(".") && !s.contains("e") { s += ".0" }
            return s
        }
        // Swift prints e.g. "1e+20" / "1.5e-05"; Java prints "1.0E20" / "1.5E-5"
        let parts = "\(d)".split(separator: "e")
        guard parts.count == 2 else { return "\(d)" }
        var mantissa = String(parts[0])
        if !mantissa.contains(".") { mantissa += ".0" }
        let exponent = Int(parts[1]) ?? 0
        return mantissa + "E" + String(exponent)
    }

    // MARK: - parsing

    /// Parses the first JSON value in `text` (trailing content is ignored, as Jackson's
    /// `readTree` does by default). Empty or whitespace-only input yields `.missing`.
    public static func parse(_ text: String) throws -> CoreJSON {
        try parse(Data(text.utf8))
    }

    public static func parse(_ data: Data) throws -> CoreJSON {
        var p = Parser(bytes: [UInt8](data))
        return try p.parseDocument()
    }

    private struct Parser {
        let bytes: [UInt8]
        var i = 0

        init(bytes: [UInt8]) {
            self.bytes = bytes
            if bytes.count >= 3, bytes[0] == 0xEF, bytes[1] == 0xBB, bytes[2] == 0xBF { i = 3 }
        }

        func fail(_ what: String) -> ParseError {
            ParseError(message: "\(what) at offset \(i)")
        }

        mutating func skipWhitespace() {
            while i < bytes.count, [0x20, 0x09, 0x0A, 0x0D].contains(bytes[i]) { i += 1 }
        }

        mutating func parseDocument() throws -> CoreJSON {
            skipWhitespace()
            if i >= bytes.count { return .missing }
            return try parseValue(depth: 0)
        }

        mutating func parseValue(depth: Int) throws -> CoreJSON {
            if depth > 1000 { throw fail("nesting too deep") }
            skipWhitespace()
            guard i < bytes.count else { throw fail("unexpected end of input") }
            switch bytes[i] {
            case UInt8(ascii: "{"): return try parseObject(depth: depth)
            case UInt8(ascii: "["): return try parseArray(depth: depth)
            case UInt8(ascii: "\""): return .string(try parseString())
            case UInt8(ascii: "t"): try literal("true"); return .bool(true)
            case UInt8(ascii: "f"): try literal("false"); return .bool(false)
            case UInt8(ascii: "n"): try literal("null"); return .null
            case UInt8(ascii: "-"), UInt8(ascii: "0")...UInt8(ascii: "9"): return try parseNumber()
            default: throw fail("unexpected character")
            }
        }

        mutating func literal(_ word: String) throws {
            let w = Array(word.utf8)
            guard i + w.count <= bytes.count, Array(bytes[i..<(i + w.count)]) == w else {
                throw fail("unrecognized token")
            }
            i += w.count
            // Jackson rejects "trueX"; a following identifier character is an error
            if i < bytes.count, isIdentifierByte(bytes[i]) { throw fail("unrecognized token") }
        }

        func isIdentifierByte(_ b: UInt8) -> Bool {
            (b >= 0x30 && b <= 0x39) || (b >= 0x41 && b <= 0x5A) || (b >= 0x61 && b <= 0x7A) || b == 0x5F
        }

        mutating func parseObject(depth: Int) throws -> CoreJSON {
            i += 1
            var members: [Member] = []
            skipWhitespace()
            if i < bytes.count, bytes[i] == UInt8(ascii: "}") { i += 1; return .object(members) }
            while true {
                skipWhitespace()
                guard i < bytes.count, bytes[i] == UInt8(ascii: "\"") else { throw fail("expected field name") }
                let key = try parseString()
                skipWhitespace()
                guard i < bytes.count, bytes[i] == UInt8(ascii: ":") else { throw fail("expected ':'") }
                i += 1
                let value = try parseValue(depth: depth + 1)
                // duplicate keys: the last one wins, as Jackson's tree model does
                if let existing = members.firstIndex(where: { $0.key == key }) {
                    members[existing].value = value
                } else {
                    members.append(Member(key, value))
                }
                skipWhitespace()
                guard i < bytes.count else { throw fail("unexpected end of object") }
                if bytes[i] == UInt8(ascii: ",") { i += 1; continue }
                if bytes[i] == UInt8(ascii: "}") { i += 1; return .object(members) }
                throw fail("expected ',' or '}'")
            }
        }

        mutating func parseArray(depth: Int) throws -> CoreJSON {
            i += 1
            var items: [CoreJSON] = []
            skipWhitespace()
            if i < bytes.count, bytes[i] == UInt8(ascii: "]") { i += 1; return .array(items) }
            while true {
                items.append(try parseValue(depth: depth + 1))
                skipWhitespace()
                guard i < bytes.count else { throw fail("unexpected end of array") }
                if bytes[i] == UInt8(ascii: ",") { i += 1; continue }
                if bytes[i] == UInt8(ascii: "]") { i += 1; return .array(items) }
                throw fail("expected ',' or ']'")
            }
        }

        mutating func parseString() throws -> String {
            i += 1
            var out = [UInt8]()
            var units = [UInt16]()
            func flushUnits() {
                if !units.isEmpty {
                    out.append(contentsOf: Array(String(decoding: units, as: UTF16.self).utf8))
                    units.removeAll()
                }
            }
            while true {
                guard i < bytes.count else { throw fail("unterminated string") }
                let b = bytes[i]
                if b == UInt8(ascii: "\"") {
                    i += 1
                    flushUnits()
                    return String(decoding: out, as: UTF8.self)
                }
                if b < 0x20 { throw fail("illegal unquoted character in string") }
                if b == UInt8(ascii: "\\") {
                    i += 1
                    guard i < bytes.count else { throw fail("unterminated escape") }
                    let e = bytes[i]
                    i += 1
                    if e == UInt8(ascii: "u") {
                        guard i + 4 <= bytes.count,
                              let v = UInt16(String(decoding: bytes[i..<(i + 4)], as: UTF8.self), radix: 16) else {
                            throw fail("bad unicode escape")
                        }
                        i += 4
                        units.append(v)
                        continue
                    }
                    flushUnits()
                    switch e {
                    case UInt8(ascii: "\""): out.append(0x22)
                    case UInt8(ascii: "\\"): out.append(0x5C)
                    case UInt8(ascii: "/"): out.append(0x2F)
                    case UInt8(ascii: "b"): out.append(0x08)
                    case UInt8(ascii: "f"): out.append(0x0C)
                    case UInt8(ascii: "n"): out.append(0x0A)
                    case UInt8(ascii: "r"): out.append(0x0D)
                    case UInt8(ascii: "t"): out.append(0x09)
                    default: throw fail("unrecognized escape")
                    }
                    continue
                }
                flushUnits()
                out.append(b)
                i += 1
            }
        }

        mutating func parseNumber() throws -> CoreJSON {
            let start = i
            if bytes[i] == UInt8(ascii: "-") { i += 1 }
            func digits() -> Int {
                let s = i
                while i < bytes.count, bytes[i] >= 0x30, bytes[i] <= 0x39 { i += 1 }
                return i - s
            }
            let intDigits = digits()
            if intDigits == 0 { throw fail("bad number") }
            if intDigits > 1 && bytes[i - intDigits] == UInt8(ascii: "0") { throw fail("leading zeroes") }
            var integral = true
            if i < bytes.count, bytes[i] == UInt8(ascii: ".") {
                i += 1
                integral = false
                if digits() == 0 { throw fail("bad fraction") }
            }
            if i < bytes.count, bytes[i] == UInt8(ascii: "e") || bytes[i] == UInt8(ascii: "E") {
                i += 1
                integral = false
                if i < bytes.count, bytes[i] == UInt8(ascii: "+") || bytes[i] == UInt8(ascii: "-") { i += 1 }
                if digits() == 0 { throw fail("bad exponent") }
            }
            let text = String(decoding: bytes[start..<i], as: UTF8.self)
            if integral, let v = Int64(text) { return .int(v) }
            guard let d = Double(text) else { throw fail("bad number") }
            return .double(d)
        }
    }

    // MARK: - writing

    /// Compact form (`ObjectMapper.writeValueAsString`).
    public func compact() -> String {
        var out = ""
        write(into: &out, pretty: false, nesting: 0)
        return out
    }

    /// Jackson's `DefaultPrettyPrinter` layout (`INDENT_OUTPUT`): objects broken over
    /// lines with two-space indents and `" : "` separators, arrays inline (`[ a, b ]`).
    public func pretty() -> String {
        var out = ""
        write(into: &out, pretty: true, nesting: 0)
        return out
    }

    private func write(into out: inout String, pretty: Bool, nesting: Int) {
        switch self {
        case .missing: out += ""
        case .null: out += "null"
        case .bool(let b): out += b ? "true" : "false"
        case .int(let i): out += String(i)
        case .double(let d): out += CoreJSON.javaDouble(d)
        case .string(let s): CoreJSON.writeString(s, into: &out)
        case .array(let items):
            if !pretty {
                out += "["
                for (n, item) in items.enumerated() {
                    if n > 0 { out += "," }
                    item.write(into: &out, pretty: false, nesting: nesting)
                }
                out += "]"
                return
            }
            if items.isEmpty { out += "[ ]"; return }
            out += "[ "
            for (n, item) in items.enumerated() {
                if n > 0 { out += ", " }
                item.write(into: &out, pretty: true, nesting: nesting)
            }
            out += " ]"
        case .object(let members):
            if !pretty {
                out += "{"
                for (n, m) in members.enumerated() {
                    if n > 0 { out += "," }
                    CoreJSON.writeString(m.key, into: &out)
                    out += ":"
                    m.value.write(into: &out, pretty: false, nesting: nesting)
                }
                out += "}"
                return
            }
            if members.isEmpty { out += "{ }"; return }
            let inner = nesting + 1
            out += "{"
            for (n, m) in members.enumerated() {
                out += n == 0 ? "\n" : ",\n"
                out += String(repeating: "  ", count: inner)
                CoreJSON.writeString(m.key, into: &out)
                out += " : "
                m.value.write(into: &out, pretty: true, nesting: inner)
            }
            out += "\n" + String(repeating: "  ", count: nesting) + "}"
        }
    }

    /// Jackson's string escaping: `"` and `\`, the short forms for \b \f \n \r \t, and
    /// `\u00XX` for the other control characters; everything else verbatim.
    private static func writeString(_ s: String, into out: inout String) {
        out += "\""
        for scalar in s.unicodeScalars {
            switch scalar {
            case "\"": out += "\\\""
            case "\\": out += "\\\\"
            case "\u{08}": out += "\\b"
            case "\u{0C}": out += "\\f"
            case "\n": out += "\\n"
            case "\r": out += "\\r"
            case "\t": out += "\\t"
            default:
                if scalar.value < 0x20 {
                    out += String(format: "\\u%04X", Int(scalar.value))
                } else {
                    out.unicodeScalars.append(scalar)
                }
            }
        }
        out += "\""
    }
}
