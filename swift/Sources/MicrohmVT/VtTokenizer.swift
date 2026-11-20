import Foundation

/**
 * Boundary-preserving splitter for a terminal output byte stream. Feed arbitrary chunks; get
 * back the complete tokens they finish, in order, plus the fragment of any string body still
 * open — so clients can be streamed immediately while the emulator only ever sees complete
 * sequences.
 *
 * Invariants:
 *  - Every byte ≥ 0x80 is text. No 8-bit C1 recognition.
 *  - Sequences start only with ESC. `ESC [` → CSI (parameters 0x30–0x3F, intermediates
 *    0x20–0x2F, final 0x40–0x7E); `ESC ]` → OSC; `ESC P`, `ESC _`, `ESC ^`, `ESC X` → STRING;
 *    both terminated by BEL or `ESC \` (an ESC inside a body not followed by `\` stays in the
 *    body); `ESC` + intermediate(s) 0x20–0x2F + final 0x30–0x7E, or `ESC` + one final
 *    0x30–0x7E → ESCAPE. An ESC followed by a byte that fits none of those (CAN, SUB, a C0,
 *    another ESC) ends the aborted sequence as an ESCAPE token and the new byte is processed
 *    fresh.
 *  - A C0 control other than ESC (and DEL) is its own CONTROL token, even mid-text.
 *  - Held back until complete: a lone trailing ESC, a partial CSI, a partial ESC-intermediate
 *    sequence, a partial UTF-8 code point. A CSI longer than 64 bytes without a final byte is
 *    flushed as TEXT and the parser resets.
 *  - String bodies are *not* held back from clients: the bytes of an open OSC/STRING that
 *    arrived in this chunk are returned as `Batch.openStringFragment` to be broadcast now; when
 *    the terminator arrives the whole token is returned with `VtToken.alreadyForwarded` set to
 *    the number of bytes already streamed. A string that outgrows 64 KiB is never returned as
 *    an OSC/STRING token: from that byte on (the same byte however the input is chunked) the
 *    body is skipped up to its terminator, still streamed to clients as fragments, the last
 *    piece as a `.discarded` token. The parser does not go back to text mid-body, which would
 *    print the rest of a large image or clipboard payload.
 *  - Concatenating, for each batch, every token's `bytesToForward()` followed by
 *    `openStringFragment`, reproduces the input byte-for-byte, minus tokens the caller chooses
 *    to drop and minus any still-held partial CSI/ESC/UTF-8 tail.
 *
 * Single-threaded: one owner feeds it.
 */
public final class VtTokenizer {

    public static let maxCsiLength = 64
    public static let maxStringLength = 64 * 1024
    /** Java-named aliases. */
    public static let MAX_CSI_LENGTH = maxCsiLength
    public static let MAX_STRING_LENGTH = maxStringLength

    private static let ESC: UInt8 = 0x1B
    private static let BEL: UInt8 = 0x07

    private enum State {
        /** Between tokens; `text` may hold a run of printable bytes. */
        case ground
        /** Saw ESC; deciding what kind of sequence follows. `seq` = {ESC}. */
        case afterEsc
        /** In a CSI (`ESC [ ...`); `seq` accumulates through the final byte. */
        case inCsi
        /** In an `ESC` + intermediate(s) sequence; `seq` accumulates. */
        case inEscInter
        /** In an OSC/DCS/APC/PM/SOS body; `stringBuf` accumulates (already forwarded). */
        case inString
        /** In a string that outgrew `maxStringLength`, skipping to its terminator;
         * `stringBuf` holds only the bytes not yet forwarded. */
        case discardString
    }

    /** What one `feed` produced: the tokens completed by the chunk, in order, and the bytes of
     * a still-open string body that arrived in this chunk (after the last token; empty when no
     * string is open). */
    public struct Batch: Sendable {
        public let tokens: [VtToken]
        public let openStringFragment: [UInt8]

        public init(_ tokens: [VtToken], _ openStringFragment: [UInt8]) {
            self.tokens = tokens
            self.openStringFragment = openStringFragment
        }
    }

    /**
     * Receives tokens as they complete, without a `VtToken` or a copy per token: the client
     * emulator's path. The buffer holds the token's exact bytes and is valid only during the
     * call (it is the caller's chunk or the tokenizer's own buffer). A CONTROL token is its
     * one byte.
     */
    public typealias Sink = (VtToken.Kind, UnsafeBufferPointer<UInt8>) -> Void

