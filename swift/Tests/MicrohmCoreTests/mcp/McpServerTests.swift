import Darwin
import Foundation
import XCTest
@testable import MicrohmCore

/// Records every call; "echo" answers with caller and arguments, "boom" throws, "fail"
/// returns an error.
private final class FakeToolset: McpToolset, @unchecked Sendable {
    let callers = SvcList<String>()

    struct Kaboom: Error, CustomStringConvertible {
        var description: String { "kaboom" }
    }

    func tools() -> [ToolDef] {
        let schema = CoreJSON.obj([("type", .string("object")),
                                   ("properties", .obj([("msg", .obj([("type", .string("string"))]))]))])
        let empty = CoreJSON.obj([("type", .string("object"))])
        return [ToolDef("echo", "Echoes msg and the caller.", schema), ToolDef("boom", "Throws.", empty),
                ToolDef("fail", "Returns an error result.", empty)]
    }

    func call(_ caller: String?, _ tool: String, _ arguments: CoreJSON) throws -> ToolResult {
        callers.append(caller ?? "null")
        switch tool {
        case "echo": return ToolResult.ok((caller ?? "null") + ":" + (arguments.path("msg").asText("") ?? ""))
        case "boom": throw Kaboom()
        case "fail": return ToolResult.error("nope")
        default:
            XCTFail("server must not forward unknown tools: " + tool)
            return ToolResult.error("?")
        }
    }
}

final class McpServerTests: XCTestCase {

    private static let TOKEN = "s3cret-token_ABC"
    private var tools: FakeToolset!
    private var server: McpServer!

    override func setUpWithError() throws {
        tools = FakeToolset()
        server = try McpServer(0, McpServerTests.TOKEN, tools, "9.9.9-test")
        try server.start()
    }

    override func tearDown() {
        server.close()
    }

    private func post(_ url: String, _ body: String, _ headers: [(String, String)] = []) throws -> SvcResponse {
        try SvcHttp.post(url, body, headers)
    }

    private func rpc(_ url: String, _ body: String, file: StaticString = #filePath, line: UInt = #line) throws -> CoreJSON {
        let r = try post(url, body)
        XCTAssertEqual(200, r.status, r.body, file: file, line: line)
        XCTAssertEqual("application/json", r.header("Content-Type"), file: file, line: line)
        return r.json
    }

    private static func call(_ id: Int, _ tool: String, _ argsJson: String) -> String {
        "{\"jsonrpc\":\"2.0\",\"id\":\(id),\"method\":\"tools/call\",\"params\":{\"name\":\"\(tool)\",\"arguments\":\(argsJson)}}"
    }

    private var base: String { "http://127.0.0.1:\(server.port)" }

    func testUrlForEncodesCallerAndUsesActualPort() {
        XCTAssertNotEqual(0, server.port)
        XCTAssertEqual(base + "/mcp/my%20sess%2Fx?token=" + McpServerTests.TOKEN, server.urlFor("my sess/x"))
        XCTAssertEqual(base + "/mcp?token=" + McpServerTests.TOKEN, server.urlFor(nil))
        XCTAssertEqual(base + "/mcp/my%20sess%2Fx", server.callerUrl("my sess/x"))
        XCTAssertEqual(base + "/mcp", server.callerUrl(nil))
    }

    func testInitializeEchoesKnownProtocolVersion() throws {
        let r = try post(server.urlFor("a"), "{\"jsonrpc\":\"2.0\",\"id\":1,\"method\":\"initialize\",\"params\":"
                         + "{\"protocolVersion\":\"2025-03-26\",\"capabilities\":{},\"clientInfo\":{\"name\":\"t\",\"version\":\"1\"}}}")
        XCTAssertEqual(200, r.status)
        XCTAssertNotNil(r.header("Mcp-Session-Id"))
        let res = r.json
        XCTAssertEqual("2.0", res.path("jsonrpc").asText())
        XCTAssertEqual(1, res.path("id").asInt())
        let result = res.path("result")
        XCTAssertEqual("2025-03-26", result.path("protocolVersion").asText())
        XCTAssertFalse(result.svcAt("/capabilities/tools/listChanged").asBoolean(true))
        XCTAssertEqual("micro-harness-manager", result.svcAt("/serverInfo/name").asText())
        XCTAssertEqual("9.9.9-test", result.svcAt("/serverInfo/version").asText())
        XCTAssertTrue(result.path("instructions").asText().contains("notify"))
    }

