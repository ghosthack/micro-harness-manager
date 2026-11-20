import Foundation

/// Server-side JSON shapes of the session records; the client's `JsonDecoding` is the
/// mirror image. Field names come from `MuxProtocol` so both sides agree, in the order the
/// Java server writes them.
enum JsonEncoding {

    static func info(_ info: SessionInfo) -> JSONObject {
        Json.object()
            .with(MuxProtocol.F_NAME, info.name)
            .with(MuxProtocol.F_WORKDIR, info.workdir.path)
            .with(MuxProtocol.F_COLUMNS, info.columns)
            .with(MuxProtocol.F_ROWS, info.rows)
            .with(MuxProtocol.F_PID, info.pid)
            .with(MuxProtocol.F_CREATED_AT, InstantFormat.format(info.createdAt))
            .with(MuxProtocol.F_CLIENTS, info.clients)
            .with(MuxProtocol.F_ALIVE, info.alive)
            .with(MuxProtocol.F_BACKEND, info.backend)
            .with(MuxProtocol.F_LABELS, .object(labels(info.labels)))
            .with(MuxProtocol.F_OUTPUT_BYTES, info.outputBytes)
    }

    /// Key-sorted, as the Java side's immutable `TreeMap` copy serialized.
    static func labels(_ labels: [String: String]) -> JSONObject {
        var node = Json.object()
        for (key, value) in sortedLabels(labels) {
            node[key] = .string(value)
        }
        return node
    }

    /// One `watch` stream entry.
    static func event(_ event: SessionEvent) -> JSONObject {
        var node = Json.ok()
            .with(MuxProtocol.F_EVENT, event.type)
            .with(MuxProtocol.F_NAME, event.name)
            .with(MuxProtocol.F_OUTPUT_BYTES, event.outputBytes)
        if let title = event.title {
            node[MuxProtocol.F_TITLE] = .string(title)
        }
        if let exitCode = event.exitCode {
            node[MuxProtocol.F_EXIT_CODE] = .int(Int64(exitCode))
        }
        return node
    }

    static func infos(_ sessions: [Session]) -> JSON {
        .array(sessions.map { .object(info($0.info())) })
    }

    static func capture(_ capture: SessionCapture, _ format: CaptureFormat) -> JSONObject {
        var reply = Json.ok()
            .with(MuxProtocol.F_TEXT, capture.text)
            .with(MuxProtocol.F_ALIVE, capture.alive)
            .with(MuxProtocol.F_FOREGROUND_COMMAND, capture.foregroundCommand)
            .with(MuxProtocol.F_PROCESS_ID, capture.processId)
            .with(MuxProtocol.F_TITLE, capture.title)
            .with(MuxProtocol.F_COLUMNS, capture.columns)
            .with(MuxProtocol.F_ROWS, capture.rows)
            .with(MuxProtocol.F_FORMAT, format.wireName)
            .with(MuxProtocol.F_OUTPUT_BYTES, capture.outputBytes)
            .with(MuxProtocol.F_CURSOR_VISIBLE, capture.cursorVisible)
        if let history = capture.history {
            reply[MuxProtocol.F_HISTORY_TEXT] = .string(history.text)
            reply[MuxProtocol.F_HISTORY_SIZE] = .int(Int64(history.held))
            reply[MuxProtocol.F_HISTORY_ADDED] = .int(history.added)
            reply[MuxProtocol.F_ALTERNATE_SCREEN] = .bool(history.alternateScreen)
        }
        return reply
    }

    /// An integer field with a default, tolerant of a missing or non-numeric value.
    static func intField(_ node: JSONObject, _ field: String, _ fallback: Int) -> Int {
        guard let value = node[field], value.canConvertToInt else { return fallback }
        return value.asInt()
    }

    /// A long field with a default, tolerant of a missing or non-numeric value.
    static func longField(_ node: JSONObject, _ field: String, _ fallback: Int64) -> Int64 {
        guard let value = node[field], value.canConvertToLong else { return fallback }
        return value.asLong()
    }

    /// A boolean field with a default; anything but a JSON boolean is the default.
    static func booleanField(_ node: JSONObject, _ field: String, _ fallback: Bool) -> Bool {
        guard case .bool(let b)? = node[field] else { return fallback }
        return b
    }

    static func textField(_ node: JSONObject, _ field: String) -> String? {
        node[field]?.stringValue
    }
}
