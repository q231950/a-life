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
        StubServer.requests.filter {
            $0.url.path.hasPrefix("/v1/sessions/") && $0.url.path.hasSuffix("/events") && $0.url.path != "/v1/sessions/events"
        }
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
        // Everything comes from the init call, not the list of sessions.
        XCTAssertTrue(StubServer.requests.contains { $0.url.path == "/v1/init" })
        XCTAssertFalse(StubServer.requests.contains { $0.url.path == "/v1/sessions" })
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
        StubServer.roster = [StubServer.roster[0], SessionState(id: "painter", name: "Painter")]
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
        StubServer.roster = [SessionState(id: "gardener", name: "Gardener")]
        let before = Message(id: "m1", kind: .agent, speaker: "Gardener", text: "I watered the roses.")
        let after = Message(id: "m2", kind: .agent, speaker: "Gardener", text: "The tulips are up.")
        let missed = [
            EventEnvelope(seq: 1, event: .conversationStarted(conversationID: "g1")),
            EventEnvelope(seq: 2, event: .message(before)),
            EventEnvelope(seq: 3, event: .statusChanged(.idle, stopReason: .endTurn)),
        ]
        for envelope in missed { StubServer.push(envelope, to: "gardener") }
        server.connect()
        await wait(for: "live") { server.phase == .live }
        let gardener = try XCTUnwrap(server.session("gardener"))
        // It has the whole conversation from the start, in one go.
        XCTAssertEqual(gardener.transcript, [before])

        // What the server sends again goes to the log only.
        for envelope in missed { StubServer.replay(envelope, to: "gardener") }
        StubServer.push(EventEnvelope(seq: 4, event: .message(after)), to: "gardener") // live
        await wait(for: "the live message") { gardener.transcript.count == 2 }
        XCTAssertEqual(gardener.transcript, [before, after])
        XCTAssertEqual(gardener.newMessages, [after])

        server.disconnect()
    }

    func testTakesOnEverythingAtOnceWhenItConnects() async throws {
        let (server, _) = makeConnection()
        // While nobody watched, the Builder sent two helpers off, one came
        // back, and it asked you something; a restaurant went up.
        StubServer.roster = [SessionState(id: "builder", name: "Builder", color: "#F2A633")]
        let first = Subagent(id: "s1", task: "Measure the north corner")
        let second = Subagent(id: "s2", task: "Fetch the bricks")
        let approval = Approval(id: "p1", toolName: "bash", input: "mv shed.md buildings/")
        let missed = [
            EventEnvelope(seq: 1, event: .conversationStarted(conversationID: "b1")),
            EventEnvelope(seq: 2, event: .statusChanged(.running, stopReason: nil)),
            EventEnvelope(seq: 3, event: .subagentStarted(first)),
            EventEnvelope(seq: 4, event: .subagentStarted(second)),
            EventEnvelope(seq: 5, event: .subagentFinished(subagentID: "s1")),
            EventEnvelope(seq: 6, event: .message(Message(id: "m1", kind: .agent, speaker: "Builder", text: "May I move the shed?"))),
            EventEnvelope(seq: 7, event: .approvalRequested(approval)),
            EventEnvelope(seq: 8, event: .statusChanged(.idle, stopReason: .requiresAction)),
        ]
        for envelope in missed { StubServer.push(envelope, to: "builder") }
        let restaurant = LotItem(
            id: "buildings/restaurant.md", category: .building, kind: "restaurant", name: "Luigi's",
            area: LotArea(x: 20, y: 30, width: 5, depth: 4)
        )
        StubServer.lot = Lot(revision: 3, items: [restaurant])
        let window = UsageWindow(utilization: 0.46, resetsAt: Date(timeIntervalSince1970: 1_795_366_800), readAt: Date(timeIntervalSince1970: 1_795_360_000))
        StubServer.usage = Usage(revision: 2, window: window)

        server.connect()
        await wait(for: "the snapshot") { server.session("builder") != nil }
        let builder = try XCTUnwrap(server.session("builder"))
        // All of it is there at once, as the server has it, without going
        // through how it got there.
        XCTAssertEqual(builder.state, StubServer.roster[0])
        XCTAssertEqual(builder.subagents, [second])
        XCTAssertEqual(builder.pendingApprovals, [approval])
        XCTAssertEqual(server.lot, StubServer.lot)
        XCTAssertFalse(server.lotIsNews) // so it doesn't pop up
        XCTAssertEqual(server.usage, StubServer.usage)
        XCTAssertTrue(builder.newMessages.isEmpty)
        // It is waiting for you, so it leaves a missed call.
        XCTAssertFalse(builder.isCatchingUp)
        XCTAssertEqual(builder.finishedWhileAway.map(\.id), ["m1"])

        // It follows on from where it had got to, which was nowhere.
        await wait(for: "live") { server.phase == .live }
        XCTAssertEqual(streamRequests.last?.url.query, "after=0")
        // What the server sends again is written down, as while you were
        // away, but changes nothing: the helper that came back stays gone.
        for envelope in missed { StubServer.replay(envelope, to: "builder") }
        await wait(for: "the log") { server.log.entries.count == 5 }
        XCTAssertEqual(server.log.entries.map(\.kind), [.helperSent, .helperSent, .helperBack, .reply, .waitingForYou])
        XCTAssertTrue(server.log.entries.allSatisfy(\.isWhileAway))
        XCTAssertEqual(builder.state, StubServer.roster[0])

        // What comes after the snapshot happens now.
        StubServer.push(EventEnvelope(seq: 9, event: .approvalResolved(approvalID: "p1", outcome: .allowed)), to: "builder")
        StubServer.push(EventEnvelope(seq: 10, event: .subagentFinished(subagentID: "s2")), to: "builder")
        await wait(for: "the live events") { builder.state.lastSeq == 10 }
        XCTAssertTrue(builder.subagents.isEmpty)
        XCTAssertFalse(builder.isWaitingForYou)
        XCTAssertEqual(server.log.entries.last?.kind, .helperBack)
        XCTAssertEqual(server.log.entries.last?.isWhileAway, false)

        server.disconnect()
    }

    func testReconnectingTakesOnWhatWasMissedAtOnce() async throws {
        let (server, _) = makeConnection()
        server.connect()
        await wait(for: "live") { server.phase == .live }
        let builder = try XCTUnwrap(server.session("builder"))
        StubServer.push(EventEnvelope(seq: 1, event: .conversationStarted(conversationID: "b1")), to: "builder")
        StubServer.push(EventEnvelope(seq: 2, event: .statusChanged(.running, stopReason: nil)), to: "builder")
        await wait(for: "events") { builder.status == .running }

        // The connection drops, and the Builder carries on meanwhile.
        StubServer.dropStream("builder")
        let helper = Subagent(id: "s1", task: "Fetch the bricks")
        let missed = [
            EventEnvelope(seq: 3, event: .subagentStarted(helper)),
            EventEnvelope(seq: 4, event: .subagentFinished(subagentID: "s1")),
            EventEnvelope(seq: 5, event: .message(Message(id: "m1", kind: .agent, speaker: "Builder", text: "The shed is moved."))),
            EventEnvelope(seq: 6, event: .statusChanged(.idle, stopReason: .endTurn)),
        ]
        for envelope in missed { StubServer.push(envelope, to: "builder") }

        // Back again, it has where things stand at once: the helper never
        // shows, and the job is done.
        await wait(for: "reconnect") { streamRequests.count == 4 && server.phase == .live }
        XCTAssertEqual(builder.state, StubServer.roster[1])
        XCTAssertTrue(builder.subagents.isEmpty)
        XCTAssertTrue(builder.newMessages.isEmpty)
        // It follows on from where it had got to before, for the log.
        let query = try XCTUnwrap(streamRequests.last { $0.url.path == "/v1/sessions/builder/events" }?.url.query)
        XCTAssertTrue(query.contains("after=2") && query.contains("conversation=b1"), query)
        for envelope in missed { StubServer.replay(envelope, to: "builder") }
        await wait(for: "the log") { server.log.entries.count == 4 }
        XCTAssertEqual(server.log.entries.map(\.kind), [.helperSent, .helperBack, .reply, .jobDone])
        XCTAssertTrue(server.log.entries.allSatisfy(\.isWhileAway))
        XCTAssertEqual(builder.state, StubServer.roster[1])

        server.disconnect()
    }

    func testAServerWithoutAnInitCallIsCaughtUpFromItsListOfSessions() async throws {
        let (server, _) = makeConnection()
        StubServer.hasInit = false
        StubServer.push(EventEnvelope(seq: 1, event: .conversationStarted(conversationID: "g1")), to: "gardener")
        StubServer.push(EventEnvelope(seq: 2, event: .statusChanged(.running, stopReason: nil)), to: "gardener")
        server.connect()
        await wait(for: "live") { server.phase == .live }
        XCTAssertTrue(StubServer.requests.contains { $0.url.path == "/v1/sessions" })
        let gardener = try XCTUnwrap(server.session("gardener"))
        XCTAssertEqual(gardener.state, StubServer.roster[0])
        XCTAssertEqual(gardener.status, .running)
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
        StubServer.roster = [SessionState(id: "gardener", name: "Gardener")]
        let away = Date(timeIntervalSince1970: (Date().timeIntervalSince1970 - 3600).rounded()) // an hour ago
        let helper = Subagent(id: "s1", task: "Count the snails")
        let missed = [
            EventEnvelope(seq: 1, event: .conversationStarted(conversationID: "g1"), time: away),
            EventEnvelope(seq: 2, event: .statusChanged(.running, stopReason: nil), time: away),
            EventEnvelope(seq: 3, event: .subagentStarted(helper), time: away),
        ]
        for envelope in missed { StubServer.push(envelope, to: "gardener") }
        server.connect()
        await wait(for: "live") { server.phase == .live }
        let gardener = try XCTUnwrap(server.session("gardener"))
        XCTAssertTrue(gardener.isCatchingUp)
        XCTAssertEqual(gardener.subagents, [helper])

        let silence = Silence()
        let narrator = Narrator(engine: silence, log: server.log)
        func listen() {
            let speakers = server.sessions.map {
                Narrator.Speaker(id: $0.id, name: $0.name, messages: $0.newMessages, isWorking: $0.status == .running)
            }
            narrator.listen(to: speakers, inEarshot: [])
        }

        for envelope in missed { StubServer.replay(envelope, to: "gardener") }
        await wait(for: "the replay") { server.log.entries.count == 1 }
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
        StubServer.roster = [SessionState(id: "builder", name: "Builder")]
        StubServer.push(EventEnvelope(seq: 1, event: .conversationStarted(conversationID: "b1")), to: "builder")
        StubServer.push(EventEnvelope(seq: 2, event: .statusChanged(.running, stopReason: nil)), to: "builder")
        server.connect()
        await wait(for: "live") { server.phase == .live }
        let builder = try XCTUnwrap(server.session("builder"))
        XCTAssertEqual(builder.state.lastSeq, 2)
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

    func testFollowsWhoIsOnTheLotAsAgentsJoinAndLeave() async throws {
        let (server, _) = makeConnection()
        server.connect()
        await wait(for: "live") { server.phase == .live }
        XCTAssertTrue(StubServer.requests.contains { $0.url.path == "/v1/sessions/events" })
        let gardener = try XCTUnwrap(server.session("gardener"))
        XCTAssertEqual(StubServer.requests.filter { $0.url.path == "/v1/init" }.count, 1)

        // The same roster again changes nothing: nobody reconnects.
        StubServer.pushRoster(Roster(revision: 1, sessions: ["gardener", "builder"]))
        try await Task.sleep(nanoseconds: 100_000_000)
        XCTAssertEqual(StubServer.requests.filter { $0.url.path == "/v1/init" }.count, 1)

        // The Team Lead adds a Plumber: it appears, and is followed.
        StubServer.roster.append(SessionState(id: "plumber", name: "Plumber", color: "#2266AA"))
        StubServer.pushRoster(Roster(revision: 2, sessions: ["gardener", "builder", "plumber"]))
        await wait(for: "the Plumber") { server.sessions.map(\.id) == ["gardener", "builder", "plumber"] }
        XCTAssertEqual(server.session("plumber")?.name, "Plumber")
        XCTAssertEqual(server.session("plumber")?.color, "#2266AA")
        // The ones that were there are the same, and it never looked as if
        // the connection had dropped.
        XCTAssertTrue(server.session("gardener") === gardener)
        XCTAssertEqual(server.phase, .live)
        await wait(for: "the Plumber's events") { StubServer.requests.contains { $0.url.path == "/v1/sessions/plumber/events" } }
        try await Task.sleep(nanoseconds: 100_000_000)
        StubServer.push(EventEnvelope(seq: 1, event: .conversationStarted(conversationID: "p1")), to: "plumber")
        await wait(for: "the Plumber's conversation") { server.session("plumber")?.state.conversationID == "p1" }

        // It is taken away again, and the others carry on.
        StubServer.roster.removeAll { $0.id == "plumber" }
        StubServer.pushRoster(Roster(revision: 3, sessions: ["gardener", "builder"]))
        await wait(for: "the Plumber to go") { server.sessions.map(\.id) == ["gardener", "builder"] }
        XCTAssertNil(server.session("plumber"))
        XCTAssertTrue(server.session("gardener") === gardener)
        XCTAssertEqual(server.phase, .live)
        server.disconnect()
    }

    func testAServerThatDoesntTellWhoIsOnTheLotStillHasItsSessionsFollowed() async throws {
        let (server, _) = makeConnection()
        StubServer.hasRoster = false
        server.connect()
        await wait(for: "live") { server.phase == .live }
        let gardener = try XCTUnwrap(server.session("gardener"))
        StubServer.push(EventEnvelope(seq: 1, event: .conversationStarted(conversationID: "g1")), to: "gardener")
        await wait(for: "events") { gardener.state.conversationID == "g1" }
        server.disconnect()
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
        XCTAssertTrue(server.lotIsNews) // it went up while you watched

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

    func testFollowsEachCharactersModelAndSwitchesIt() async throws {
        let (server, _) = makeConnection()
        var builderState = SessionState(id: "builder", name: "Builder")
        builderState.model = .haiku
        builderState.fileModel = .haiku
        StubServer.roster = [SessionState(id: "gardener", name: "Gardener"), builderState]
        // One this version doesn't know is left out.
        StubServer.models = #"[{"model":"fable","name":"Fable 5.2"},{"model":"mythos","name":"Mythos 1"},{"model":"opus","name":"Opus 5.5","description":"For complex work and everyday tasks","resolved":"claude-opus-5-5"},{"model":"sonnet"},{"model":"haiku","name":"Haiku 5.5"}]"#
        server.connect()
        await wait(for: "live, with the models") { server.phase == .live && !server.models.isEmpty }
        XCTAssertEqual(server.models.map(\.displayName), ["Fable 5.2", "Opus 5.5", "Sonnet", "Haiku 5.5"])
        let builder = try XCTUnwrap(server.session("builder"))
        let gardener = try XCTUnwrap(server.session("gardener"))
        XCTAssertEqual(builder.model, .haiku)
        XCTAssertNil(gardener.model)
        XCTAssertEqual(builder.modelName(among: server.models), "Haiku 5.5") // before it has started
        XCTAssertEqual(gardener.modelName(among: server.models), "Default model")

        await builder.setModel(.opus)
        XCTAssertEqual(builder.model, .opus)
        let put = try XCTUnwrap(StubServer.requests.last)
        XCTAssertEqual(put.method, "PUT")
        XCTAssertEqual(put.url.path, "/v1/sessions/builder/model")
        XCTAssertEqual(try JSONDecoder().decode(ModelChoiceRequest.self, from: XCTUnwrap(put.body)).model, .opus)

        // The event brings it to every front end, and starting over keeps it.
        StubServer.push(EventEnvelope(seq: 1, event: .conversationStarted(conversationID: "b1")), to: "builder")
        StubServer.push(EventEnvelope(seq: 2, event: .modelChanged(.sonnet, fileModel: .haiku)), to: "builder")
        await wait(for: "the model from another front end") { builder.model == .sonnet }
        StubServer.push(EventEnvelope(seq: 3, event: .conversationStarted(conversationID: "b2")), to: "builder")
        await wait(for: "the new conversation") { builder.state.conversationID == "b2" }
        XCTAssertEqual(builder.model, .sonnet)
        XCTAssertEqual(builder.fileModel, .haiku)

        // Back to the agents file's, which is said as null.
        await builder.setModel(nil)
        XCTAssertEqual(builder.model, .haiku)
        let back = try XCTUnwrap(StubServer.requests.last?.body)
        XCTAssertEqual(String(decoding: back, as: UTF8.self), #"{"model":null}"#)

        // Refused, it goes back to what it was.
        StubServer.failPosts = (400, "\"opus-5\" isn't one of the models a character can run on")
        await builder.setModel(.fable)
        XCTAssertEqual(builder.model, .haiku)
        XCTAssertNotNil(builder.lastError)
        server.disconnect()
    }

    func testAServerWithoutModelsOffersNone() async throws {
        let (server, _) = makeConnection()
        server.connect()
        await wait(for: "live") { server.phase == .live }
        await wait(for: "the models asked for") { StubServer.requests.contains { $0.url.path == "/v1/models" } }
        try await Task.sleep(nanoseconds: 50_000_000)
        XCTAssertTrue(server.models.isEmpty) // so there's no picker
        XCTAssertNil(server.session("builder")?.model)
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
    nonisolated(unsafe) private static var _hasRoster = true
    nonisolated(unsafe) private static var _models: String?
    nonisolated(unsafe) private static var _pushEnabled = true
    nonisolated(unsafe) private static var _hasInit = true
    nonisolated(unsafe) private static var _lot = Lot()
    nonisolated(unsafe) private static var _usage = Usage()

    static var requests: [Recorded] { lock.withLock { _requests } }
    /// The sessions as the server has them, which `GET /v1/init` and
    /// `GET /v1/sessions` answer with. `push(_:to:)` moves them on.
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

    /// What `GET /v1/models` answers, or `nil` for a 404, as servers from
    /// before characters had models give.
    static var models: String? {
        get { lock.withLock { _models } }
        set { lock.withLock { _models = newValue } }
    }

    /// Whether it tells who is on the lot, as servers from before agents
    /// could join and leave don't.
    static var hasRoster: Bool {
        get { lock.withLock { _hasRoster } }
        set { lock.withLock { _hasRoster = newValue } }
    }

    /// Whether it tells the usage, as servers from before it did don't.
    static var hasUsage: Bool {
        get { lock.withLock { _hasUsage } }
        set { lock.withLock { _hasUsage = newValue } }
    }

    /// Whether it answers `GET /v1/init`, as servers from before there was
    /// one don't.
    static var hasInit: Bool {
        get { lock.withLock { _hasInit } }
        set { lock.withLock { _hasInit = newValue } }
    }

    /// The lot `GET /v1/init` answers with.
    static var lot: Lot {
        get { lock.withLock { _lot } }
        set { lock.withLock { _lot = newValue } }
    }

    /// The usage `GET /v1/init` answers with.
    static var usage: Usage {
        get { lock.withLock { _usage } }
        set { lock.withLock { _usage = newValue } }
    }

    /// Whether it says it sends notifications when a device registers.
    static var pushEnabled: Bool {
        get { lock.withLock { _pushEnabled } }
        set { lock.withLock { _pushEnabled = newValue } }
    }

    static func reset() {
        lock.withLock {
            _pushEnabled = true
            _requests = []
            streams = [:]
            _roster = [SessionState(id: "gardener", name: "Gardener"), SessionState(id: "builder", name: "Builder")]
            _failPosts = nil
            _hasLot = true
            _hasUsage = true
            _hasRoster = true
            _models = nil
            _hasInit = true
            _lot = Lot()
            _usage = Usage()
        }
    }

    /// Something happens in a session: the server's snapshot of it moves
    /// on, and the event goes down its stream, if one is open.
    static func push(_ envelope: EventEnvelope, to sessionID: String) {
        lock.withLock {
            if let index = _roster.firstIndex(where: { $0.id == sessionID }) {
                _roster[index].apply(envelope)
            }
        }
        replay(envelope, to: sessionID)
    }

    /// Sends an event the server had already down a session's stream, as
    /// it does for a client that follows on from further back than the
    /// snapshot it was given.
    static func replay(_ envelope: EventEnvelope, to sessionID: String) {
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

    /// Sends who is on the lot down the roster's stream.
    static func pushRoster(_ roster: Roster) {
        guard let stream = lock.withLock({ streams["roster"] }) else { return }
        let json = String(decoding: try! JSONEncoder().encode(roster), as: UTF8.self)
        stream.client?.urlProtocol(stream, didLoad: Data("id: \(roster.revision)\nevent: roster\ndata: \(json)\n\n".utf8))
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
        } else if method == "GET", url.path == "/v1/sessions/events", !Self.hasRoster {
            respond(404, body: #"{"error":true,"reason":"Not Found"}"#)
        } else if method == "GET", url.path == "/v1/sessions/events" {
            respond(200, contentType: "text/event-stream", body: ": connected\n\n", finish: false)
            Self.lock.withLock { Self.streams["roster"] = self } // stays open
        } else if method == "GET", url.path.hasSuffix("/events") {
            // A session's stream is kept under its id, the lot's under
            // "lot", the usage's under "usage" and the roster's under "roster".
            let sessionID = url.deletingLastPathComponent().lastPathComponent
            respond(200, contentType: "text/event-stream", body: ": connected\n\n", finish: false)
            Self.lock.withLock { Self.streams[sessionID] = self } // stays open
        } else if method == "GET", url.path == "/v1/models" {
            if let models = Self.models {
                respond(200, body: models)
            } else {
                respond(404, body: #"{"error":true,"reason":"Not Found"}"#)
            }
        } else if method == "GET", url.path == "/v1/init" {
            if Self.hasInit {
                let initial = InitialState(sessions: Self.roster, lot: Self.lot, usage: Self.usage)
                respond(200, body: String(decoding: try! JSONEncoder().encode(initial), as: UTF8.self))
            } else {
                respond(404, body: #"{"error":true,"reason":"Not Found"}"#)
            }
        } else if method == "GET", url.path == "/v1/sessions" {
            respond(200, body: String(decoding: try! JSONEncoder().encode(Self.roster), as: UTF8.self))
        } else if method == "PUT", url.path.hasPrefix("/v1/devices/") {
            // Each address is a server of its own, with its host for its id.
            respond(200, body: #"{"server_id":"\#(url.host ?? "")","push_enabled":\#(Self.pushEnabled)}"#)
        } else if method == "DELETE", url.path.hasPrefix("/v1/devices/") {
            respond(204, body: "")
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
