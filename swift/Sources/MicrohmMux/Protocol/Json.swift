import Foundation

/// A JSON value with insertion-ordered objects (the Java side used Jackson's tree model;
/// its `ObjectNode` keeps insertion order and writes compact JSON, which this mirrors so
/// replies read the same on the wire). Numbers keep the integer/fraction distinction
/// Jackson makes: `canConvertToInt` and friends follow its rules.
public enum JSON: Equatable, Sendable, CustomStringConvertible {
    case null
    case bool(Bool)
    case int(Int64)
    case double(Double)
    case string(String)
    case array([JSON])
    case object(JSONObject)

    // MARK: Jackson-style accessors

    public subscript(key: String) -> JSON? {
        if case .object(let o) = self { return o[key] }
        return nil
    }

    public var isObject: Bool { if case .object = self { return true }; return false }
    public var isArray: Bool { if case .array = self { return true }; return false }
    public var isNull: Bool { if case .null = self { return true }; return false }
    public var isTextual: Bool { if case .string = self { return true }; return false }
    public var isBoolean: Bool { if case .bool = self { return true }; return false }
    public var isNumber: Bool {
        switch self { case .int, .double: return true; default: return false }
    }

    public var objectValue: JSONObject? { if case .object(let o) = self { return o }; return nil }
    public var arrayValue: [JSON]? { if case .array(let a) = self { return a }; return nil }
    public var stringValue: String? { if case .string(let s) = self { return s }; return nil }

    /// Jackson `canConvertToInt`: a number within the int range.
    public var canConvertToInt: Bool {
        switch self {
        case .int(let v): return v >= Int64(Int32.min) && v <= Int64(Int32.max)
        case .double(let d): return d >= Double(Int32.min) && d <= Double(Int32.max)
        default: return false
        }
    }

    /// Jackson `canConvertToLong`.
    public var canConvertToLong: Bool {
        switch self {
        case .int: return true
        case .double(let d): return d >= -9.223372036854776E18 && d < 9.223372036854776E18
        default: return false
        }
    }

    /// Jackson `asLong(default)`: numbers, numeric text, booleans as 1/0.
    public func asLong(_ fallback: Int64 = 0) -> Int64 {
        switch self {
        case .int(let v): return v
        case .double(let d): return d.isFinite ? Int64(max(min(d, 9.2e18), -9.2e18)) : fallback
        case .bool(let b): return b ? 1 : 0
        case .string(let s):
            let t = s.trimmingCharacters(in: .whitespaces)
            if let v = Int64(t) { return v }
            if let d = Double(t), d.isFinite { return Int64(max(min(d, 9.2e18), -9.2e18)) }
            return fallback
        default: return fallback
        }
    }

    /// Jackson `asInt(default)`.
    public func asInt(_ fallback: Int = 0) -> Int {
        switch self {
        case .int(let v): return Int(Int32(truncatingIfNeeded: v))
        case .double, .bool, .string:
            let missing = Int64.min
            let v = asLong(missing)
            return v == missing ? fallback : Int(Int32(truncatingIfNeeded: v))
        default: return fallback
        }
    }

    /// Jackson `asBoolean(default)`: booleans, numbers (non-zero), "true"/"false" text.
    public func asBoolean(_ fallback: Bool = false) -> Bool {
        switch self {
        case .bool(let b): return b
        case .int(let v): return v != 0
        case .double(let d): return d != 0
        case .string(let s):
            let t = s.trimmingCharacters(in: .whitespaces)
            if t == "true" { return true }
            if t == "false" { return false }
            return fallback
        default: return fallback
        }
    }

    /// Jackson `asText()`: the text of a scalar, "" for containers.
    public func asText() -> String {
        switch self {
        case .null: return "null"
        case .bool(let b): return b ? "true" : "false"
        case .int(let v): return String(v)
        case .double(let d): return JSON.formatDouble(d)
        case .string(let s): return s
        case .array, .object: return ""
        }
    }

    // MARK: serialization

    /// Compact JSON, as Jackson writes it (no spaces, `/` not escaped, non-ASCII as UTF-8).
    public var description: String { serialized() }

    public func serialized(escapeNonASCII: Bool = false) -> String {
        var out = ""
        write(to: &out, escapeNonASCII: escapeNonASCII)
        return out
    }

    public var bytes: [UInt8] { Array(serialized().utf8) }