    /** One shared token per C0 control and DEL: they carry no state. */
    private static let CONTROLS: [VtToken] = (0..<0x80).map { VtToken(.control, [UInt8($0)]) }

    private var state = State.ground

    /** Printable bytes accumulated in GROUND, flushed as a TEXT token at the next boundary. */
    private let text = Bytes(256)
    /** The bytes of the escape/CSI sequence being parsed (starts with ESC). */
    private let seq = Bytes(VtTokenizer.maxCsiLength + 1)
    /** The bytes of the open string (introducer included). */
    private let stringBuf = Bytes(256)
    /** OSC vs generic STRING, decided by the introducer byte. */
    private var stringIsOsc = false
    /** Bytes of `stringBuf` already returned to clients via openStringFragment. */
    private var stringForwarded = 0
    /** True when the previous string byte was ESC (a potential `ESC \` terminator). */
    private var stringSawEsc = false

    /** Where tokens go during a feed: collected (the Batch path) or handed to a sink. */
    private var collected: [VtToken]? = nil
    private var sink: Sink? = nil

    public init() {
    }

    public func feed(_ chunk: [UInt8], _ off: Int, _ len: Int) -> Batch {
        return chunk.withUnsafeBufferPointer { p in
            feed(UnsafeBufferPointer(rebasing: p[off..<(off + len)]))
        }
    }

    public func feed(_ chunk: [UInt8]) -> Batch {
        return chunk.withUnsafeBufferPointer { feed($0) }
    }

    public func feed(_ chunk: UnsafeBufferPointer<UInt8>) -> Batch {
        collected = []
        collected!.reserveCapacity(16)
        run(chunk)
        let tokens = collected!
        collected = nil
        return Batch(tokens, endOfFeed(true))
    }

    /**
     * Feeds a chunk, handing each completed token to `sink` in order. Same parsing as
     * `feed(_:_:_:)`, but nothing is collected or copied, and no open-string fragment is
     * computed (a client has no one to forward it to).
     */
    public func feed(_ chunk: [UInt8], _ off: Int, _ len: Int, _ sink: Sink) {
        chunk.withUnsafeBufferPointer { p in
            feed(UnsafeBufferPointer(rebasing: p[off..<(off + len)]), sink)
        }
    }

    public func feed(_ chunk: UnsafeBufferPointer<UInt8>, _ sink: Sink) {
        withoutActuallyEscaping(sink) { s in
            self.sink = s
            run(chunk)
            self.sink = nil
        }
        _ = endOfFeed(false)
    }

    /** Hands a token `b[off, off + len)` to the collector or the sink. */
    @inline(__always)
    private func out(_ kind: VtToken.Kind, _ b: UnsafePointer<UInt8>, _ off: Int, _ len: Int) {
        if let sink = sink {
            sink(kind, UnsafeBufferPointer(start: b + off, count: len))
            return
        }
        let token: VtToken
        switch kind {
        case .control:
            token = VtTokenizer.CONTROLS[Int(b[off])]
        case .osc, .string:
            token = VtToken(kind, Array(UnsafeBufferPointer(start: b + off, count: len)), stringForwarded)
        default:
            token = VtToken(kind, Array(UnsafeBufferPointer(start: b + off, count: len)))
        }
        collected!.append(token)
    }

    private var collecting: Bool {
        return sink == nil
    }