    func testInitializeWithUnknownVersionAnswersLatest() throws {
        let res = try rpc(server.urlFor(nil),
                          "{\"jsonrpc\":\"2.0\",\"id\":\"x\",\"method\":\"initialize\",\"params\":{\"protocolVersion\":\"1999-01-01\"}}")
        XCTAssertEqual("x", res.path("id").asText())
        XCTAssertEqual("2025-06-18", res.svcAt("/result/protocolVersion").asText())
    }

    func testPingAnswersEmptyObject() throws {
        let res = try rpc(server.urlFor("a"), "{\"jsonrpc\":\"2.0\",\"id\":7,\"method\":\"ping\"}")
        XCTAssertTrue(res.path("result").isObject)
        XCTAssertTrue(res.path("result").isEmpty)
    }

    func testToolsListReturnsDefinitions() throws {
        let res = try rpc(server.urlFor("a"), "{\"jsonrpc\":\"2.0\",\"id\":2,\"method\":\"tools/list\"}")
        let list = res.svcAt("/result/tools")
        XCTAssertEqual(3, list.elements.count)
        XCTAssertEqual("echo", list.path(0).path("name").asText())
        XCTAssertEqual("Echoes msg and the caller.", list.path(0).path("description").asText())
        XCTAssertEqual("string", list.path(0).svcAt("/inputSchema/properties/msg/type").asText())
    }

    func testToolsCallOk() throws {
        let res = try rpc(server.urlFor("caller-1"), McpServerTests.call(3, "echo", "{\"msg\":\"hi\"}"))
        XCTAssertEqual(3, res.path("id").asInt())
        XCTAssertEqual("text", res.svcAt("/result/content/0/type").asText())
        XCTAssertEqual("caller-1:hi", res.svcAt("/result/content/0/text").asText())
        XCTAssertFalse(res.svcAt("/result/isError").asBoolean(true))
    }

    func testToolsCallErrorResult() throws {
        let res = try rpc(server.urlFor("a"), McpServerTests.call(4, "fail", "{}"))
        XCTAssertEqual("nope", res.svcAt("/result/content/0/text").asText())
        XCTAssertTrue(res.svcAt("/result/isError").asBoolean())
    }

    func testToolsetExceptionBecomesErrorResult() throws {
        let res = try rpc(server.urlFor("a"), McpServerTests.call(5, "boom", "{}"))
        XCTAssertNil(res.get("error"))
        XCTAssertEqual("kaboom", res.svcAt("/result/content/0/text").asText())
        XCTAssertTrue(res.svcAt("/result/isError").asBoolean())
    }

    func testUnknownToolIsErrorResult() throws {
        let res = try rpc(server.urlFor("a"), McpServerTests.call(6, "nosuch", "{}"))
        XCTAssertTrue(res.svcAt("/result/isError").asBoolean())
        XCTAssertTrue(res.svcAt("/result/content/0/text").asText().contains("nosuch"))
        XCTAssertEqual(0, tools.callers.count)
    }

    func testMissingArgumentsAreAnEmptyObject() throws {
        let res = try rpc(server.urlFor("a"), "{\"jsonrpc\":\"2.0\",\"id\":1,\"method\":\"tools/call\",\"params\":{\"name\":\"echo\"}}")
        XCTAssertEqual("a:", res.svcAt("/result/content/0/text").asText())
    }

