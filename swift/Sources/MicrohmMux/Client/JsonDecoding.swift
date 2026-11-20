import Foundation

/// Client-side decoding of the session records the server encodes; unknown fields are
/// ignored and missing ones get neutral defaults, as the protocol contract requires. A
/// missing `outputBytes` (in `list` and `capture`) decodes as -1 = unknown, the daemon
/// predates the counter: never equal to a real count by accident.
enum JsonDecoding {

    static func infos(_ sessions: JSON?) -> [SessionInfo] {
        guard case .array(let array)? = sessions else { return [] }
        return array.compactMap { $0.objectValue.map(info) }
    }

    static func info(_ node: JSONObject) -> SessionInfo {
        SessionInfo(
            name: text(node, MuxProtocol.F_NAME),
            workdir: URL(fileURLWithPath: text(node, MuxProtocol.F_WORKDIR)),
            columns: path(node, MuxProtocol.F_COLUMNS).asInt(0),
            rows: path(node, MuxProtocol.F_ROWS).asInt(0),
            pid: path(node, MuxProtocol.F_PID).asLong(0),
            createdAt: InstantFormat.parse(text(node, MuxProtocol.F_CREATED_AT)),
            clients: path(node, MuxProtocol.F_CLIENTS).asInt(0),
            alive: path(node, MuxProtocol.F_ALIVE).asBoolean(false),
            backend: text(node, MuxProtocol.F_BACKEND),
            labels: labels(node[MuxProtocol.F_LABELS]),
            outputBytes: outputBytes(node))
    }

    /// A labels object; anything else (an old server's missing field) is empty.
    static func labels(_ node: JSON?) -> [String: String] {
        var labels: [String: String] = [:]
        if case .object(let o)? = node {
            for (key, value) in o.fields {
                if case .string(let s) = value { labels[key] = s }
            }
        }
        return labels
    }

    static func event(_ node: JSONObject) -> SessionEvent {
        let title = node[MuxProtocol.F_TITLE]
        let exitCode = node[MuxProtocol.F_EXIT_CODE]
        return SessionEvent(
            name: text(node, MuxProtocol.F_NAME),
            type: text(node, MuxProtocol.F_EVENT),
            outputBytes: path(node, MuxProtocol.F_OUTPUT_BYTES).asLong(0),
            title: title?.stringValue,
            exitCode: exitCode.flatMap { $0.canConvertToInt ? Int32($0.asInt()) : nil })
    }

    static func capture(_ node: JSONObject) -> SessionCapture {
        SessionCapture(
            text: text(node, MuxProtocol.F_TEXT),
            alive: path(node, MuxProtocol.F_ALIVE).asBoolean(false),
            foregroundCommand: text(node, MuxProtocol.F_FOREGROUND_COMMAND),
            processId: path(node, MuxProtocol.F_PROCESS_ID).asLong(0),
            title: text(node, MuxProtocol.F_TITLE),
            columns: path(node, MuxProtocol.F_COLUMNS).asInt(0),
            rows: path(node, MuxProtocol.F_ROWS).asInt(0),
            outputBytes: outputBytes(node),
            cursorVisible: path(node, MuxProtocol.F_CURSOR_VISIBLE).asBoolean(true),
            history: node.has(MuxProtocol.F_HISTORY_SIZE) ? CaptureHistory(
                text: text(node, MuxProtocol.F_HISTORY_TEXT),
                held: path(node, MuxProtocol.F_HISTORY_SIZE).asInt(0),
                added: path(node, MuxProtocol.F_HISTORY_ADDED).asLong(0),
                alternateScreen: path(node, MuxProtocol.F_ALTERNATE_SCREEN).asBoolean(false)) : nil)
    }

    /// The byte counter, or -1 = unknown: the daemon predates the counter.
    static func outputBytes(_ node: JSONObject) -> Int64 {
        if let value = node[MuxProtocol.F_OUTPUT_BYTES], value.canConvertToLong { return value.asLong() }
        return -1
    }

    /// Jackson `path(field)`: the value, or a "missing" node whose `as*` give the default.
    static func path(_ node: JSONObject, _ field: String) -> JSON {
        node[field] ?? .null
    }

    /// Jackson `asText()` of a present, non-null field; "" otherwise.
    static func text(_ node: JSONObject, _ field: String) -> String {
        guard let value = node[field], !value.isNull else { return "" }
        return value.asText()
    }
}

