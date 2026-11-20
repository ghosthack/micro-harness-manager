/// Wire-level constants shared by server, client and CLI (Java `Protocol`; renamed because
/// `Protocol` is a Swift keyword-ish name). Request/response bodies are JSON objects; the
/// field names below are the whole vocabulary (see PROTOCOL.md).
///
/// Requests: `{"op": <OP_*>, "protocol": 1, ...args}`. Responses: `{"ok": true, ...}` or
/// `{"ok": false, "error": "<message>"}`.
public enum MuxProtocol {

    public static let VERSION = 1

    // ---- request fields
    public static let F_OP = "op"
    public static let F_PROTOCOL = "protocol"
    public static let F_NAME = "name"
    public static let F_WORKDIR = "workdir"
    public static let F_COLUMNS = "columns"
    public static let F_ROWS = "rows"
    public static let F_COMMAND = "command"
    public static let F_TEXT = "text"
    public static let F_ENTER = "enter"
    /// `new` / `label`: a string→string object; in `label` a null value removes the key.
    /// Also on every `list` entry.
    public static let F_LABELS = "labels"
    /// `new`: a string→string object of environment variables merged into the session's
    /// environment after the defaults (`TERM` and `MICROHM_SESSION` cannot be overridden).
    public static let F_ENV = "env"
    /// `input`: named keys (see `KeyNames`), pressed after `text`.
    public static let F_KEYS = "keys"
    /// `input`: send `text` as a paste (bracketed when the program asked).
    public static let F_PASTE = "paste"
    /// `input`: with `paste`, refuse (writing nothing) unless the program enabled bracketed
    /// paste (DEC 2004), instead of falling back to a raw paste.
    public static let F_REQUIRE_BRACKETED_PASTE = "requireBracketedPaste"
    /// `capture`: `text` | `annotated` | `ansi`; echoed in the response.
    public static let F_FORMAT = "format"
    /// `wait`: first wait for output past this byte count (-1 = don't).
    public static let F_SINCE_BYTES = "sinceBytes"
    /// `wait` / `watch`: how long without output counts as quiet.
    public static let F_QUIET_MS = "quietMs"
    /// `wait`: the overall bound.
    public static let F_TIMEOUT_MS = "timeoutMs"
    /// `watch`: the sessions to watch; absent or empty = all, including later ones.
    public static let F_NAMES = "names"

    // ---- response fields
    public static let F_OK = "ok"
    public static let F_ERROR = "error"
    public static let F_VERSION = "version"
    public static let F_PID = "pid"
    public static let F_SESSIONS = "sessions"
    public static let F_PRESENT = "present"
    public static let F_PATH = "path"
    public static let F_ALIVE = "alive"
    public static let F_FOREGROUND_COMMAND = "foregroundCommand"
    public static let F_PROCESS_ID = "processId"
    public static let F_TITLE = "title"
    public static let F_CLIENTS = "clients"
    public static let F_CREATED_AT = "createdAt"
    public static let F_EXIT_CODE = "exitCode"
    /// `unix` — the PTY backend a session got (kept for wire compatibility).
    public static let F_BACKEND = "backend"
    /// Raw PTY bytes the session has produced so far; monotonic.
    public static let F_OUTPUT_BYTES = "outputBytes"
    /// `capture`: whether the program shows its cursor.
    public static let F_CURSOR_VISIBLE = "cursorVisible"
    /// `capture` request: how many scrollback lines above the screen to include (0 or
    /// absent = none). A daemon that predates it ignores it, and its reply then has no
    /// `F_HISTORY_SIZE`: that absence is how a client tells.
    public static let F_HISTORY = "history"
    /// `capture` request, instead of `F_HISTORY`: the scrollback lines added after the first
    /// this many ever added (a previous reply's `F_HISTORY_ADDED`), those still held.
    public static let F_HISTORY_SINCE = "historySince"
    /// `capture` reply, when history was asked for: the scrollback lines, oldest first, in
    /// the `text` format's shape (each ends with a newline).
    public static let F_HISTORY_TEXT = "historyText"
    /// `capture` reply, when history was asked for: the lines of scrollback held in all.
    public static let F_HISTORY_SIZE = "historySize"
    /// `capture` reply, when history was asked for: the lines ever added (monotonic).
    public static let F_HISTORY_ADDED = "historyAdded"
    /// `capture` reply, when history was asked for: whether a full-screen program shows
    /// the alternate screen (which keeps no scrollback).
    public static let F_ALTERNATE_SCREEN = "alternateScreen"
    /// `wait`: true when the output went quiet, false on timeout.
    public static let F_QUIET = "quiet"
    /// A `watch` stream entry: one of the `EVENT_*` names.
    public static let F_EVENT = "event"

