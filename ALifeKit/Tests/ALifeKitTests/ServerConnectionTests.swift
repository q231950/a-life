import XCTest
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif
@testable import ALifeClient

/// `ServerConnection` and its `AgentSession`s against a stubbed server. The
/// a-life-server package has the tests that run them against the real thing.
@MainActor
final class ServerConnectionTests: XCTestCase {
    private func makeConnection(url: URL? = URL(string: "https://stub.invalid")) -> (ServerConnection, InMemoryServerURLStore) {
        StubServer.reset()
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [StubServer.self]
        let store = InMemoryServerURLStore(url)
        return (ServerConnection(serverURLStore: store, urlSession: URLSession(configuration: configuration)), store)
    }

    private func wait(
        for description: String,
        file: StaticString = #filePath,
        line: UInt = #line,
        until condition: () -> Bool
    ) async {
        for _ in 0..<500 where !condition() {
            try? await Task.sleep(nanoseconds: 10_000_000)
        }
        XCTAssertTrue(condition(), "timed out waiting for \(description)", file: file, line: line)
    }

    /// The event streams opened so far, oldest first.
    private var streamRequests: [StubServer.Recorded] {
        StubServer.requests.filter { $0.url.path.hasSuffix("/events") }
    }

    func testWithoutAServerAddressAsksForOne() async {
        let (server, _) = makeConnection(url: nil)
        server.connect()
        XCTAssertEqual(server.phase, .needsServer)
        XCTAssertTrue(StubServer.requests.isEmpty)
    }

    func testRejectsAddressesThatAreNotHTTP() async {
        let (server, store) = makeConnection(url: nil)
        XCTAssertFalse(server.setServerURL("my-mac"))
        XCTAssertFalse(server.setServerURL("ftp://my-mac"))
        XCTAssertNil(store.load())
        XCTAssertTrue(server.setServerURL(" http://localhost:8080 "))
        XCTAssertEqual(store.load(), URL(string: "http://localhost:8080"))
        server.disconnect()
    }

    func testFollowsEverySessionAndTalksToEachOne() async throws {
        let (server, _) = makeConnection()
        server.connect()
        await wait(for: "live") { server.phase == .live }
        XCTAssertEqual(server.sessions.map(\.name), ["Gardener", "Builder"])
        XCTAssertEqual(Set(streamRequests.map(\.url.path)), ["/v1/sessions/gardener/events", "/v1/sessions/builder/events"])
        XCTAssertTrue(streamRequests.allSatisfy { $0.url.query == "after=0" })

        let gardener = try XCTUnwrap(server.session("gardener"))
        let builder = try XCTUnwrap(server.session("builder"))
        let approval = Approval(id: "p1", toolName: "bash", input: "ls")
        StubServer.push(EventEnvelope(seq: 1, event: .conversationStarted(conversationID: "g1")), to: "gardener")
        StubServer.push(EventEnvelope(seq: 2, event: .statusChanged(.running, stopReason: nil)), to: "gardener")
        StubServer.push(EventEnvelope(seq: 3, event: .activityChanged("read")), to: "gardener")
        StubServer.push(EventEnvelope(seq: 1, event: .conversationStarted(conversationID: "b1")), to: "builder")
        StubServer.push(EventEnvelope(seq: 2, event: .approvalRequested(approval)), to: "builder")
        StubServer.push(EventEnvelope(seq: 3, event: .statusChanged(.idle, stopReason: .requiresAction)), to: "builder")
        let helper = Subagent(id: "s1", task: "Search the flower beds")
        StubServer.push(EventEnvelope(seq: 4, event: .subagentStarted(helper)), to: "gardener")
        await wait(for: "events") { gardener.subagents == [helper] && builder.stopReason == .requiresAction }

        // Each session has only its own events.
        XCTAssertEqual(gardener.status, .running)
        XCTAssertEqual(gardener.activity, "read")
        XCTAssertFalse(gardener.isWaitingForYou)
        XCTAssertTrue(gardener.pendingApprovals.isEmpty)
        XCTAssertTrue(builder.isWaitingForYou)
        XCTAssertEqual(builder.pendingApprovals, [approval])
        XCTAssertNil(builder.activity)
        XCTAssertTrue(builder.subagents.isEmpty)

        StubServer.push(EventEnvelope(seq: 5, event: .subagentFinished(subagentID: "s1")), to: "gardener")
        await wait(for: "the helper to report back") { gardener.subagents.isEmpty }

        await gardener.send("  What are you doing? ")
        await builder.respond(to: approval, allow: true)
        await builder.interrupt()
        await gardener.startOver()
        XCTAssertNil(gardener.lastError)
        XCTAssertNil(builder.lastError)
        let posts = StubServer.requests.filter { $0.method == "POST" }
        XCTAssertEqual(posts.map(\.url.path), [
            "/v1/sessions/gardener/messages",
            "/v1/sessions/builder/approvals/p1",
            "/v1/sessions/builder/interrupt",
            "/v1/sessions/gardener/reset",
        ])
        XCTAssertEqual(try JSONDecoder().decode(SendMessageRequest.self, from: XCTUnwrap(posts[0].body)).text, "What are you doing?")
        XCTAssertEqual(try JSONDecoder().decode(ApprovalDecision.self, from: XCTUnwrap(posts[1].body)).allow, true)

        server.disconnect()
    }

