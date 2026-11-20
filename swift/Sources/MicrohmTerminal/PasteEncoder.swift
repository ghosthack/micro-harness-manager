import Foundation

/// Clipboard text → the bytes a paste sends. Line breaks become CR (what Enter sends), so a
/// multi-line paste into a shell or agent behaves like typing. With bracketed paste (DECSET
/// 2004) the text is wrapped in `ESC [200~ … ESC [201~`, and anything inside that could end
/// the bracket early or smuggle a control sequence — an embedded `ESC [201~`, any other ESC,
/// a C1 CSI — is removed first, so pasted text can never act as keystrokes.
public enum PasteEncoder {

    public static let start = "\u{1b}[200~"
    public static let end = "\u{1b}[201~"

    // Work on unicode scalars throughout: Swift's String treats "\r\n" as one Character,
    // so Character-level replacing would miss a CR or LF that is half of one.

    static func normalize(_ text: String) -> String {
        var out = String.UnicodeScalarView()
        var previousCR = false
        for s in text.unicodeScalars {
            if s == "\n" {
                if !previousCR {
                    out.append("\r")
                }
                previousCR = false
                continue
            }
            out.append(s)
            previousCR = s == "\r"
        }
        return String(out)
    }

    private static func removing(_ needle: String, from s: String) -> String {
        let n = Array(needle.unicodeScalars)
        let h = Array(s.unicodeScalars)
        var out = String.UnicodeScalarView()
        var i = 0
        while i < h.count {
            if i + n.count <= h.count && Array(h[i..<(i + n.count)]) == n {
                i += n.count
                continue
            }
            out.append(h[i])
            i += 1
        }
        return String(out)
    }

    static func sanitize(_ text: String) -> String {
        var s = text
        var previous: String
        repeat { // removing one marker may join the halves of another
            previous = s
            s = removing(start, from: removing(end, from: s))
        } while s.unicodeScalars.elementsEqual(previous.unicodeScalars) == false
        var out = String.UnicodeScalarView()
        for c in s.unicodeScalars where c != "\u{1b}" && c != "\u{9b}" {
            out.append(c)
        }
        return String(out)
    }

    public static func encode(_ text: String, bracketed: Bool) -> [UInt8] {
        let normalized = normalize(text)
        let out = bracketed ? start + sanitize(normalized) + end : normalized
        return Array(out.utf8)
    }
}
