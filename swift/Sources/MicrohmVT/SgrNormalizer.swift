/**
 * Rewrites SGR sequences that use colon sub-parameters into the semicolon form every terminal
 * understands. It was written for jediterm, which printed the ':' as text; the project's own
 * emulator reads sub-parameters, so the underline styles that have no semicolon form (curly,
 * dotted, dashed) now pass through.
 *
 * Applied to every CSI token with final byte `m` that contains ':'; all other tokens are
 * returned unchanged. Rules:
 *  - `38:2::r:g:b` and `38:2:r:g:b` → `38;2;r;g;b` (48 likewise);
 *  - `38:5:n` → `38;5;n` (48 likewise);
 *  - `4:0` → `24`; `4:2` → `21` (double); `4:3`, `4:4`, `4:5` (curly, dotted, dashed) kept;
 *    any other `4:n` → `4`;
 *  - `58:…`, `58;5;n`, `58;2;r;g;b` (underline colour) and `59` → dropped;
 *  - the arguments of a semicolon-form `38;5;n` / `38;2;r;g;b` (48 likewise) are copied
 *    untouched;
 *  - any other `p:q…` → `p` (sub-parameters dropped).
 *
 * The result is emitted to both the emulator and the clients, so the two stay identical.
 */
public enum SgrNormalizer {

    public static func normalize(_ token: VtToken) -> VtToken {
        if token.kind != .csi || token.csiFinalByte() != UInt8(ascii: "m") {
            return token
        }
        if !hasColon(token.bytes) {
            return token // no sub-parameters: nothing to rewrite
        }
        let body = token.csiBody()

        // SGR parameters are ';'-separated; each may carry ':'-separated sub-parameters.
        let groups = ModeTracker.split(body, ";")
        var rebuilt = ""
        var first = true
        var i = 0
        while i < groups.count {
            let group = groups[i]
            let replacement: String?
            let args = semicolonColorArgs(groups, i)
            if args > 0 {
                // 38;5;n / 38;2;r;g;b (48, 58 likewise): the arguments are values, not SGR codes
                // (a blue of 59 is not "default underline colour"), so copy them as is.
                var run = group
                for k in 1...args {
                    run += ";" + groups[i + k]
                }
                replacement = group == "58" ? nil : run
                i += args
            } else {
                replacement = transformGroup(group)
            }
            i += 1
            guard let r = replacement else {
                continue // dropped
            }
            if !first {
                rebuilt += ";"
            }
            rebuilt += r
            first = false
        }

        var out: [UInt8] = [0x1B, UInt8(ascii: "[")] // ESC [ <body> m
        out.append(contentsOf: rebuilt.utf8)
        out.append(UInt8(ascii: "m"))
        return VtToken(.csi, out)
    }

    /** True when the token bytes (`ESC [ body final`) hold a ':' in the body; checked on the
     * bytes so the common colon-free SGR allocates nothing. */
    private static func hasColon(_ bytes: [UInt8]) -> Bool {
        if bytes.count < 3 {
            return false
        }
        for i in 2..<(bytes.count - 1) where bytes[i] == UInt8(ascii: ":") {
            return true
        }
        return false
    }

    /** For a semicolon-form extended colour at `groups[i]` (`38`, `48` or `58` followed by `5`
     * or `2`), the number of groups after it that belong to it (clamped to what is there); 0
     * otherwise. */
    private static func semicolonColorArgs(_ groups: [String], _ i: Int) -> Int {
        let g = groups[i]
        if !(g == "38" || g == "48" || g == "58") || i + 1 >= groups.count {
            return 0
        }
        let args: Int
        switch groups[i + 1] {
        case "5": args = 2
        case "2": args = 4
        default: args = 0
        }
        return min(args, groups.count - 1 - i)
    }

    /** The rewritten group, or nil when it is dropped entirely. */
    private static func transformGroup(_ group: String) -> String? {
        if !group.contains(":") {
            // No sub-parameters. Only 59 (default underline colour) is dropped here.
            return group == "59" ? nil : group
        }
        let parts = ModeTracker.split(group, ":")
        let p0 = parts[0]
        switch p0 {
        case "38", "48":
            let cs = parts.count > 1 ? parts[1] : ""
            if cs == "2" {
                // 38:2::r:g:b (with an empty colour-space id) or 38:2:r:g:b — r,g,b are last three.
                let n = parts.count
                if n >= 3 {
                    return p0 + ";2;" + parts[n - 3] + ";" + parts[n - 2] + ";" + parts[n - 1]
                }
                return p0
            } else if cs == "5" {
                return p0 + ";5;" + parts[parts.count - 1]
            }
            return p0 // unknown colour space: drop sub-parameters
        case "4":
            let sub = parts.count > 1 ? parts[1] : ""
            switch sub {
            case "0": return "24"
            case "2": return "21"
            // curly, dotted, dashed have no semicolon form; TerminalEmulator reads the colon
            // form, and a terminal attached through the CLI that does not draws a plain
            // underline
            case "3", "4", "5": return "4:" + sub
            default: return "4"
            }
        case "58":
            return nil // underline colour: dropped
        default:
            return p0 // any other p:q… → p
        }
    }
}
