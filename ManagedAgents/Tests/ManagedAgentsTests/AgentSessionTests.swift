import XCTest
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif
@testable import ManagedAgents

/// Runs `AgentSession` end to end against a stubbed API.
@MainActor
final class AgentSessionTests: XCTestCase {
    override func setUp() {
        StubAPI.reset()
    }

    private func makeSession(
        reference: SessionReference = SessionReference(),
        key: String? = "sk-test"
    ) -> (AgentSession, InMemorySessionReferenceStore) {
        let store = InMemorySessionReferenceStore(reference)
        let session = AgentSession(
            apiKeyStore: InMemoryAPIKeyStore(key: key),
            referenceStore: store,
            makeClient: { key in
                let configuration = URLSessionConfiguration.ephemeral
                configuration.protocolClasses = [StubAPI.self]
                return ManagedAgentsClient(
                    apiKey: key,
                    baseURL: URL(string: "https://stub.invalid")!,
                    urlSession: URLSession(configuration: configuration)
                )
            }
        )
        return (session, store)
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

    func testWithoutAPIKeyAsksForOne() async {
        let (session, _) = makeSession(key: nil)
        session.connect()
        XCTAssertEqual(session.phase, .needsAPIKey)
        XCTAssertTrue(StubAPI.requests.isEmpty)
    }

    func testFirstRunCreatesEverythingOnceThenFollowsTheSession() async throws {
        StubAPI.history = [
            ["id": "sevt_1", "type": "user.message", "content": [["type": "text", "text": "Tidy the lot"]]],
            ["id": "sevt_2", "type": "session.status_running"],
            ["id": "sevt_3", "type": "session.thread_created", "session_thread_id": "sthr_child", "agent_name": "Gardener"],
            ["id": "sevt_4", "type": "session.thread_status_running", "session_thread_id": "sthr_child", "agent_name": "Gardener"],
        ]
        StubAPI.threads = [
            ["id": "sthr_main", "status": "running", "parent_thread_id": nil, "agent": ["type": "agent", "name": "Team lead"]],
            ["id": "sthr_child", "status": "running", "parent_thread_id": "sthr_main", "agent": ["type": "inline", "name": "Gardener"]],
        ]
        let (session, store) = makeSession()

        session.connect()
        await wait(for: "live") { session.phase == .live }

        XCTAssertEqual(store.load(), SessionReference(agentID: "agent_1", environmentID: "env_1", sessionID: "sesn_1"))
        let created = StubAPI.requests.filter { $0.method == "POST" }.map(\.path)
        XCTAssertEqual(created, ["/v1/environments", "/v1/agents", "/v1/sessions"])
        let agentBody = try XCTUnwrap(StubAPI.requests.first { $0.path == "/v1/agents" }?.body)
        XCTAssertEqual(agentBody["multiagent"]?["type"]?.stringValue, "multiagent_20261001")
        let sessionBody = try XCTUnwrap(StubAPI.requests.first { $0.path == "/v1/sessions" }?.body)
        XCTAssertEqual(sessionBody["budget"]?["max_list_cost"]?["amount"]?.stringValue, "500")
        XCTAssertEqual(StubAPI.requests.first?.headers["anthropic-beta"], "managed-agents-2026-04-01")
        XCTAssertEqual(StubAPI.requests.first?.headers["x-api-key"], "sk-test")

        XCTAssertEqual(session.status, .running)
        XCTAssertEqual(session.agents.map(\.name), ["Team lead", "Gardener"])
        XCTAssertEqual(session.agents.map(\.isCoordinator), [true, false])
        XCTAssertEqual(session.transcript.map(\.text), ["Tidy the lot"])

        // Live events, including one that was already in the history.
        StubAPI.pushLive(["id": "sevt_1", "type": "user.message", "content": [["type": "text", "text": "Tidy the lot"]]])
        StubAPI.pushLive([
            "id": "sevt_5", "type": "agent.tool_use", "name": "bash", "input": ["command": "ls"],
            "evaluated_permission": "ask", "session_thread_id": "sthr_child",
        ])
        StubAPI.pushLive(["id": "sevt_6", "type": "session.status_idle", "stop_reason": ["type": "requires_action", "event_ids": ["sevt_5"]]])
        await wait(for: "approval") { session.stopReason == "requires_action" }

        XCTAssertEqual(session.transcript.count, 1)
        XCTAssertEqual(session.pendingApprovals.map(\.toolName), ["bash"])
        XCTAssertEqual(session.pendingApprovals.first?.agentName, "Gardener")
        XCTAssertEqual(session.agents.last?.activity, "bash")

        await session.respond(to: session.pendingApprovals[0], allow: true)
        await session.send("  And water the bushes ")
        let sent = StubAPI.requests.filter { $0.path == "/v1/sessions/sesn_1/events" && $0.method == "POST" }
        XCTAssertEqual(sent.count, 2)
        XCTAssertEqual(sent[0].body?["events"]?.arrayValue?.first, [
            "type": "user.tool_confirmation", "tool_use_id": "sevt_5", "result": "allow",
        ])
        XCTAssertEqual(sent[1].body?["events"]?.arrayValue?.first?["content"]?.joinedText, "And water the bushes")
        XCTAssertNil(session.lastError)

        StubAPI.pushLive(["id": "sevt_7", "type": "user.tool_confirmation", "tool_use_id": "sevt_5", "result": "allow"])
        StubAPI.pushLive(["id": "sevt_8", "type": "session.thread_status_idle", "session_thread_id": "sthr_child", "agent_name": "Gardener", "stop_reason": ["type": "end_turn"]])
        StubAPI.pushLive(["id": "sevt_9", "type": "agent.thread_message_received", "from_agent_name": "Gardener", "content": [["type": "text", "text": "Done."]]])
        await wait(for: "report") { session.transcript.count == 2 }
        XCTAssertTrue(session.pendingApprovals.isEmpty)
        XCTAssertEqual(session.agents.last?.status, .idle)
        XCTAssertEqual(session.transcript.last?.speaker, "Gardener → Team lead")

        session.disconnect()
    }

    func testLaterRunsReuseTheStoredSession() async {
        let stored = SessionReference(agentID: "agent_9", environmentID: "env_9", sessionID: "sesn_9")
        let (session, store) = makeSession(reference: stored)

        session.connect()
        await wait(for: "live") { session.phase == .live }

        XCTAssertEqual(store.load(), stored)
        XCTAssertTrue(StubAPI.requests.allSatisfy { $0.method == "GET" })
        XCTAssertTrue(StubAPI.requests.contains { $0.path == "/v1/sessions/sesn_9/events/stream" })
        session.disconnect()
    }

    func testRejectedKeyFailsWithoutRetrying() async {
        StubAPI.failure = (401, ["type": "error", "error": ["type": "authentication_error", "message": "invalid x-api-key"]])
        let (session, _) = makeSession()

        session.connect()
        await wait(for: "failure") { if case .failed = session.phase { return true } else { return false } }

        XCTAssertEqual(session.phase, .failed("invalid x-api-key (HTTP 401)"))
        XCTAssertEqual(StubAPI.requests.count, 1)
    }

    func testChangingTheKeyForgetsTheOldWorkspaceIDs() async {
        let (session, store) = makeSession(reference: SessionReference(agentID: "a", environmentID: "e", sessionID: "s"))
        session.setAPIKey("sk-other")
        XCTAssertEqual(store.load(), SessionReference())
        session.disconnect()
    }
}

/// Stands in for api.anthropic.com.
final class StubAPI: URLProtocol, @unchecked Sendable {
    struct Recorded {
        let method: String
        let path: String
        let headers: [String: String]
        let body: JSONValue?
    }