    func testCallerIsUrlDecodedFromPath() throws {
        let res = try rpc(server.urlFor("proj é/1+2"), McpServerTests.call(1, "echo", "{}"))
        XCTAssertEqual("proj é/1+2:", res.svcAt("/result/content/0/text").asText())
        // A raw '+' in the path is literal, not a space.
        let raw = base + "/mcp/a+b%20c?token=" + McpServerTests.TOKEN
        XCTAssertEqual("a+b c:", try rpc(raw, McpServerTests.call(2, "echo", "{}")).svcAt("/result/content/0/text").asText())
    }

    func testAnonymousCallerIsNull() throws {
        _ = try rpc(server.urlFor(nil), McpServerTests.call(1, "echo", "{}"))
        _ = try rpc(base + "/mcp/?token=" + McpServerTests.TOKEN, McpServerTests.call(2, "echo", "{}"))
        XCTAssertEqual(["null", "null"], tools.callers.all)
    }

    func testBearerTokenIsAccepted() throws {
        let r = try post(base + "/mcp/b", McpServerTests.call(1, "echo", "{}"),
                         [("Authorization", "Bearer " + McpServerTests.TOKEN)])
        XCTAssertEqual(200, r.status)
        XCTAssertEqual("b:", r.json.svcAt("/result/content/0/text").asText())
    }

    /// A launched session's token names it: it opens that session's path and no other, so
    /// an agent cannot call as another session (or anonymously).
    func testASessionTokenOpensOnlyItsOwnPath() throws {
        let mine = server.sessionToken("mhm-a")
        XCTAssertNotEqual(mine, McpServerTests.TOKEN)
        XCTAssertNotEqual(mine, server.sessionToken("mhm-b"))
        let echo = McpServerTests.call(1, "echo", "{}")
        XCTAssertEqual(200, try post(base + "/mcp/mhm-a", echo, [("Authorization", "Bearer " + mine)]).status)
        XCTAssertEqual(200, try post(base + "/mcp/mhm-a?token=" + mine, echo).status)
        XCTAssertEqual(401, try post(base + "/mcp/mhm-b", echo, [("Authorization", "Bearer " + mine)]).status)
        XCTAssertEqual(401, try post(base + "/mcp", echo, [("Authorization", "Bearer " + mine)]).status)
        XCTAssertEqual(["mhm-a", "mhm-a"], tools.callers.all)
    }

    func testSessionTokenIsHmacSha256OfTheCallerBase64UrlWithoutPadding() throws {
        // HMAC-SHA256(key "s3cret-token_ABC", "mhm-a"), the Java app's derivation
        let token = server.sessionToken("mhm-a")
        XCTAssertEqual(43, token.count)
        XCTAssertFalse(token.contains("=") || token.contains("+") || token.contains("/"))
    }

    func testBadOrMissingTokenIs401() throws {
        let url = base + "/mcp/a"
        let echo = McpServerTests.call(1, "echo", "{}")
        XCTAssertEqual(401, try post(url + "?token=wrong", echo).status)
        XCTAssertEqual(401, try post(url, echo).status)
        XCTAssertEqual(401, try post(url, echo, [("Authorization", "Bearer wrong")]).status)
        XCTAssertEqual(401, try post(url + "?token=" + McpServerTests.TOKEN + "x", echo).status)
        XCTAssertEqual(0, tools.callers.count)
    }

    func testForeignOriginIs403() throws {
        let echo = McpServerTests.call(1, "echo", "{}")
        XCTAssertEqual(403, try post(server.urlFor("a"), echo, [("Origin", "https://evil.example")]).status)
        XCTAssertEqual(403, try post(server.urlFor("a"), echo, [("Origin", "null")]).status)
        XCTAssertEqual(0, tools.callers.count)
        XCTAssertEqual(200, try post(server.urlFor("a"), echo, [("Origin", "http://localhost:3000")]).status)
        XCTAssertEqual(200, try post(server.urlFor("a"), echo, [("Origin", "http://127.0.0.1")]).status)
        XCTAssertEqual(200, try post(server.urlFor("a"), echo, [("Origin", "http://[::1]:8080")]).status)
    }

