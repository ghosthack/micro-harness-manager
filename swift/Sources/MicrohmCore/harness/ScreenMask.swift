import Foundation

/// The shared mechanics behind `HarnessPlugin.maskChrome`: line splitting, the
/// annotated-capture markers, and blank-run collapsing, so each plugin only states which
/// lines are its chrome.
///
/// Annotated captures (the daemon's `capture --format annotated`) prefix a highlighted
/// row with `"▶ "` and insert `"▮"` at the cursor. Chrome tests see each line without
/// either, because the plugins' patterns are anchored at the line start and a cursor
/// parked in the composer must not hide it; the output keeps the selection prefix (a
/// moved selection is a real change) and drops the cursor marker.
enum ScreenMask {

    /// The daemon's selection-row prefix (`HeadlessTerminal.SELECTION_MARKER`).
    static let selectionMarker = "▶ "

    /// The daemon's cursor marker (`HeadlessTerminal.CURSOR_MARKER`).
    static let cursorMarker = "▮"

    /// The screen's lines, cursor marker removed, with no trailing empty element.
    static func lines(_ screenText: String) -> [String] {
        let text = screenText.replacingOccurrences(of: cursorMarker, with: "")
        var lines = JavaText.splitKeepingEmpty(text, on: "\n")
        if let last = lines.last, last.isEmpty {
            lines.removeLast()
        }
        return lines
    }

    /// `line` as the plugins' chrome patterns expect it: no selection prefix.
    static func plain(_ line: String) -> String {
        JavaText.hasPrefix(line, selectionMarker) ? JavaText.dropPrefix(line, selectionMarker) : line
    }

    /// Drops every line whose plain form `chrome` accepts, then joins the rest.
    static func mask(_ screenText: String, _ chrome: (String) -> Bool) -> String {
        join(lines(screenText).filter { !chrome(plain($0)) })
    }

    /// Joins with `"\n"`, trailing whitespace stripped, runs of blank lines collapsed to
    /// one, and no blank line at either end.
    static func join<S: Sequence>(_ lines: S) -> String where S.Element == String {
        var out = ""
        var pendingBlank = false
        for line in lines {
            let trimmed = JavaText.stripTrailing(line)
            if JavaText.isBlank(trimmed) {
                pendingBlank = !out.isEmpty
                continue
            }
            if !out.isEmpty {
                out += pendingBlank ? "\n\n" : "\n"
            }
            out += trimmed
            pendingBlank = false
        }
        return out
    }

    /// Index of the last non-blank line at or before `from`, or -1.
    static func lastNonBlank(_ lines: [String], _ from: Int) -> Int {
        var i = min(from, lines.count - 1)
        while i >= 0 {
            if !JavaText.isBlank(plain(lines[i])) {
                return i
            }
            i -= 1
        }
        return -1
    }

    /// `command` with `flags` inserted right after its leading `program` token, or
    /// unchanged when the command does not start with that token — the shape every
    /// per-run MCP injection takes, since the flags are global options that must precede
    /// any subcommand or resume selector.
    static func insertAfterProgram(_ command: String, _ program: String, _ flags: String) -> String {
        if command == program {
            return program + " " + flags
        }
        if JavaText.hasPrefix(command, program + " ") {
            return program + " " + flags + JavaText.dropPrefix(command, program)
        }
        return command
    }

    /// `value` as a JSON (and TOML basic) string literal, quotes included.
    static func quoted(_ value: String) -> String {
        var out = "\""
        for scalar in value.unicodeScalars {
            switch scalar {
            case "\"": out += "\\\""
            case "\\": out += "\\\\"
            default:
                if scalar.value < 0x20 {
                    out += String(format: "\\u%04x", Int(scalar.value))
                } else {
                    out.unicodeScalars.append(scalar)
                }
            }
        }
        return out + "\""
    }
}