    private func run(_ chunkBuf: UnsafeBufferPointer<UInt8>) {
        guard let chunk = chunkBuf.baseAddress, chunkBuf.count > 0 else {
            if state == .ground {
                flushText()
            }
            return
        }
        let end = chunkBuf.count
        var i = 0
        while i < end {
            let b = chunk[i]
            switch state {
            case .ground:
                if b == VtTokenizer.ESC {
                    flushText()
                    seq.reset()
                    seq.write(VtTokenizer.ESC)
                    state = .afterEsc
                } else if b < 0x20 || b == 0x7F {
                    // C0 control (other than ESC, handled above) or DEL: its own token.
                    flushText()
                    out(.control, chunk, i, 1)
                } else {
                    // A run of printable bytes (every byte >= 0x80 is text). It ends at a
                    // boundary or at the end of the chunk, where the text is flushed anyway,
                    // so flush it now: straight from the chunk when nothing is held (the
                    // usual case), holding back an incomplete UTF-8 tail.
                    var runEnd = i + 1
                    while runEnd < end && VtTokenizer.isPrintable(chunk[runEnd]) {
                        runEnd += 1
                    }
                    if text.size == 0 {
                        let tail = VtTokenizer.incompleteUtf8TailLength(chunk, i, runEnd)
                        if runEnd - tail > i {
                            out(.text, chunk, i, runEnd - tail - i)
                        }
                        if tail > 0 {
                            text.write(chunk + runEnd - tail, tail)
                        }
                    } else {
                        text.write(chunk + i, runEnd - i)
                        flushText()
                    }
                    i = runEnd - 1
                }
            case .afterEsc:
                if b == UInt8(ascii: "[") {
                    seq.write(b)
                    state = .inCsi
                } else if b == UInt8(ascii: "]") || b == UInt8(ascii: "P") || b == UInt8(ascii: "_")
                            || b == UInt8(ascii: "^") || b == UInt8(ascii: "X") {
                    // OSC (]) / DCS (P) / APC (_) / PM (^) / SOS (X).
                    stringBuf.reset()
                    stringBuf.write(VtTokenizer.ESC)
                    stringBuf.write(b)
                    stringIsOsc = b == UInt8(ascii: "]")
                    stringForwarded = 0
                    stringSawEsc = false
                    state = .inString
                } else if b >= 0x20 && b <= 0x2F {
                    seq.write(b)
                    state = .inEscInter
                } else if b >= 0x30 && b <= 0x7E {
                    seq.write(b)
                    out(.escape, seq.buf, 0, seq.size)
                    state = .ground
                } else {
                    // Aborted: emit the lone ESC as ESCAPE and reprocess this byte fresh.
                    out(.escape, seq.buf, 0, seq.size)
                    state = .ground
                    i -= 1 // reprocess b in GROUND
                }
            case .inCsi:
                if b >= 0x40 && b <= 0x7E {
                    seq.write(b)
                    out(.csi, seq.buf, 0, seq.size)
                    state = .ground
                } else if seq.size >= VtTokenizer.maxCsiLength {
                    // Overlong CSI without a final byte: flush as TEXT, reprocess b fresh.
                    appendSeqAsText()
                    state = .ground
                    i -= 1
                } else if b >= 0x20 && b <= 0x3F {
                    seq.write(b) // parameter (0x30-0x3F) or intermediate (0x20-0x2F)
                } else {
                    // Unexpected byte inside CSI: abort to TEXT, reprocess b fresh.
                    appendSeqAsText()
                    state = .ground
                    i -= 1
                }
            case .inEscInter:
                if b >= 0x20 && b <= 0x2F {
                    seq.write(b) // another intermediate
                } else if b >= 0x30 && b <= 0x7E {
                    seq.write(b)
                    out(.escape, seq.buf, 0, seq.size)
                    state = .ground
                } else {
                    // Aborted intermediate sequence: emit what we have, reprocess b fresh.
                    out(.escape, seq.buf, 0, seq.size)
                    state = .ground
                    i -= 1
                }
            case .inString:
                // Fast path: copy the run of ordinary body bytes in one go.
                if !stringSawEsc && b != VtTokenizer.BEL && b != VtTokenizer.ESC {
                    let room = VtTokenizer.maxStringLength + 1 - stringBuf.size
                    var runEnd = i + 1
                    let limit = min(end, i + max(1, room))
                    while runEnd < limit {
                        let c = chunk[runEnd]
                        if c == VtTokenizer.BEL || c == VtTokenizer.ESC {
                            break
                        }
                        runEnd += 1
                    }
                    stringBuf.write(chunk + i, runEnd - i)
                    i = runEnd - 1
                } else {
                    stringBuf.write(b)
                    if b == VtTokenizer.BEL {
                        emitString()
                        state = .ground
                    } else if stringSawEsc {
                        stringSawEsc = false
                        if b == UInt8(ascii: "\\") { // ESC \ = ST terminator
                            emitString()
                            state = .ground
                        } else if b == VtTokenizer.ESC {
                            stringSawEsc = true // the previous ESC stays in the body
                        }
                    } else if b == VtTokenizer.ESC {
                        stringSawEsc = true
                    }
                }
                if state == .inString && stringBuf.size > VtTokenizer.maxStringLength {
                    // Checked per byte, so where the body is given up does not depend on how
                    // the input was chunked: daemon and clients agree.
                    stringBuf.keepTail(stringBuf.size - stringForwarded)
                    stringForwarded = 0
                    state = .discardString
                }
            case .discardString:
                // The same terminators as IN_STRING: a client that attached mid-string is
                // still in that state, and must leave the string on the same byte.
                stringBuf.write(b)
                let terminated = b == VtTokenizer.BEL || (stringSawEsc && b == UInt8(ascii: "\\"))
                stringSawEsc = b == VtTokenizer.ESC
                if terminated {
                    emitDiscarded()
                    state = .ground
                }
            }
            i += 1
        }

        if state == .ground {
            // Emit the completed text of this feed, holding back an incomplete UTF-8 tail.
            flushText()
        }
    }