    func testReconnectsEachSessionFromWhereItLeftOff() async throws {
        let (server, _) = makeConnection()
        server.connect()
        await wait(for: "live") { server.phase == .live }
        let gardener = try XCTUnwrap(server.session("gardener"))
        let builder = try XCTUnwrap(server.session("builder"))
        StubServer.push(EventEnvelope(seq: 1, event: .conversationStarted(conversationID: "g1")), to: "gardener")
        StubServer.push(EventEnvelope(seq: 2, event: .statusChanged(.running, stopReason: nil)), to: "gardener")
        StubServer.push(EventEnvelope(seq: 1, event: .conversationStarted(conversationID: "b1")), to: "builder")
        await wait(for: "events") { gardener.status == .running && builder.state.conversationID == "b1" }

        // One stream dropping brings every session back in.
        StubServer.dropStream("builder")
        await wait(for: "reconnect") { streamRequests.count == 4 && server.phase == .live }
        let queries = Dictionary(uniqueKeysWithValues: streamRequests.suffix(2).map { ($0.url.path, $0.url.query ?? "") })
        let gardenerQuery = try XCTUnwrap(queries["/v1/sessions/gardener/events"])
        let builderQuery = try XCTUnwrap(queries["/v1/sessions/builder/events"])
        XCTAssertTrue(gardenerQuery.contains("after=2") && gardenerQuery.contains("conversation=g1"), gardenerQuery)
        XCTAssertTrue(builderQuery.contains("after=1") && builderQuery.contains("conversation=b1"), builderQuery)
        XCTAssertEqual(gardener.status, .running) // what it knew is kept across the gap

        server.disconnect()
    }

    func testFollowsTheServersListOfSessions() async throws {
        let (server, _) = makeConnection()
        server.connect()
        await wait(for: "live") { server.phase == .live }
        let gardener = try XCTUnwrap(server.session("gardener"))
        StubServer.push(EventEnvelope(seq: 1, event: .conversationStarted(conversationID: "g1")), to: "gardener")
        await wait(for: "events") { gardener.state.conversationID == "g1" }

        // The server comes back with someone else instead of the Builder.
        StubServer.roster = [SessionState(id: "gardener", name: "Gardener"), SessionState(id: "painter", name: "Painter")]
        StubServer.dropStream("gardener")
        await wait(for: "the new list") { server.sessions.map(\.name) == ["Gardener", "Painter"] && server.phase == .live }
        XCTAssertTrue(server.session("gardener") === gardener)
        XCTAssertEqual(gardener.state.conversationID, "g1")
        XCTAssertNil(server.session("builder"))

        server.disconnect()
    }