    private static let lock = NSLock()
    nonisolated(unsafe) private static var _requests: [Recorded] = []
    nonisolated(unsafe) private static var liveStream: StubAPI?
    nonisolated(unsafe) static var history: [JSONValue] = []
    nonisolated(unsafe) static var threads: [JSONValue] = []
    nonisolated(unsafe) static var failure: (Int, JSONValue)?

    static var requests: [Recorded] { lock.withLock { _requests } }

    static func reset() {
        lock.withLock {
            _requests = []
            liveStream = nil
            history = []
            threads = []
            failure = nil
        }
    }

    static func pushLive(_ event: JSONValue) {
        let json = String(decoding: try! JSONEncoder().encode(event), as: UTF8.self)
        let type = event["type"]?.stringValue ?? ""
        lock.withLock { liveStream }?.client?.urlProtocol(self.liveStream!, didLoad: Data("event: \(type)\ndata: \(json)\n\n".utf8))
    }

    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    override func stopLoading() {}

    override func startLoading() {
        let method = request.httpMethod ?? "GET"
        let path = request.url?.path ?? ""
        var body = request.httpBody
        if body == nil, let stream = request.httpBodyStream {
            stream.open()
            var data = Data()
            var buffer = [UInt8](repeating: 0, count: 4096)
            while case let count = stream.read(&buffer, maxLength: buffer.count), count > 0 {
                data.append(buffer, count: count)
            }
            stream.close()
            body = data
        }
        Self.lock.withLock {
            Self._requests.append(Recorded(
                method: method,
                path: path,
                // Header names keep whatever case the platform gives them.
                headers: Dictionary((request.allHTTPHeaderFields ?? [:]).map { ($0.key.lowercased(), $0.value) }, uniquingKeysWith: { $1 }),
                body: body.flatMap { try? JSONDecoder().decode(JSONValue.self, from: $0) }
            ))
        }

        if let (status, json) = Self.failure {
            return respond(status, json)
        }
        switch (method, path) {
        case ("POST", "/v1/environments"): respond(200, ["id": "env_1"])
        case ("POST", "/v1/agents"): respond(200, ["id": "agent_1", "version": 1])
        case ("POST", "/v1/sessions"): respond(200, ["id": "sesn_1", "status": "idle"])
        case ("GET", _) where path.hasSuffix("/events/stream"):
            let response = HTTPURLResponse(url: request.url!, statusCode: 200, httpVersion: "HTTP/1.1", headerFields: ["Content-Type": "text/event-stream"])!
            client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
            client?.urlProtocol(self, didLoad: Data(": connected\n\n".utf8))
            Self.lock.withLock { Self.liveStream = self } // stays open
        case ("GET", _) where path.hasSuffix("/events"): respond(200, ["data": .array(Self.history), "next_page": nil])
        case ("GET", _) where path.hasSuffix("/threads"): respond(200, ["data": .array(Self.threads), "next_page": nil])
        case ("GET", _) where path.hasPrefix("/v1/sessions/"):
            respond(200, ["id": .string(String(path.dropFirst("/v1/sessions/".count))), "status": "idle"])
        case ("POST", _) where path.hasSuffix("/events"): respond(200, ["data": []])
        default: respond(404, ["type": "error", "error": ["type": "not_found_error", "message": .string("no stub for \(method) \(path)")]])
        }
    }

    private func respond(_ status: Int, _ json: JSONValue) {
        let response = HTTPURLResponse(url: request.url!, statusCode: status, httpVersion: "HTTP/1.1", headerFields: ["Content-Type": "application/json"])!
        client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: try! JSONEncoder().encode(json))
        client?.urlProtocolDidFinishLoading(self)
    }
}