    // ---- watch event names (F_EVENT)
    /// The session became active: the first output after a quiet period (or the watch start).
    public static let EVENT_OUTPUT = "output"
    /// No output for the watch's `quietMs` after activity.
    public static let EVENT_QUIET = "quiet"
    /// The OSC 0/2 title changed; carries `title`.
    public static let EVENT_TITLE = "title"
    /// The program rang the bell (a BEL outside any string sequence).
    public static let EVENT_BELL = "bell"
    /// The session's process ended; carries `exitCode`.
    public static let EVENT_EXIT = "exit"

    /// The `error` text a server sends when a request's `protocol` differs from its own;
    /// the response also carries `protocol`, `version` and `pid`.
    public static let ERROR_PROTOCOL_MISMATCH = "protocol mismatch"
    /// `input` with `paste` and `requireBracketedPaste` while the program has not enabled
    /// bracketed paste (nothing was written).
    public static let ERROR_BRACKETED_PASTE_DISABLED = "bracketed paste is not enabled in the session"

    // ---- operations
    /// → {ok, protocol, version, pid}.
    public static let OP_PING = "ping"
    /// → {ok, sessions: [{name, workdir, columns, rows, pid, createdAt, clients, alive,
    /// backend, labels, outputBytes}]}.
    public static let OP_LIST = "list"
    /// {name} → {ok, present}.
    public static let OP_HAS = "has"
    /// {name, workdir, columns, rows, command?: [..], labels?: {k: v}, env?: {k: v}} → {ok,
    /// pid, backend, env?: true}. Error if the name exists.
    public static let OP_NEW = "new"
    /// {name} → {ok}. An absent session is not an error.
    public static let OP_KILL = "kill"
    /// {name, text, enter?: true} → {ok}. Text, then (when enter) a 400 ms pause and CR.
    public static let OP_SEND_KEYS = "send-keys"
    /// {name, format?} → {ok, text, alive, foregroundCommand, processId, title, columns,
    /// rows, format, outputBytes, cursorVisible}.
    public static let OP_CAPTURE = "capture"
    /// {name, labels: {k: v|null}} → {ok, labels}: merges, a null value removes the key.
    public static let OP_LABEL = "label"
    /// {name, text?, paste?, requireBracketedPaste?, keys?: [..]} → {ok}.
    public static let OP_INPUT = "input"
    /// {name, sinceBytes?: -1, quietMs?: 300, timeoutMs?: 5000} → {ok, quiet, outputBytes,
    /// alive}. Blocks this connection until quiet, exit, or the timeout.
    public static let OP_WAIT = "wait"
    /// {names?: [..], quietMs?: 500} → {ok}; the connection then streams RESPONSE frames
    /// {ok, event, name, outputBytes, title?, exitCode?} until DETACH or EOF.
    public static let OP_WATCH = "watch"
    /// {name} → {ok, path}.
    public static let OP_CURRENT_PATH = "current-path"
    /// {name, columns, rows} → {ok}; the connection is then in attach mode.
    public static let OP_ATTACH = "attach"
    /// → {ok}; the server stops accepting, kills every session and exits. The one request
    /// honoured whatever its `protocol` says, so a client of another version can always
    /// stop the server.
    public static let OP_SHUTDOWN = "shutdown"

    /// Server-side pause between typed text and the Enter key on `OP_SEND_KEYS`: TUIs with
    /// paste detection treat a CR arriving within milliseconds of the text as a literal
    /// newline, not a submit.
    public static let SEND_KEYS_ENTER_DELAY_MS: Int64 = 400

    /// `OP_WAIT` defaults and the clamp for both of its durations.
    public static let WAIT_DEFAULT_QUIET_MS: Int64 = 300
    public static let WAIT_DEFAULT_TIMEOUT_MS: Int64 = 5000
    public static let WAIT_MAX_MS: Int64 = 60_000
    /// `OP_WATCH`'s default quiet period.
    public static let WATCH_DEFAULT_QUIET_MS: Int64 = 500
}