    func testAFailedSendIsReportedOnThatSession() async throws {
        let (server, _) = makeConnection()
        server.connect()
        await wait(for: "live") { server.phase == .live }
        StubServer.failPosts = (409, "Builder is waiting for an answer to its request")
        let builder = try XCTUnwrap(server.session("builder"))
        await builder.send("Hello")
        XCTAssertEqual(builder.lastError, "Builder is waiting for an answer to its request (HTTP 409)")
        XCTAssertNil(server.session("gardener")?.lastError)
        server.disconnect()
    }
}

/// Stands in for an a-life-server.
final class StubServer: URLProtocol, @unchecked Sendable {
    struct Recorded {
        let method: String
        let url: URL
        let body: Data?
    }

    private static let lock = NSLock()
    nonisolated(unsafe) private static var _requests: [Recorded] = []
    /// The open event streams, by session id.
    nonisolated(unsafe) private static var streams: [String: StubServer] = [:]
    nonisolated(unsafe) private static var _roster: [SessionState] = []
    nonisolated(unsafe) private static var _failPosts: (status: Int, reason: String)?

    static var requests: [Recorded] { lock.withLock { _requests } }
    /// What `GET /v1/sessions` answers.
    static var roster: [SessionState] {
        get { lock.withLock { _roster } }
        set { lock.withLock { _roster = newValue } }
    }
    /// Makes every POST fail like this.
    static var failPosts: (status: Int, reason: String)? {
        get { lock.withLock { _failPosts } }
        set { lock.withLock { _failPosts = newValue } }
    }

    static func reset() {
        lock.withLock {
            _requests = []
            streams = [:]
            _roster = [SessionState(id: "gardener", name: "Gardener"), SessionState(id: "builder", name: "Builder")]
            _failPosts = nil
        }
    }

    static func push(_ envelope: EventEnvelope, to sessionID: String) {
        guard let stream = lock.withLock({ streams[sessionID] }) else { return }
        let json = String(decoding: try! JSONEncoder().encode(envelope), as: UTF8.self)
        stream.client?.urlProtocol(stream, didLoad: Data("id: \(envelope.seq)\nevent: \(envelope.event.type)\ndata: \(json)\n\n".utf8))
    }

    static func dropStream(_ sessionID: String) {
        guard let stream = lock.withLock({ streams.removeValue(forKey: sessionID) }) else { return }
        stream.client?.urlProtocolDidFinishLoading(stream)
    }

    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }

    override func stopLoading() {
        Self.lock.withLock {
            for (id, stream) in Self.streams where stream === self {
                Self.streams[id] = nil
            }
        }
    }

    override func startLoading() {
        let method = request.httpMethod ?? "GET"
        let url = request.url!
        var body = request.httpBody
        if body == nil, let input = request.httpBodyStream {
            input.open()
            var data = Data()
            var buffer = [UInt8](repeating: 0, count: 4096)
            while case let count = input.read(&buffer, maxLength: buffer.count), count > 0 {
                data.append(buffer, count: count)
            }
            input.close()
            body = data
        }
        Self.lock.withLock { Self._requests.append(Recorded(method: method, url: url, body: body)) }

        if method == "GET", url.path.hasSuffix("/events") {
            let sessionID = url.deletingLastPathComponent().lastPathComponent
            respond(200, contentType: "text/event-stream", body: ": connected\n\n", finish: false)
            Self.lock.withLock { Self.streams[sessionID] = self } // stays open
        } else if method == "GET", url.path == "/v1/sessions" {
            respond(200, body: String(decoding: try! JSONEncoder().encode(Self.roster), as: UTF8.self))
        } else if let failure = Self.failPosts {
            respond(failure.status, body: #"{"error":true,"reason":"\#(failure.reason)"}"#)
        } else {
            respond(202, body: "{}")
        }
    }

    private func respond(_ status: Int, contentType: String = "application/json", body: String, finish: Bool = true) {
        let response = HTTPURLResponse(url: request.url!, statusCode: status, httpVersion: "HTTP/1.1", headerFields: ["Content-Type": contentType])!
        client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: Data(body.utf8))
        if finish { client?.urlProtocolDidFinishLoading(self) }
    }
}