    func testGetAndDeleteAre405() throws {
        let (port, target) = SvcHttp.split(server.urlFor("a"))
        let get = try SvcHttp.request(port, "GET", target, headers: [("Accept", "text/event-stream")])
        XCTAssertEqual(405, get.status)
        XCTAssertEqual("POST", get.header("Allow"))
        XCTAssertEqual(405, try SvcHttp.request(port, "DELETE", target).status)
    }

    func testForeignPathIs404() throws {
        let echo = McpServerTests.call(1, "echo", "{}")
        XCTAssertEqual(404, try post(base + "/mcpx?token=" + McpServerTests.TOKEN, echo).status)
        XCTAssertEqual(404, try post(base + "/mcp/a/b?token=" + McpServerTests.TOKEN, echo).status)
    }

    func testBatchAnswersRequestsOnly() throws {
        let body = "[" + McpServerTests.call(1, "echo", "{\"msg\":\"one\"}") + ","
            + "{\"jsonrpc\":\"2.0\",\"method\":\"notifications/initialized\"},"
            + "{\"jsonrpc\":\"2.0\",\"id\":2,\"method\":\"nope\"},"
            + "{\"jsonrpc\":\"2.0\",\"id\":3,\"method\":\"ping\"}]"
        let res = try rpc(server.urlFor("z"), body)
        XCTAssertTrue(res.isArray)
        XCTAssertEqual(3, res.elements.count)
        XCTAssertEqual("z:one", res.path(0).svcAt("/result/content/0/text").asText())
        XCTAssertEqual(-32601, res.path(1).svcAt("/error/code").asInt())
        XCTAssertEqual(2, res.path(1).path("id").asInt())
        XCTAssertEqual(3, res.path(2).path("id").asInt())
    }

    func testNotificationOnlyIs202WithEmptyBody() throws {
        let one = try post(server.urlFor("a"), "{\"jsonrpc\":\"2.0\",\"method\":\"notifications/initialized\"}")
        XCTAssertEqual(202, one.status)
        XCTAssertEqual("", one.body)
        let batch = try post(server.urlFor("a"), "[{\"jsonrpc\":\"2.0\",\"method\":\"notifications/initialized\"},"
                             + "{\"jsonrpc\":\"2.0\",\"id\":9,\"result\":{}}]")
        XCTAssertEqual(202, batch.status)
        XCTAssertEqual("", batch.body)
    }

    func testUnknownMethodIs32601() throws {
        let res = try rpc(server.urlFor("a"), "{\"jsonrpc\":\"2.0\",\"id\":1,\"method\":\"resources/list\"}")
        XCTAssertEqual(-32601, res.svcAt("/error/code").asInt())
        XCTAssertEqual(1, res.path("id").asInt())
    }

    func testParseErrorIs32700() throws {
        let res = try rpc(server.urlFor("a"), "{not json")
        XCTAssertEqual(-32700, res.svcAt("/error/code").asInt())
        XCTAssertTrue(res.path("id").isNull)
    }

    func testInvalidRequestIs32600() throws {
        XCTAssertEqual(-32600, try rpc(server.urlFor("a"), "42").svcAt("/error/code").asInt())
        XCTAssertEqual(-32600, try rpc(server.urlFor("a"), "[]").svcAt("/error/code").asInt())
        let noVersion = try rpc(server.urlFor("a"), "{\"id\":4,\"method\":\"ping\"}")
        XCTAssertEqual(-32600, noVersion.svcAt("/error/code").asInt())
        XCTAssertEqual(4, noVersion.path("id").asInt())
        let batch = try rpc(server.urlFor("a"), "[1,{\"jsonrpc\":\"2.0\",\"id\":5,\"method\":\"ping\"}]")
        XCTAssertEqual(-32600, batch.path(0).svcAt("/error/code").asInt())
        XCTAssertEqual(5, batch.path(1).path("id").asInt())
    }

