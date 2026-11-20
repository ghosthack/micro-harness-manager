/**
 * One complete unit of a terminal output stream, as split by `VtTokenizer`. The bytes are the
 * exact original bytes, so concatenating a token sequence reproduces the input verbatim
 * (minus any incomplete tail the tokenizer is still holding).
 *
 * `alreadyForwarded` is non-zero only for STRING/OSC tokens whose body was streamed to
 * clients in fragments before the terminator arrived (see `VtTokenizer.Batch`): the broadcast
 * for this token is `bytes[alreadyForwarded...]`. The emulator and the mode tracker always get
 * the whole token.
 */
public struct VtToken: Equatable, Sendable {

    public enum Kind: Sendable, CustomStringConvertible {
        /** Printable text: one or more complete UTF-8 code points, no C0 controls. */
        case text
        /** A single C0 control byte (BEL, BS, HT, LF, CR, SO, SI, ...) other than ESC, or DEL. */
        case control
        /** `ESC [ params intermediates final` — final byte 0x40..0x7E. */
        case csi
        /** `ESC ] ... (BEL | ESC \)` — includes the terminator. */
        case osc
        /** `ESC P ... ESC \` (DCS), and likewise APC (`ESC _`), PM (`ESC ^`), SOS (`ESC X`) —
         * includes the terminator. */
        case string
        /** Any other `ESC x` sequence: two-byte escapes (ESC c, ESC 7, ESC =, ...) and the
         * intermediate forms (`ESC ( B`, `ESC # 8`). */
        case escape
        /** The rest of an OSC/STRING that outgrew `VtTokenizer.maxStringLength`, through its
         * terminator: bytes clients must still get (their own tokenizers are skipping the same
         * string) and that nothing interprets. */
        case discarded

        /** The Java constant name (TEXT, CONTROL, CSI, ...). */
        public var description: String {
            switch self {
            case .text: return "TEXT"
            case .control: return "CONTROL"
            case .csi: return "CSI"
            case .osc: return "OSC"
            case .string: return "STRING"
            case .escape: return "ESCAPE"
            case .discarded: return "DISCARDED"
            }
        }
    }

    public let kind: Kind
    public let bytes: [UInt8]
    public let alreadyForwarded: Int

    public init(_ kind: Kind, _ bytes: [UInt8], _ alreadyForwarded: Int = 0) {
        self.kind = kind
        self.bytes = bytes
        self.alreadyForwarded = alreadyForwarded
    }

    public init(kind: Kind, bytes: [UInt8], alreadyForwarded: Int = 0) {
        self.init(kind, bytes, alreadyForwarded)
    }

    public func asString() -> String {
        return String(decoding: bytes, as: UTF8.self)
    }

    /** The bytes not yet streamed to clients: all of them, except for a string token whose
     * body went out in fragments. */
    public func bytesToForward() -> [UInt8] {
        if alreadyForwarded == 0 {
            return bytes
        }
        return Array(bytes[alreadyForwarded...])
    }

    /** For CSI tokens: the parameter/intermediate bytes between `ESC [` and the final byte
     * (e.g. `"?996"` for `CSI ?996n`); empty for other kinds. */
    public func csiBody() -> String {
        if kind != .csi || bytes.count < 3 {
            return ""
        }
        return String(decoding: bytes[2..<(bytes.count - 1)], as: UTF8.self)
    }

    /** For CSI tokens: the final byte; NUL for other kinds. */
    public func csiFinal() -> Character {
        return kind == .csi ? Character(Unicode.Scalar(bytes[bytes.count - 1])) : "\0"
    }

    /** For CSI tokens: the final byte as a byte; 0 for other kinds. */
    public func csiFinalByte() -> UInt8 {
        return kind == .csi ? bytes[bytes.count - 1] : 0
    }
}