    private func write(to out: inout String, escapeNonASCII: Bool) {
        switch self {
        case .null: out += "null"
        case .bool(let b): out += b ? "true" : "false"
        case .int(let v): out += String(v)
        case .double(let d): out += JSON.formatDouble(d)
        case .string(let s): JSON.quote(s, into: &out, escapeNonASCII: escapeNonASCII)
        case .array(let a):
            out += "["
            for (i, v) in a.enumerated() {
                if i > 0 { out += "," }
                v.write(to: &out, escapeNonASCII: escapeNonASCII)
            }
            out += "]"
        case .object(let o):
            out += "{"
            for (i, key) in o.keys.enumerated() {
                if i > 0 { out += "," }
                JSON.quote(key, into: &out, escapeNonASCII: escapeNonASCII)
                out += ":"
                o.values[key]!.write(to: &out, escapeNonASCII: escapeNonASCII)
            }
            out += "}"
        }
    }

    private static let hex: [Character] = Array("0123456789ABCDEF")

    private static func quote(_ s: String, into out: inout String, escapeNonASCII: Bool) {
        out += "\""
        for scalar in s.unicodeScalars {
            switch scalar.value {
            case 0x22: out += "\\\""
            case 0x5C: out += "\\\\"
            case 0x0A: out += "\\n"
            case 0x0D: out += "\\r"
            case 0x09: out += "\\t"
            case 0x08: out += "\\b"
            case 0x0C: out += "\\f"
            case 0..<0x20: appendUnicodeEscape(UInt16(scalar.value), into: &out)
            case 0x80...:
                if escapeNonASCII {
                    // Jackson ESCAPE_NON_ASCII: UTF-16 units, so astral characters become pairs.
                    for unit in String(scalar).utf16 { appendUnicodeEscape(unit, into: &out) }
                } else {
                    out.unicodeScalars.append(scalar)
                }
            default: out.unicodeScalars.append(scalar)
            }
        }
        out += "\""
    }

    private static func appendUnicodeEscape(_ unit: UInt16, into out: inout String) {
        out += "\\u"
        out.append(hex[Int(unit >> 12) & 0xF])
        out.append(hex[Int(unit >> 8) & 0xF])
        out.append(hex[Int(unit >> 4) & 0xF])
        out.append(hex[Int(unit) & 0xF])
    }

    static func formatDouble(_ d: Double) -> String {
        if d.isNaN { return "\"NaN\"" }
        if d.isInfinite { return d > 0 ? "\"Infinity\"" : "\"-Infinity\"" }
        if d == d.rounded(), abs(d) < 1e15 { return String(format: "%.1f", d) }
        return String(d)
    }

    // MARK: parsing

    public static func parse(_ bytes: [UInt8]) throws -> JSON {
        var parser = JSONParser(bytes)
        return try parser.parseDocument()
    }

    public static func parse(_ text: String) throws -> JSON {
        try parse(Array(text.utf8))
    }
}

/// An insertion-ordered JSON object; setting an existing key keeps its position (as
/// Jackson's `ObjectNode.put` does).
public struct JSONObject: Equatable, Sendable {
    public private(set) var keys: [String] = []
    public private(set) var values: [String: JSON] = [:]

    public init() {}

    public subscript(key: String) -> JSON? {
        get { values[key] }
        set {
            if let newValue {
                if values.updateValue(newValue, forKey: key) == nil { keys.append(key) }
            } else if values.removeValue(forKey: key) != nil {
                keys.removeAll { $0 == key }
            }
        }
    }

    public var isEmpty: Bool { keys.isEmpty }
    public var count: Int { keys.count }

    /// Fields in order.
    public var fields: [(String, JSON)] { keys.map { ($0, values[$0]!) } }

    public func has(_ key: String) -> Bool { values[key] != nil }

    // Builder helpers, Jackson `put` style (chainable).
    @discardableResult
    public mutating func put(_ key: String, _ value: String?) -> JSONObject {
        self[key] = value.map(JSON.string) ?? .null
        return self
    }
    @discardableResult
    public mutating func put(_ key: String, _ value: Bool) -> JSONObject { self[key] = .bool(value); return self }
    @discardableResult
    public mutating func put(_ key: String, _ value: Int) -> JSONObject { self[key] = .int(Int64(value)); return self }
    @discardableResult
    public mutating func put(_ key: String, _ value: Int64) -> JSONObject { self[key] = .int(value); return self }
    @discardableResult
    public mutating func put(_ key: String, _ value: Int32) -> JSONObject { self[key] = .int(Int64(value)); return self }
    @discardableResult
    public mutating func set(_ key: String, _ value: JSON) -> JSONObject { self[key] = value; return self }