    func testOversizedBodyIs413() throws {
        let big = "{\"jsonrpc\":\"2.0\",\"id\":1,\"method\":\"ping\",\"params\":{\"pad\":\""
            + String(repeating: "x", count: McpServer.MAX_BODY_BYTES) + "\"}}"
        XCTAssertEqual(413, try post(server.urlFor("a"), big).status)
        // with Expect: 100-continue the client never sends the body, and still gets the 413
        let (port, target) = SvcHttp.split(server.urlFor("a"))
        let socket = try SvcSocket(port: port)
        try socket.send(Array(("POST \(target) HTTP/1.1\r\nHost: x\r\nContent-Type: application/json\r\n"
                               + "Content-Length: \(big.utf8.count)\r\nExpect: 100-continue\r\n\r\n").utf8))
        XCTAssertEqual(413, try socket.readHead().0)
    }

    func testAChunkedBodyIsRead() throws {
        let (port, target) = SvcHttp.split(server.urlFor("c"))
        let socket = try SvcSocket(port: port)
        let body = McpServerTests.call(1, "echo", "{\"msg\":\"chunked\"}")
        let half = body.utf8.count / 2
        let first = String(decoding: Array(body.utf8)[0..<half], as: UTF8.self)
        let second = String(decoding: Array(body.utf8)[half...], as: UTF8.self)
        try socket.send(Array(("POST \(target) HTTP/1.1\r\nHost: x\r\nTransfer-Encoding: chunked\r\n\r\n"
                               + String(first.utf8.count, radix: 16) + "\r\n" + first + "\r\n"
                               + String(second.utf8.count, radix: 16) + "\r\n" + second + "\r\n0\r\n\r\n").utf8))
        let (status, headers) = try socket.readHead()
        XCTAssertEqual(200, status)
        let json = try CoreJSON.parse(socket.readBody(headers))
        XCTAssertEqual("c:chunked", json.svcAt("/result/content/0/text").asText())
    }

    func testKeepAliveServesSeveralRequestsOnOneConnection() throws {
        let (port, target) = SvcHttp.split(server.urlFor("k"))
        let socket = try SvcSocket(port: port)
        for i in 1...3 {
            try socket.send(SvcSocket.requestBytes("POST", target, [("Content-Type", "application/json")],
                                                   McpServerTests.call(i, "echo", "{\"msg\":\"\(i)\"}"), port: port))
            let (status, headers) = try socket.readHead()
            XCTAssertEqual(200, status)
            XCTAssertEqual("k:\(i)", try CoreJSON.parse(socket.readBody(headers)).svcAt("/result/content/0/text").asText())
        }
    }

    func testCloseIsIdempotentAndStopsServing() throws {
        let url = server.urlFor("a")
        server.close()
        server.close()
        XCTAssertThrowsError(try post(url, McpServerTests.call(1, "echo", "{}")))
    }
}

/// The service's lifecycle over real loopback sockets — always on free ports, never the
/// configured default, so a running app on this machine is never disturbed.
final class McpServiceTests: XCTestCase {

    private let service = McpService(McpService.NO_TOOLS, "test")

    override func tearDown() {
        service.stop()
    }

    private func ping(_ url: String) throws -> Int {
        try SvcHttp.post(url, "{\"jsonrpc\":\"2.0\",\"id\":1,\"method\":\"ping\"}").status
    }

    func testStoppedServiceHasNoUrl() {
        XCTAssertFalse(service.isRunning())
        XCTAssertEqual(-1, service.port())
        XCTAssertNil(service.urlFor("mhm-x"))
        XCTAssertNil(service.linkFor("mhm-x"))
        service.stop() // idempotent
    }

    func testStartServesAndUrlCarriesCallerAndToken() throws {
        try service.start(0, "tok")
        XCTAssertTrue(service.isRunning())
        let port = service.port()
        XCTAssertTrue(port > 0)
        XCTAssertEqual("http://127.0.0.1:\(port)/mcp/mhm-a%20b?token=tok", service.urlFor("mhm-a b"))
        XCTAssertEqual(200, try ping(service.urlFor("mhm-x")!))

        service.stop()
        XCTAssertNil(service.linkFor("mhm-x"))
        XCTAssertFalse(service.isRunning())
        XCTAssertNil(service.urlFor("mhm-x"))
        XCTAssertThrowsError(try ping("http://127.0.0.1:\(port)/mcp?token=tok"))
    }