    /** After a chunk: the bytes of a still-open string that arrived in it (when
     * `wantFragment`), and the reset of an overlong one. */
    private func endOfFeed(_ wantFragment: Bool) -> [UInt8] {
        var fragment: [UInt8] = []
        if state == .inString || state == .discardString {
            let size = stringBuf.size
            if wantFragment && size > stringForwarded {
                fragment = stringBuf.copy(stringForwarded, size)
            }
            stringForwarded = size
            if state == .discardString {
                // Nothing will ask for these bytes again: keep the buffer at one chunk.
                stringBuf.reset()
                stringForwarded = 0
            }
        }
        return fragment
    }

    /** The whole body of the currently open OSC/STRING (introducer included), or empty:
     * attach sends this to a new client after the snapshot so it gets the sequence the other
     * clients are mid-way through. */
    public func openStringBytes() -> [UInt8] {
        if state == .discardString {
            // The body is gone; an SOS introducer makes the new client skip the rest of it as
            // a string too (plus the ESC that may be half of the terminator).
            return stringSawEsc ? [VtTokenizer.ESC, UInt8(ascii: "X"), VtTokenizer.ESC]
                : [VtTokenizer.ESC, UInt8(ascii: "X")]
        }
        return state == .inString ? stringBuf.toByteArray() : []
    }

    /** Bytes held back as an incomplete ESC/CSI/UTF-8 tail (never a string body); empty at a
     * boundary. For diagnostics and `flush`. */
    public func pending() -> [UInt8] {
        switch state {
        case .afterEsc, .inCsi, .inEscInter:
            return seq.toByteArray()
        case .ground:
            return incompleteUtf8Tail()
        case .inString, .discardString:
            return []
        }
    }

    /** End of stream: emits the held tail as ESCAPE/TEXT and any open string body as a
     * STRING/OSC token (with `alreadyForwarded` set), resetting the parser. */
    public func flush() -> Batch {
        collected = []
        switch state {
        case .ground:
            flushText()
        case .afterEsc, .inEscInter:
            out(.escape, seq.buf, 0, seq.size)
        case .inCsi:
            out(.text, seq.buf, 0, seq.size)
        case .inString:
            emitString()
        case .discardString:
            emitDiscarded()
        }
        let tokens = collected!
        collected = nil
        state = .ground
        text.reset()
        seq.reset()
        stringBuf.reset()
        stringForwarded = 0
        stringSawEsc = false
        return Batch(tokens, [])
    }

    /** Flush `text` as one or more TEXT tokens, holding back an incomplete trailing UTF-8 code
     * point for the next feed. */
    private func flushText() {
        let size = text.size
        if size == 0 {
            return
        }
        let tail = VtTokenizer.incompleteUtf8TailLength(text.buf, 0, size)
        if size - tail > 0 {
            out(.text, text.buf, 0, size - tail)
        }
        // Re-hold an incomplete code point at the front so the next feed can complete it.
        text.keepTail(tail)
    }

    private func appendSeqAsText() {
        // Prepend the aborted sequence to any pending text so byte order is preserved.
        text.prepend(seq.buf, seq.size)
    }

    private func emitString() {
        out(stringIsOsc ? .osc : .string, stringBuf.buf, 0, stringBuf.size) // reads stringForwarded
        stringBuf.reset()
        stringForwarded = 0
        stringSawEsc = false
    }

