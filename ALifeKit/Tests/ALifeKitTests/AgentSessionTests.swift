import XCTest
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif
@testable import ALifeClient

/// `AgentSession` against a stubbed server. The a-life-server package has the
/// tests that run it against the real thing.
@MainActor
final class AgentSessionTests: XCTestCase {
    private func makeSession(url: URL? = URL(string: "https://stub.invalid")) -> (AgentSession, InMemoryServerURLStore) {
        StubServer.reset()
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [StubServer.self]
        let store = InMemoryServerURLStore(url)
        return (AgentSession(serverURLStore: store, urlSession: URLSession(configuration: configuration)), store)
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

    func testWithoutAServerAddressAsksForOne() async {
        let (session, _) = makeSession(url: nil)
        session.connect()
        XCTAssertEqual(session.phase, .needsServer)
        XCTAssertTrue(StubServer.requests.isEmpty)
    }

    func testRejectsAddressesThatAreNotHTTP() async {
        let (session, store) = makeSession(url: nil)
        XCTAssertFalse(session.setServerURL("my-mac"))
        XCTAssertFalse(session.setServerURL("ftp://my-mac"))
        XCTAssertNil(store.load())
        XCTAssertTrue(session.setServerURL(" http://localhost:8080 "))
        XCTAssertEqual(store.load(), URL(string: "http://localhost:8080"))
        session.disconnect()
    }

    func testFollowsTheStreamAndSendsWhatTheUserDoes() async throws {
        let (session, _) = makeSession()
        session.connect()
        await wait(for: "live") { session.phase == .live }
        XCTAssertEqual(StubServer.requests.first?.url.query, "after=0")

        let approval = Approval(id: "p1", agentID: "b", agentName: "Builder", toolName: "bash", input: "ls")
        StubServer.push(EventEnvelope(seq: 1, event: .sessionStarted(sessionID: "s1")))
        StubServer.push(EventEnvelope(seq: 2, event: .agentUpdated(Agent(id: "lead", name: "Team lead", isCoordinator: true))))
        StubServer.push(EventEnvelope(seq: 3, event: .approvalRequested(approval)))
        StubServer.push(EventEnvelope(seq: 4, event: .statusChanged(.idle, stopReason: .requiresAction)))
        await wait(for: "events") { session.stopReason == .requiresAction }
        XCTAssertEqual(session.agents.map(\.name), ["Team lead"])
        XCTAssertEqual(session.pendingApprovals, [approval])

        await session.send("  Tidy the lot ")
        await session.respond(to: approval, allow: true)
        await session.interrupt()
        await session.startNewSession()
        XCTAssertNil(session.lastError)
        let posts = StubServer.requests.filter { $0.method == "POST" }
        XCTAssertEqual(posts.map(\.url.path), [
            "/v1/session/messages", "/v1/session/approvals/p1", "/v1/session/interrupt", "/v1/session/reset",
        ])
        XCTAssertEqual(try JSONDecoder().decode(SendMessageRequest.self, from: XCTUnwrap(posts[0].body)).text, "Tidy the lot")
        XCTAssertEqual(try JSONDecoder().decode(ApprovalDecision.self, from: XCTUnwrap(posts[1].body)).allow, true)

        session.disconnect()
    }

    func testReconnectsFromWhereItLeftOff() async {
        let (session, _) = makeSession()
        session.connect()
        await wait(for: "live") { session.phase == .live }
        StubServer.push(EventEnvelope(seq: 1, event: .sessionStarted(sessionID: "s1")))
        StubServer.push(EventEnvelope(seq: 2, event: .statusChanged(.running, stopReason: nil)))
        await wait(for: "events") { session.status == .running }

        StubServer.dropStream()
        await wait(for: "reconnect") { StubServer.requests.filter { $0.method == "GET" }.count == 2 && session.phase == .live }
        let query = StubServer.requests.last { $0.method == "GET" }?.url.query ?? ""
        XCTAssertTrue(query.contains("after=2") && query.contains("session=s1"), query)
        XCTAssertEqual(session.status, .running) // what it knew is kept across the gap

        session.disconnect()
    }

    func testAFailedSendIsReported() async {
        let (session, _) = makeSession()
        session.connect()
        await wait(for: "live") { session.phase == .live }
        StubServer.failPosts = true
        await session.send("Hello")
        XCTAssertEqual(session.lastError, "No such approval (HTTP 404)")
        session.disconnect()
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
    nonisolated(unsafe) private static var stream: StubServer?
    nonisolated(unsafe) static var failPosts = false

    static var requests: [Recorded] { lock.withLock { _requests } }

    static func reset() {
        lock.withLock {
            _requests = []
            stream = nil
            failPosts = false
        }
    }

    static func push(_ envelope: EventEnvelope) {
        guard let stream = lock.withLock({ stream }) else { return }
        let json = String(decoding: try! JSONEncoder().encode(envelope), as: UTF8.self)
        stream.client?.urlProtocol(stream, didLoad: Data("id: \(envelope.seq)\nevent: \(envelope.event.type)\ndata: \(json)\n\n".utf8))
    }

    static func dropStream() {
        guard let stream = lock.withLock({ stream }) else { return }
        lock.withLock { self.stream = nil }
        stream.client?.urlProtocolDidFinishLoading(stream)
    }

    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    override func stopLoading() {}

    override func startLoading() {
        let method = request.httpMethod ?? "GET"
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
        Self.lock.withLock { Self._requests.append(Recorded(method: method, url: request.url!, body: body)) }

        if method == "GET" {
            let response = HTTPURLResponse(url: request.url!, statusCode: 200, httpVersion: "HTTP/1.1", headerFields: ["Content-Type": "text/event-stream"])!
            client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
            client?.urlProtocol(self, didLoad: Data(": connected\n\n".utf8))
            Self.lock.withLock { Self.stream = self } // stays open
        } else {
            let failed = Self.failPosts
            let response = HTTPURLResponse(url: request.url!, statusCode: failed ? 404 : 202, httpVersion: "HTTP/1.1", headerFields: ["Content-Type": "application/json"])!
            client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
            client?.urlProtocol(self, didLoad: Data((failed ? #"{"error":true,"reason":"No such approval"}"# : "{}").utf8))
            client?.urlProtocolDidFinishLoading(self)
        }
    }
}
