/**
 * Decides which tokens are *not* forwarded to attached clients because the server's own
 * emulator answers (or deliberately ignores) them: exactly the queries `TerminalEmulator`
 * answers in its `.basic` scope, which `HeadlessTerminal` uses. (The set was first drawn from
 * jediterm-core's `JediEmulator` dispatch, which the daemon used before, and is kept so that
 * what clients receive does not change.) A client emulator would otherwise answer too —
 * duplicate replies with two clients attached, and no reply at all when no client is attached,
 * which is precisely the state right after `new` + `send-keys` when a harness starts and
 * probes its terminal.
 *
 *  - DA1 — CSI, final `c`, no private marker or intermediate, first parameter absent or 0
 *    (`CSI c`, `CSI 0 c`): stripped. `CSI ? Ps c` (the Linux console's cursor shape, not a
 *    query) and `CSI = c` pass through — nobody answers them.
 *  - DA2 — CSI, `>` prefix, final `c`, first parameter absent or 0: stripped. `CSI > 1 c`
 *    passes through — nobody answers it.
 *  - DSR/CPR — CSI, final `n`, no `?` prefix, first parameter 5 or 6: stripped. `CSI ? 6 n`
 *    (DECXCPR) passes through.
 *  - XTWINOPS 8 — `CSI 8 ; … t`: stripped; the emulator ignores it too (it would resize the
 *    emulator but not the PTY). The server's own size announcements are injected after this
 *    filter.
 *  - `CSI ? 996 n` — colour-scheme preference: **passed through**; only a client knows its
 *    theme, and the server never answers it.
 *  - OSC 10/11 `?`, DECRQM, XTVERSION, kitty keyboard, XTGETTCAP (which the server also
 *    answers "invalid", as before), everything else: passed through, so behaviour matches a
 *    direct attach.
 *
 * Keep this and the emulator's basic reply scope in lock-step (TerminalEmulatorTest checks
 * it): a query the emulator answers but this filter forwards is a duplicate-reply bug; a query
 * this filter strips but nobody answers is a hang for the program that asked.
 *
 * Works on the token bytes directly (a CSI body is ASCII, so this is the Java string logic).
 */
public enum QueryFilter {

    /** True when `token` must not be forwarded to clients. */
    public static func isServerAnswered(_ token: VtToken) -> Bool {
        if token.kind != .csi {
            return false
        }
        let b = token.bytes
        // The body is b[2 ..< count-1].
        let bodyStart = 2
        let bodyEnd = max(2, b.count - 1)
        // The final byte first: only c / n / t can be stripped, so no other CSI pays for
        // decoding its body.
        switch token.csiFinalByte() {
        case UInt8(ascii: "c"):
            if bodyStart < bodyEnd && b[bodyStart] == UInt8(ascii: ">") {
                // DA2: strip only when the first parameter is absent or 0.
                return leadingInt(b, bodyStart + 1, bodyEnd) == 0
            }
            // DA1: no private marker or intermediate, first parameter absent or 0.
            // CSI ? Ps c (the Linux console's cursor) and CSI = c pass through.
            return plainParameters(b, bodyStart, bodyEnd) && leadingInt(b, bodyStart, bodyEnd) == 0
        case UInt8(ascii: "n"):
            if bodyStart < bodyEnd && b[bodyStart] == UInt8(ascii: "?") {
                // DECXCPR (CSI ? 6 n) and CSI ? 996 n pass through — not answered here.
                return false
            }
            // DSR/CPR: first parameter 5 or 6.
            let p = leadingInt(b, bodyStart, bodyEnd)
            return p == 5 || p == 6
        case UInt8(ascii: "t"):
            // XTWINOPS: strip the "resize text area" form (8) only.
            return leadingInt(b, bodyStart, bodyEnd) == 8
        default:
            return false
        }
    }

    /** Parse the run of decimal digits starting at `from`; 0 when there are none (also the
     * default for an absent first parameter). */
    private static func leadingInt(_ b: [UInt8], _ from: Int, _ to: Int) -> Int {
        var i = from
        var value = 0
        while i < to {
            let c = b[i]
            if c < 0x30 || c > 0x39 {
                break
            }
            value = min(value * 10 + Int(c - 0x30), 0xFFFF) // saturates, as the emulator's parser
            i += 1
        }
        return value
    }

    /** True when the body is digits and ';' only: the CSI the emulator dispatches without a
     * private marker, an intermediate or sub-parameters. */
    private static func plainParameters(_ b: [UInt8], _ from: Int, _ to: Int) -> Bool {
        var i = from
        while i < to {
            let c = b[i]
            if (c < 0x30 || c > 0x39) && c != UInt8(ascii: ";") {
                return false
            }
            i += 1
        }
        return true
    }
}