    /** The end of a skipped string: its bytes not yet streamed go out as a DISCARDED token, in
     * order before whatever follows. A sink has no one to forward to and gets nothing. */
    private func emitDiscarded() {
        if collecting && stringBuf.size > stringForwarded {
            out(.discarded, stringBuf.buf, stringForwarded, stringBuf.size - stringForwarded)
        }
        stringBuf.reset()
        stringForwarded = 0
        stringSawEsc = false
    }

    /** The trailing bytes of `text` that form an incomplete (completable) UTF-8 code point. */
    private func incompleteUtf8Tail() -> [UInt8] {
        let size = text.size
        let tail = VtTokenizer.incompleteUtf8TailLength(text.buf, 0, size)
        return tail == 0 ? [] : text.copy(size - tail, size)
    }

    /** Text in GROUND: anything but a C0 control, ESC or DEL (bytes >= 0x80 included). */
    @inline(__always)
    private static func isPrintable(_ b: UInt8) -> Bool {
        return b >= 0x20 && b != 0x7F
    }

    /**
     * Number of trailing bytes of `b[from, to)` that form an incomplete but still completable
     * UTF-8 sequence (a lead byte with fewer continuation bytes than it needs). Stray
     * continuation bytes with no lead, and already-complete sequences, are not held.
     */
    static func incompleteUtf8TailLength(_ b: UnsafePointer<UInt8>, _ from: Int, _ to: Int) -> Int {
        var i = to - 1
        var cont = 0
        while i >= from && (b[i] & 0xC0) == 0x80 && cont < 3 {
            i -= 1
            cont += 1
        }
        if i < from {
            return 0 // only continuation bytes in view: not completable
        }
        let lead = b[i]
        let need: Int
        if lead < 0x80 {
            return 0 // ASCII lead, the trailing continuations are stray
        } else if (lead & 0xE0) == 0xC0 {
            need = 1
        } else if (lead & 0xF0) == 0xE0 {
            need = 2
        } else if (lead & 0xF8) == 0xF0 {
            need = 3
        } else {
            return 0 // stray continuation acting as lead, or invalid 0xF8+ byte
        }
        if cont >= need {
            return 0 // complete (or overlong) sequence: nothing to hold
        }
        return cont + 1 // lead byte plus the continuations seen so far
    }

    /** `incompleteUtf8TailLength` over a whole array. */
    static func incompleteUtf8TailLength(_ b: [UInt8], _ len: Int) -> Int {
        return b.withUnsafeBufferPointer { p in
            guard let base = p.baseAddress else { return 0 }
            return incompleteUtf8TailLength(base, 0, len)
        }
    }

    /** A growable byte buffer on raw memory: the tokenizer writes to these on every byte. */
    private final class Bytes {
        var buf: UnsafeMutablePointer<UInt8>
        var capacity: Int
        var size = 0

        init(_ capacity: Int) {
            self.capacity = capacity
            buf = UnsafeMutablePointer<UInt8>.allocate(capacity: capacity)
        }

        deinit {
            buf.deallocate()
        }

        @inline(__always) func reset() {
            size = 0
        }

        @inline(__always) func write(_ b: UInt8) {
            if size == capacity {
                grow(size + 1)
            }
            buf[size] = b
            size += 1
        }

        func write(_ src: UnsafePointer<UInt8>, _ len: Int) {
            if size + len > capacity {
                grow(size + len)
            }
            (buf + size).update(from: src, count: len)
            size += len
        }

        /** Inserts `src[0, len)` before the current contents. */
        func prepend(_ src: UnsafePointer<UInt8>, _ len: Int) {
            if size + len > capacity {
                grow(size + len)
            }
            memmove(buf + len, buf, size)
            (buf).update(from: src, count: len)
            size += len
        }

        /** Keeps only the last `tail` bytes, moved to the front. */
        func keepTail(_ tail: Int) {
            if tail > 0 && size - tail > 0 {
                memmove(buf, buf + size - tail, tail)
            }
            size = tail
        }

        func copy(_ from: Int, _ to: Int) -> [UInt8] {
            return Array(UnsafeBufferPointer(start: buf + from, count: to - from))
        }

        func toByteArray() -> [UInt8] {
            return copy(0, size)
        }

        private func grow(_ min: Int) {
            let newCapacity = Swift.max(min, capacity * 2)
            let next = UnsafeMutablePointer<UInt8>.allocate(capacity: newCapacity)
            next.update(from: buf, count: size)
            buf.deallocate()
            buf = next
            capacity = newCapacity
        }
    }
}