    func testLinkKeepsTheTokenOutOfTheUrlAndTheBearerHeaderIsAccepted() throws {
        try service.start(0, "tok")
        let link = service.linkFor("mhm-a b")!
        XCTAssertEqual("http://127.0.0.1:\(service.port())/mcp/mhm-a%20b", link.url)
        XCTAssertFalse(link.token.contains("tok"), "the session gets its own token, not the server's")
        XCTAssertFalse(link.description.contains(link.token), link.description)
        let body = "{\"jsonrpc\":\"2.0\",\"id\":1,\"method\":\"ping\"}"
        XCTAssertEqual(401, try SvcHttp.post(link.url, body).status)
        XCTAssertEqual(200, try SvcHttp.post(link.url, body, [("Authorization", "Bearer " + link.token)]).status)
    }

    func testToolsetIsToldWhenTheServerStartsAndStops() throws {
        final class Tracked: McpToolset, @unchecked Sendable {
            let lifecycle = SvcList<String>()
            func tools() -> [ToolDef] { [] }
            func call(_ caller: String?, _ tool: String, _ arguments: CoreJSON) throws -> ToolResult { .error("none") }
            func serverStarted() { lifecycle.append("started") }
            func serverStopped() { lifecycle.append("stopped") }
        }
        let toolset = Tracked()
        let tracked = McpService(toolset, "test")
        defer { tracked.stop() }
        try tracked.start(0, "tok")
        try tracked.start(0, "other") // a restart: stopped, then started again
        tracked.stop()
        tracked.stop() // idempotent: no second notice
        XCTAssertEqual(["started", "stopped", "started", "stopped"], toolset.lifecycle.all)
    }

    func testRestartingOnANewPortOrTokenClosesTheOldSocket() throws {
        let first = try McpServiceTests.freePort()
        try service.start(first, "one")
        try service.start(first, "one") // same port and token: no-op
        XCTAssertEqual(first, service.port())
        try service.start(first, "two") // new token: rebound
        XCTAssertEqual(401, try ping("http://127.0.0.1:\(first)/mcp?token=one"))
        XCTAssertEqual(200, try ping(service.urlFor(nil)!))

        let second = try McpServiceTests.freePort()
        try service.start(second, "two")
        XCTAssertEqual(second, service.port())
        XCTAssertThrowsError(try ping("http://127.0.0.1:\(first)/mcp?token=two"))
    }

    func testATakenPortFailsCleanlyAndLeavesTheServiceStopped() throws {
        let (squatter, squatterPort) = try McpServiceTests.listen()
        defer { Darwin.close(squatter) }
        try service.start(0, "tok")
        XCTAssertNotEqual(squatterPort, service.port())
        XCTAssertThrowsError(try service.start(squatterPort, "tok"))
        XCTAssertFalse(service.isRunning())
        XCTAssertNil(service.urlFor("mhm-x"))
    }

    /// A socket listening on a free loopback port.
    static func listen() throws -> (Int32, Int) {
        let fd = Darwin.socket(AF_INET, SOCK_STREAM, 0)
        var addr = sockaddr_in()
        addr.sin_len = UInt8(MemoryLayout<sockaddr_in>.size)
        addr.sin_family = sa_family_t(AF_INET)
        addr.sin_addr.s_addr = inet_addr("127.0.0.1")
        _ = withUnsafePointer(to: &addr) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { Darwin.bind(fd, $0, socklen_t(MemoryLayout<sockaddr_in>.size)) }
        }
        Darwin.listen(fd, 5)
        var bound = sockaddr_in()
        var length = socklen_t(MemoryLayout<sockaddr_in>.size)
        _ = withUnsafeMutablePointer(to: &bound) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { Darwin.getsockname(fd, $0, &length) }
        }
        return (fd, Int(UInt16(bigEndian: bound.sin_port)))
    }

    static func freePort() throws -> Int {
        let (fd, port) = try listen()
        Darwin.close(fd)
        return port
    }
}