    public var json: JSON { .object(self) }
}

/// Builds objects fluently: `Json.object().with(...)`.
extension JSONObject {
    public func with(_ key: String, _ value: JSON) -> JSONObject { var c = self; c[key] = value; return c }
    public func with(_ key: String, _ value: String) -> JSONObject { with(key, .string(value)) }
    public func with(_ key: String, _ value: Bool) -> JSONObject { with(key, .bool(value)) }
    public func with(_ key: String, _ value: Int) -> JSONObject { with(key, .int(Int64(value))) }
    public func with(_ key: String, _ value: Int64) -> JSONObject { with(key, .int(value)) }
    public func with(_ key: String, _ value: Int32) -> JSONObject { with(key, .int(Int64(value))) }
}

public struct JSONParseError: Error, CustomStringConvertible, LocalizedError {
    public let message: String
    public var description: String { message }
    public var errorDescription: String? { message }
}

private struct JSONParser {
    let bytes: [UInt8]
    var i = 0

    init(_ bytes: [UInt8]) { self.bytes = bytes }

    mutating func parseDocument() throws -> JSON {
        skipWhitespace()
        if i >= bytes.count { throw JSONParseError(message: "No content to map due to end-of-input") }
        let value = try parseValue(depth: 0)
        skipWhitespace()
        if i < bytes.count { throw fail("Unexpected trailing content") }
        return value
    }

    func fail(_ what: String) -> JSONParseError {
        JSONParseError(message: "\(what) at byte \(i)")
    }

    mutating func skipWhitespace() {
        while i < bytes.count, bytes[i] == 0x20 || bytes[i] == 0x0A || bytes[i] == 0x0D || bytes[i] == 0x09 { i += 1 }
    }

    mutating func parseValue(depth: Int) throws -> JSON {
        if depth > 1000 { throw fail("Nesting too deep") }
        skipWhitespace()
        guard i < bytes.count else { throw fail("Unexpected end-of-input") }
        switch bytes[i] {
        case UInt8(ascii: "{"): return try parseObject(depth: depth)
        case UInt8(ascii: "["): return try parseArray(depth: depth)
        case UInt8(ascii: "\""): return .string(try parseString())
        case UInt8(ascii: "t"): try literal("true"); return .bool(true)
        case UInt8(ascii: "f"): try literal("false"); return .bool(false)
        case UInt8(ascii: "n"): try literal("null"); return .null
        case UInt8(ascii: "-"), UInt8(ascii: "0")...UInt8(ascii: "9"): return try parseNumber()
        default: throw fail("Unexpected character '\(Character(Unicode.Scalar(bytes[i])))'")
        }
    }

    mutating func literal(_ word: String) throws {
        for b in word.utf8 {
            guard i < bytes.count, bytes[i] == b else { throw fail("Unrecognized token") }
            i += 1
        }
    }

    mutating func parseObject(depth: Int) throws -> JSON {
        i += 1
        var object = JSONObject()
        skipWhitespace()
        if i < bytes.count, bytes[i] == UInt8(ascii: "}") { i += 1; return .object(object) }
        while true {
            skipWhitespace()
            guard i < bytes.count, bytes[i] == UInt8(ascii: "\"") else { throw fail("Expected a field name") }
            let key = try parseString()
            skipWhitespace()
            guard i < bytes.count, bytes[i] == UInt8(ascii: ":") else { throw fail("Expected ':'") }
            i += 1
            object[key] = try parseValue(depth: depth + 1)
            skipWhitespace()
            guard i < bytes.count else { throw fail("Unexpected end-of-input in an object") }
            if bytes[i] == UInt8(ascii: ",") { i += 1; continue }
            if bytes[i] == UInt8(ascii: "}") { i += 1; return .object(object) }
            throw fail("Expected ',' or '}'")
        }
    }

