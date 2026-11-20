import Foundation

/// Turns the server's in-band size announcements (`CSI 8 ; rows ; columns t`, sent when
/// another client resizes the session) into a notice for the console attach instead of
/// letting them reach the terminal, where an emulator that honours XTWINOPS would resize
/// the user's window. Sequences may arrive split across reads, so a candidate is held back
/// until it either completes or stops matching; anything that is not an announcement
/// passes through byte for byte.
final class SizeAnnouncementFilter {

    typealias Listener = (_ columns: Int, _ rows: Int) -> Void

    private static let ESC: UInt8 = 0x1b
    /// `ESC [ 8 ;` plus two numbers of up to five digits, `;` and `t`.
    private static let MAX_HOLD = 16

    private enum Match { case full, prefix, none }

    private let listener: Listener
    private var held: [UInt8] = []

    init(_ listener: @escaping Listener) {
        self.listener = listener
    }

    /// The bytes of `input` that should reach the terminal now.
    func filter(_ input: ArraySlice<UInt8>) -> [UInt8] {
        var out: [UInt8] = []
        out.reserveCapacity(input.count)
        for b in input {
            accept(b, &out)
        }
        return out
    }

    func filter(_ input: [UInt8]) -> [UInt8] { filter(input[...]) }

    /// Whatever is still held back at the end of the stream.
    func flush() -> [UInt8] {
        let rest = held
        held.removeAll()
        return rest
    }

    private func accept(_ b: UInt8, _ out: inout [UInt8]) {
        if held.isEmpty {
            if b == SizeAnnouncementFilter.ESC {
                held.append(b)
            } else {
                out.append(b)
            }
            return
        }
        held.append(b)
        let candidate = held
        switch SizeAnnouncementFilter.classify(candidate) {
        case .full:
            held.removeAll()
            announce(candidate)
        case .prefix:
            if held.count > SizeAnnouncementFilter.MAX_HOLD {
                out += flush()
            }
        case .none:
            // Give up on this candidate, but the byte that broke it may itself open a new
            // one — hand it back through the empty-held path.
            held.removeAll()
            out += candidate.dropLast()
            accept(b, &out)
        }
    }

    private func announce(_ sequence: [UInt8]) {
        let body = String(decoding: sequence[2..<(sequence.count - 1)], as: UTF8.self)
        let parts = body.split(separator: ";", omittingEmptySubsequences: false)
        listener(Int(parts[2]) ?? 0, Int(parts[1]) ?? 0)
    }

    private static func classify(_ c: [UInt8]) -> Match {
        var i = 0
        // Fixed head: ESC [ 8 ;
        let head: [UInt8] = [ESC, UInt8(ascii: "["), UInt8(ascii: "8"), UInt8(ascii: ";")]
        while i < c.count && i < head.count {
            if c[i] != head[i] { return .none }
            i += 1
        }
        if i < head.count { return .prefix }
        // rows ; columns t — each number at least one digit
        for field in 0..<2 {
            var digits = 0
            while i < c.count && c[i] >= UInt8(ascii: "0") && c[i] <= UInt8(ascii: "9") {
                i += 1
                digits += 1
            }
            if i == c.count { return .prefix }
            if digits == 0 { return .none }
            let expected = field == 0 ? UInt8(ascii: ";") : UInt8(ascii: "t")
            if c[i] != expected { return .none }
            i += 1
        }
        return i == c.count ? .full : .none
    }
}
