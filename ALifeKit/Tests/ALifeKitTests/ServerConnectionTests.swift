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
        let server = ServerConnection(
            serverURLStore: store,
            urlSession: URLSession(configuration: configuration),
            logSeenStore: InMemoryLogSeenStore()
        )
        return (server, store)
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

    /// The sessions' event streams opened so far, oldest first.
    private var streamRequests: [StubServer.Recorded] {
        StubServer.requests.filter { $0.url.path.hasPrefix("/v1/sessions/") && $0.url.path.hasSuffix("/events") }
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

    func testOnlyWhatIsSaidAfterCatchingUpIsNew() async throws {
        let (server, _) = makeConnection()
        // The server had got to 3 before this front end connected.
        var gardenerListed = SessionState(id: "gardener", name: "Gardener")
        gardenerListed.lastSeq = 3
        StubServer.roster = [gardenerListed]
        server.connect()
        await wait(for: "live") { server.phase == .live }
        let gardener = try XCTUnwrap(server.session("gardener"))

        let before = Message(id: "m1", kind: .agent, speaker: "Gardener", text: "I watered the roses.")
        let after = Message(id: "m2", kind: .agent, speaker: "Gardener", text: "The tulips are up.")
        StubServer.push(EventEnvelope(seq: 1, event: .conversationStarted(conversationID: "g1")), to: "gardener")
        StubServer.push(EventEnvelope(seq: 2, event: .message(before)), to: "gardener") // replayed
        StubServer.push(EventEnvelope(seq: 3, event: .statusChanged(.idle, stopReason: .endTurn)), to: "gardener")
        StubServer.push(EventEnvelope(seq: 4, event: .message(after)), to: "gardener") // live
        await wait(for: "the live message") { gardener.transcript.count == 2 }
        XCTAssertEqual(gardener.newMessages, [after])

        server.disconnect()
    }

    /// Says nothing, and writes down what it was asked to.
    private final class Silence: SpeechEngine {
        var said: [String] = []
        func say(_ text: String, voice: Int) async { said.append(text) }
        func stop() {}
    }

    func testWhatHappenedWhileYouWereAwayIsLoggedButNeitherSaidNorRung() async throws {
        let (server, _) = makeConnection()
        // The Gardener was busy when this front end connected, with a helper
        // out that reports back moments later.
        var gardenerListed = SessionState(id: "gardener", name: "Gardener")
        gardenerListed.status = .running
        gardenerListed.lastSeq = 3
        StubServer.roster = [gardenerListed]
        server.connect()
        await wait(for: "live") { server.phase == .live }
        let gardener = try XCTUnwrap(server.session("gardener"))
        XCTAssertTrue(gardener.isCatchingUp)

        let silence = Silence()
        let narrator = Narrator(engine: silence, log: server.log)
        func listen() {
            let speakers = server.sessions.map {
                Narrator.Speaker(id: $0.id, name: $0.name, messages: $0.newMessages, isWorking: $0.status == .running)
            }
            narrator.listen(to: speakers, inEarshot: [])
        }

        let away = Date(timeIntervalSince1970: (Date().timeIntervalSince1970 - 3600).rounded()) // an hour ago
        let helper = Subagent(id: "s1", task: "Count the snails")
        StubServer.push(EventEnvelope(seq: 1, event: .conversationStarted(conversationID: "g1"), time: away), to: "gardener")
        StubServer.push(EventEnvelope(seq: 2, event: .statusChanged(.running, stopReason: nil), time: away), to: "gardener")
        StubServer.push(EventEnvelope(seq: 3, event: .subagentStarted(helper), time: away), to: "gardener") // replayed
        await wait(for: "the replay") { gardener.state.lastSeq == 3 }
        listen()
        StubServer.push(EventEnvelope(seq: 4, event: .subagentFinished(subagentID: "s1")), to: "gardener") // live, but still the old job
        StubServer.push(EventEnvelope(seq: 5, event: .message(Message(id: "m1", kind: .agent, speaker: "Gardener", text: "Twelve snails."))), to: "gardener")
        await wait(for: "the report") { gardener.transcript.count == 1 }
        listen()
        StubServer.push(EventEnvelope(seq: 6, event: .statusChanged(.idle, stopReason: .endTurn)), to: "gardener")
        await wait(for: "the job to end") { gardener.status == .idle }
        listen()

        XCTAssertFalse(gardener.isCatchingUp)
        XCTAssertTrue(gardener.newMessages.isEmpty)
        // Kept for a missed call, which only the narrator's speakers carry.
        XCTAssertEqual(gardener.finishedWhileAway.map(\.id), ["m1"])
        XCTAssertTrue(narrator.calls.isEmpty)
        XCTAssertFalse(narrator.hasSomethingToSay("gardener"))
        await Task.yield()
        XCTAssertTrue(silence.said.isEmpty)
        XCTAssertEqual(server.log.entries.map(\.kind), [.helperSent, .helperBack, .reply, .jobDone])
        XCTAssertTrue(server.log.entries.allSatisfy(\.isWhileAway))
        XCTAssertEqual(server.log.entries.first?.time, away)
        XCTAssertEqual(server.log.entries.first?.text, "Sent a helper off: Count the snails")

        // The next job, while you're here, is said or rung as ever.
        StubServer.push(EventEnvelope(seq: 7, event: .statusChanged(.running, stopReason: nil)), to: "gardener")
        StubServer.push(EventEnvelope(seq: 8, event: .message(Message(id: "m2", kind: .agent, speaker: "Gardener", text: "The roses are in."))), to: "gardener")
        StubServer.push(EventEnvelope(seq: 9, event: .statusChanged(.idle, stopReason: .endTurn)), to: "gardener")
        await wait(for: "the second job") { gardener.state.lastSeq == 9 }
        listen()
        XCTAssertEqual(gardener.newMessages.map(\.id), ["m2"])
        XCTAssertEqual(narrator.calls.first?.lines, ["The roses are in."])
        XCTAssertEqual(server.log.entries.suffix(3).map(\.kind), [.reply, .jobDone, .call])
        XCTAssertTrue(server.log.entries.suffix(3).allSatisfy { !$0.isWhileAway })

        server.disconnect()
    }

    func testAnsweringACharacterEndsCatchingUp() async throws {
        let (server, _) = makeConnection()
        var builderListed = SessionState(id: "builder", name: "Builder")
        builderListed.status = .running
        builderListed.lastSeq = 2
        StubServer.roster = [builderListed]
        server.connect()
        await wait(for: "live") { server.phase == .live }
        let builder = try XCTUnwrap(server.session("builder"))
        StubServer.push(EventEnvelope(seq: 1, event: .conversationStarted(conversationID: "b1")), to: "builder")
        StubServer.push(EventEnvelope(seq: 2, event: .statusChanged(.running, stopReason: nil)), to: "builder")
        await wait(for: "the replay") { builder.state.lastSeq == 2 }
        XCTAssertTrue(builder.isCatchingUp)

        await builder.send("Make it a café instead.")
        XCTAssertFalse(builder.isCatchingUp)
        XCTAssertTrue(builder.finishedWhileAway.isEmpty)
        StubServer.push(EventEnvelope(seq: 3, event: .message(Message(id: "m1", kind: .agent, speaker: "Builder", text: "A café it is."))), to: "builder")
        await wait(for: "the answer") { builder.newMessages.count == 1 }

        server.disconnect()
    }

    func testOffersTheVoiceModelAtTheServersAddress() {
        let (server, _) = makeConnection(url: URL(string: "https://my-mac.example.ts.net"))
        XCTAssertEqual(server.voiceModelURL?.absoluteString, "https://my-mac.example.ts.net/v1/voice/")
        XCTAssertEqual(server.voiceModelURL?.appending(path: "voices/Sir Bramwell.safetensors").path, "/v1/voice/voices/Sir Bramwell.safetensors")
        server.setServerURL("")
        XCTAssertNil(server.voiceModelURL)
    }

    func testFollowsTheLot() async throws {
        let (server, _) = makeConnection()
        server.connect()
        await wait(for: "live") { server.phase == .live }
        XCTAssertEqual(server.lot, Lot())
        XCTAssertTrue(StubServer.requests.contains { $0.url.path == "/v1/lot/events" })

        let restaurant = LotItem(
            id: "buildings/restaurant.md", category: .building, kind: "restaurant", name: "Luigi's",
            area: LotArea(x: 20, y: 30, width: 5, depth: 4)
        )
        StubServer.pushLot(Lot(revision: 1, items: [restaurant]))
        await wait(for: "the restaurant") { server.lot.items == [restaurant] }

        let roses = LotItem(
            id: "garden/roses.md", category: .plant, kind: "rose", name: "Roses",
            area: LotArea(x: 40, y: 30, width: 3, depth: 1), color: "#D02030"
        )
        StubServer.pushLot(Lot(revision: 2, items: [restaurant, roses]))
        await wait(for: "the roses") { server.lot.revision == 2 }
        XCTAssertEqual(server.lot.items.map(\.kind), ["restaurant", "rose"])

        server.disconnect()
    }

    func testAServerWithoutALotStillHasItsSessionsFollowed() async throws {
        let (server, _) = makeConnection()
        StubServer.hasLot = false
        server.connect()
        await wait(for: "live") { server.phase == .live }
        let gardener = try XCTUnwrap(server.session("gardener"))
        StubServer.push(EventEnvelope(seq: 1, event: .conversationStarted(conversationID: "g1")), to: "gardener")
        await wait(for: "events") { gardener.state.conversationID == "g1" }
        XCTAssertEqual(server.lot, Lot())
        server.disconnect()
    }

    func testFollowsTheUsage() async throws {
        let (server, _) = makeConnection()
        server.connect()
        await wait(for: "live") { server.phase == .live }
        await wait(for: "the usage's stream") { StubServer.requests.contains { $0.url.path == "/v1/usage/events" } }
        XCTAssertEqual(server.usage, Usage())

        let window = UsageWindow(utilization: 0.46, resetsAt: Date(timeIntervalSince1970: 1_795_366_800), readAt: Date(timeIntervalSince1970: 1_795_360_000))
        StubServer.pushUsage(Usage(revision: 1, window: window))
        await wait(for: "the usage") { server.usage.window == window }

        server.setServerURL("https://another.invalid")
        XCTAssertEqual(server.usage, Usage())
        server.disconnect()
    }

    func testFollowsHowFullEachSessionIsWithoutLoggingIt() async throws {
        let (server, _) = makeConnection()
        server.connect()
        await wait(for: "live") { server.phase == .live }
        let builder = try XCTUnwrap(server.session("builder"))
        await wait(for: "the builder's stream") { streamRequests.contains { $0.url.path == "/v1/sessions/builder/events" } }
        XCTAssertNil(builder.context)

        StubServer.push(EventEnvelope(seq: 1, event: .conversationStarted(conversationID: "b1")), to: "builder")
        StubServer.push(EventEnvelope(seq: 2, event: .statusChanged(.idle, stopReason: .endTurn)), to: "builder")
        await wait(for: "the builder's status") { builder.state.lastSeq == 2 }
        let logged = server.log.entries.count
        let context = SessionContext(model: "claude-opus-4-7", usedTokens: 84_000, compactsAt: 167_000)
        StubServer.push(EventEnvelope(seq: 3, event: .contextChanged(context)), to: "builder")
        await wait(for: "the context") { builder.context == context }
        XCTAssertEqual(server.log.entries.count, logged)

        server.disconnect()
    }

    func testAServerThatDoesntTellTheUsageStillHasItsSessionsFollowed() async throws {
        let (server, _) = makeConnection()
        StubServer.hasUsage = false
        server.connect()
        await wait(for: "live") { server.phase == .live }
        let gardener = try XCTUnwrap(server.session("gardener"))
        StubServer.push(EventEnvelope(seq: 1, event: .conversationStarted(conversationID: "g1")), to: "gardener")
        await wait(for: "events") { gardener.state.conversationID == "g1" }
        XCTAssertEqual(server.usage, Usage())
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
    nonisolated(unsafe) private static var _hasLot = true
    nonisolated(unsafe) private static var _hasUsage = true

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

    /// Whether it serves the lot, as servers from before there was
    /// anything to build don't.
    static var hasLot: Bool {
        get { lock.withLock { _hasLot } }
        set { lock.withLock { _hasLot = newValue } }
    }

    /// Whether it tells the usage, as servers from before it did don't.
    static var hasUsage: Bool {
        get { lock.withLock { _hasUsage } }
        set { lock.withLock { _hasUsage = newValue } }
    }

    static func reset() {
        lock.withLock {
            _requests = []
            streams = [:]
            _roster = [SessionState(id: "gardener", name: "Gardener"), SessionState(id: "builder", name: "Builder")]
            _failPosts = nil
            _hasLot = true
            _hasUsage = true
        }
    }

    static func push(_ envelope: EventEnvelope, to sessionID: String) {
        guard let stream = lock.withLock({ streams[sessionID] }) else { return }
        let json = String(decoding: try! JSONEncoder().encode(envelope), as: UTF8.self)
        stream.client?.urlProtocol(stream, didLoad: Data("id: \(envelope.seq)\nevent: \(envelope.event.type)\ndata: \(json)\n\n".utf8))
    }

    /// Sends the whole lot down the lot's stream.
    static func pushLot(_ lot: Lot) {
        guard let stream = lock.withLock({ streams["lot"] }) else { return }
        let json = String(decoding: try! JSONEncoder().encode(lot), as: UTF8.self)
        stream.client?.urlProtocol(stream, didLoad: Data("id: \(lot.revision)\nevent: lot\ndata: \(json)\n\n".utf8))
    }

    /// Sends the usage down the usage's stream.
    static func pushUsage(_ usage: Usage) {
        guard let stream = lock.withLock({ streams["usage"] }) else { return }
        let json = String(decoding: try! JSONEncoder().encode(usage), as: UTF8.self)
        stream.client?.urlProtocol(stream, didLoad: Data("id: \(usage.revision)\nevent: usage\ndata: \(json)\n\n".utf8))
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

        if method == "GET", url.path == "/v1/lot/events", !Self.hasLot {
            respond(404, body: #"{"error":true,"reason":"Not Found"}"#)
        } else if method == "GET", url.path == "/v1/usage/events", !Self.hasUsage {
            respond(404, body: #"{"error":true,"reason":"Not Found"}"#)
        } else if method == "GET", url.path.hasSuffix("/events") {
            // A session's stream is kept under its id, the lot's under
            // "lot" and the usage's under "usage".
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
