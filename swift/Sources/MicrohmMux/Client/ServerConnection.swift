import Foundation

/// One socket to the server with its codec. `open` folds "socket file missing" and
/// "connect refused" into nil — both mean no server — and `request` stamps every request
/// with the protocol version and turns EOF-before-response into `NoServerError`, so
/// callers see exactly the three no-server cases the design names and nothing else in
/// that shape.
final class ServerConnection: @unchecked Sendable {

    /// The connection died before the response: the server is not (or no longer) there.
    struct NoServerError: Error {
        let message: String
    }

    let socket: UnixSocket
    let codec: FrameCodec

    private init(_ socket: UnixSocket) {
        self.socket = socket
        self.codec = FrameCodec(socket)
    }

    /// Nil when no server listens; throws when the home belongs to someone else.
    static func open(_ socketFile: URL) throws -> ServerConnection? {
        do {
            // Not "no server": whoever owns that directory owns whatever listens in it.
            try ServerHome.requireOwned(socketFile.deletingLastPathComponent())
        } catch {
            throw SessionServerException("\(error)", cause: error)
        }
        guard let socket = try? UnixSocket.connect(socketFile.path) else { return nil }
        return ServerConnection(socket)
    }

    /// Sends `op` with `args` (plus the protocol stamp) and returns the response body,
    /// which may be `ok:false`. With a `timeout`, a server that stops answering (wedged,
    /// stopped) makes this throw after that long without a byte instead of blocking the
    /// caller for ever; the read timeout stays on the socket, so only connections that are
    /// done after the response pass one (not attach or watch).
    func request(_ op: String, _ args: JSONObject?, timeout: TimeInterval? = nil) throws -> JSONObject {
        if let timeout {
            socket.setReceiveTimeout(timeout)
        }
        var body = args ?? Json.object()
        body[MuxProtocol.F_OP] = .string(op)
        body[MuxProtocol.F_PROTOCOL] = .int(Int64(MuxProtocol.VERSION))
        try codec.write(Frame(.REQUEST, Json.bytes(body)))
        let reply: Frame?
        do {
            reply = try codec.read()
        } catch let error as MuxIOError where error.isEOF {
            throw NoServerError(message: "connection closed before the response")
        }
        guard let reply else {
            throw NoServerError(message: "connection closed before the response")
        }
        if reply.type != .RESPONSE {
            throw MuxIOError("expected a RESPONSE frame, got \(reply.type)")
        }
        guard case .object(let node) = try Json.parse(reply.payload) else {
            throw MuxIOError("response is not a JSON object")
        }
        return node
    }

    /// Reads until the server closes the socket (what `shutdown` waits for).
    func drainToEof() {
        while true {
            guard let frame = try? codec.read() else { return }
            _ = frame
        }
    }

    func close() {
        socket.close()
    }
}