    mutating func parseArray(depth: Int) throws -> JSON {
        i += 1
        var array: [JSON] = []
        skipWhitespace()
        if i < bytes.count, bytes[i] == UInt8(ascii: "]") { i += 1; return .array(array) }
        while true {
            array.append(try parseValue(depth: depth + 1))
            skipWhitespace()
            guard i < bytes.count else { throw fail("Unexpected end-of-input in an array") }
            if bytes[i] == UInt8(ascii: ",") { i += 1; continue }
            if bytes[i] == UInt8(ascii: "]") { i += 1; return .array(array) }
            throw fail("Expected ',' or ']'")
        }
    }

    mutating func parseString() throws -> String {
        i += 1
        var utf8: [UInt8] = []
        var pendingHigh: UInt16?
        func flushHigh(_ out: inout [UInt8]) {
            if pendingHigh != nil { out += Array("\u{FFFD}".utf8); pendingHigh = nil }
        }
        while true {
            guard i < bytes.count else { throw fail("Unexpected end-of-input in a string") }
            let b = bytes[i]
            if b == UInt8(ascii: "\"") { i += 1; break }
            if b == UInt8(ascii: "\\") {
                i += 1
                guard i < bytes.count else { throw fail("Unexpected end-of-input in an escape") }
                let e = bytes[i]
                i += 1
                if e == UInt8(ascii: "u") {
                    guard i + 4 <= bytes.count, let unit = UInt16(String(decoding: bytes[i..<i + 4], as: UTF8.self), radix: 16)
                    else { throw fail("Bad unicode escape") }
                    i += 4
                    if (0xD800...0xDBFF).contains(unit) {
                        flushHigh(&utf8)
                        pendingHigh = unit
                    } else if (0xDC00...0xDFFF).contains(unit), let high = pendingHigh {
                        let scalar = 0x10000 + ((UInt32(high) - 0xD800) << 10) + (UInt32(unit) - 0xDC00)
                        utf8 += Array(String(Unicode.Scalar(scalar)!).utf8)
                        pendingHigh = nil
                    } else {
                        flushHigh(&utf8)
                        utf8 += Array(String(Unicode.Scalar(UInt32(unit)) ?? "\u{FFFD}").utf8)
                    }
                    continue
                }
                flushHigh(&utf8)
                switch e {
                case UInt8(ascii: "\""): utf8.append(0x22)
                case UInt8(ascii: "\\"): utf8.append(0x5C)
                case UInt8(ascii: "/"): utf8.append(0x2F)
                case UInt8(ascii: "b"): utf8.append(0x08)
                case UInt8(ascii: "f"): utf8.append(0x0C)
                case UInt8(ascii: "n"): utf8.append(0x0A)
                case UInt8(ascii: "r"): utf8.append(0x0D)
                case UInt8(ascii: "t"): utf8.append(0x09)
                default: throw fail("Unrecognized character escape")
                }
                continue
            }
            if b < 0x20 { throw fail("Illegal unquoted character in a string") }
            flushHigh(&utf8)
            utf8.append(b)
            i += 1
        }
        flushHigh(&utf8)
        return String(decoding: utf8, as: UTF8.self)
    }

    mutating func parseNumber() throws -> JSON {
        let start = i
        var isFraction = false
        if bytes[i] == UInt8(ascii: "-") { i += 1 }
        while i < bytes.count {
            let b = bytes[i]
            if b >= UInt8(ascii: "0") && b <= UInt8(ascii: "9") { i += 1; continue }
            if b == UInt8(ascii: ".") || b == UInt8(ascii: "e") || b == UInt8(ascii: "E")
                || b == UInt8(ascii: "+") || b == UInt8(ascii: "-") {
                isFraction = true
                i += 1
                continue
            }
            break
        }
        let text = String(decoding: bytes[start..<i], as: UTF8.self)
        if !isFraction, let v = Int64(text) { return .int(v) }
        guard let d = Double(text) else { throw fail("Malformed number") }
        return .double(d)
    }
}

/// The helpers every side uses (Java `Json`).
public enum Json {
    public static func object() -> JSONObject { JSONObject() }

    public static func parse(_ utf8: [UInt8]) throws -> JSON { try JSON.parse(utf8) }

    public static func bytes(_ object: JSONObject) -> [UInt8] { JSON.object(object).bytes }

    /// `{"ok":true}` with room for more fields.
    public static func ok() -> JSONObject { object().with(MuxProtocol.F_OK, true) }

    public static func error(_ message: String) -> JSONObject {
        object().with(MuxProtocol.F_OK, false).with(MuxProtocol.F_ERROR, message)
    }
}
