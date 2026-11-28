import ALifeClient
@testable import ALifeServer
import Vapor
import XCTest
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif

/// Runs the real client package against the real server, over HTTP on a
/// local port, with the dummy characters playing at speed.
@MainActor
final class ALifeServerTests: XCTestCase {
    private var app: Application!
    private var baseURL: URL!

    override func setUp() async throws {
        // Arguments of its own, rather than `.testing`'s, which some test
        // runners leave the test bundle in, for Vapor to take as a command.
        app = try await Application.make(Environment(name: "testing", arguments: ["vapor"]))
        try await configure(app, players: .dummies(step: .milliseconds(20)), cast: [.birdwatcher, .builder, .engineer])
        app.http.server.configuration.hostname = "127.0.0.1"
        app.http.server.configuration.port = 0 // any free port
        try await app.startup()
        let port = try XCTUnwrap(app.http.server.shared.localAddress?.port)
        baseURL = try XCTUnwrap(URL(string: "http://127.0.0.1:\(port)"))
    }

    override func tearDown() async throws {
        try await app.asyncShutdown()
    }

    private func wait(
        for description: String,
        file: StaticString = #filePath,
        line: UInt = #line,
        until condition: () -> Bool
    ) async {
        for _ in 0..<1000 where !condition() {
            try? await Task.sleep(nanoseconds: 10_000_000)
        }
        XCTAssertTrue(condition(), "timed out waiting for \(description)", file: file, line: line)
    }

    private func connect() async throws -> (ServerConnection, birdwatcher: AgentSession, builder: AgentSession) {
        let server = ServerConnection(serverURLStore: InMemoryServerURLStore(baseURL), urlSession: URLSession(configuration: .ephemeral))
        server.connect()
        await wait(for: "live") { server.phase == .live && server.sessions.allSatisfy { $0.state.conversationID != nil } }
        return (server, try XCTUnwrap(server.session("birdwatcher")), try XCTUnwrap(server.session("builder")))
    }

    private func makeClient() -> ALifeServerClient {
        ALifeServerClient(baseURL: baseURL, urlSession: URLSession(configuration: .ephemeral))
    }

    func testEveryCharacterHasASessionOfItsOwn() async throws {
        let (server, birdwatcher, builder) = try await connect()
        XCTAssertEqual(server.sessions.map(\.name), ["Birdwatcher", "Builder", "a*life Engineer"])
        // Each wears its own colour; the a*life Engineer's shirt is purple.
        XCTAssertEqual(server.sessions.map(\.color), ["#D9594D", "#F2A633", "#8050C8"])
        XCTAssertEqual(birdwatcher.status, .idle)

        // The Birdwatcher only looks, so it never asks for anything.
        await birdwatcher.send("Look for snails")
        XCTAssertNil(birdwatcher.lastError)
        await wait(for: "the Birdwatcher to finish") { birdwatcher.stopReason == .endTurn }
        XCTAssertEqual(birdwatcher.transcript.map(\.speaker), ["You", "Birdwatcher"])
        XCTAssertEqual(birdwatcher.transcript.first?.text, "Look for snails")
        XCTAssertTrue(birdwatcher.transcript.last?.text.hasPrefix("Had a look around for “Look for snails”.") == true)
        XCTAssertNil(birdwatcher.activity)
        XCTAssertTrue(birdwatcher.subagents.isEmpty) // every helper reported back

        // None of that happened in the Builder's session.
        XCTAssertTrue(builder.transcript.isEmpty)
        XCTAssertEqual(builder.status, .idle)

        server.disconnect()
    }

    func testTheBuilderAsksBeforeItActs() async throws {
        let (server, birdwatcher, builder) = try await connect()

        await builder.send("Tidy the lot")
        await wait(for: "the approval") { builder.stopReason == .requiresAction }
        XCTAssertTrue(builder.isWaitingForYou)
        XCTAssertEqual(builder.pendingApprovals.map(\.toolName), ["bash"])

        // It can't be told anything else until it has an answer.
        await builder.send("What are you doing?")
        XCTAssertEqual(builder.lastError, "Builder is waiting for an answer to its request (HTTP 409)")
        XCTAssertEqual(builder.transcript.count, 1)
        // The Birdwatcher can, meanwhile.
        await birdwatcher.send("Look for snails")
        XCTAssertNil(birdwatcher.lastError)

        await builder.respond(to: builder.pendingApprovals[0], allow: false)
        await wait(for: "the end of the turn") { builder.stopReason == .endTurn }
        XCTAssertFalse(builder.isWaitingForYou)
        XCTAssertTrue(builder.transcript.last?.text.hasPrefix("Left the shed where it is") == true)
        // The request stays in the conversation, with your answer.
        XCTAssertTrue(builder.conversation.contains {
            if case .approval(let approval, .denied) = $0 { return approval.toolName == "bash" }
            return false
        })

        // A second front end joining late sees the same sessions.
        let (latecomer, lateBirdwatcher, lateBuilder) = try await connect()
        await wait(for: "the latecomer to catch up") { lateBuilder.state == builder.state }

        // Starting the Builder over empties it for both, and leaves the Birdwatcher be.
        await wait(for: "the Birdwatcher to finish") { birdwatcher.stopReason == .endTurn && lateBirdwatcher.stopReason == .endTurn }
        await builder.startOver()
        await wait(for: "the reset") { builder.transcript.isEmpty && lateBuilder.transcript.isEmpty }
        XCTAssertEqual(birdwatcher.transcript.count, 2)
        XCTAssertEqual(lateBirdwatcher.transcript, birdwatcher.transcript)

        server.disconnect()
        latecomer.disconnect()
    }

    func testAutoApproveIsEachCharactersOwn() async throws {
        let (server, birdwatcher, builder) = try await connect()
        XCTAssertFalse(builder.autoApprove)

        await builder.setAutoApprove(true)
        XCTAssertNil(builder.lastError)
        await wait(for: "auto approve") { builder.state.autoApprove }
        XCTAssertFalse(birdwatcher.autoApprove)
        let engineer = try XCTUnwrap(server.session("engineer"))
        XCTAssertFalse(engineer.autoApprove)

        // The Builder goes ahead without waiting, and its request is in the
        // conversation, settled as auto approved.
        await builder.send("Tidy the lot")
        await wait(for: "the end of the turn") { builder.stopReason == .endTurn }
        XCTAssertTrue(builder.transcript.last?.text.hasPrefix("Moved the shed") == true)
        XCTAssertTrue(builder.conversation.contains {
            if case .approval(let approval, .autoApproved) = $0 { return approval.toolName == "bash" }
            return false
        })

        // The Engineer still asks.
        await engineer.send("Tidy the lot")
        await wait(for: "the a*life Engineer's approval") { engineer.stopReason == .requiresAction }
        XCTAssertTrue(engineer.isWaitingForYou)
        // Turning it on for the a*life Engineer lets through what is waiting.
        await engineer.setAutoApprove(true)
        await wait(for: "the a*life Engineer to finish") { engineer.stopReason == .endTurn }
        XCTAssertTrue(engineer.conversation.contains {
            if case .approval(_, .autoApproved) = $0 { return true }
            return false
        })

        // Starting over keeps it on, for a front end joining late too.
        await builder.startOver()
        let (latecomer, _, lateBuilder) = try await connect()
        await wait(for: "the reset") { builder.transcript.isEmpty && lateBuilder.state == builder.state }
        XCTAssertTrue(builder.autoApprove)
        XCTAssertTrue(lateBuilder.autoApprove)

        // And turning it off asks again.
        await builder.setAutoApprove(false)
        await wait(for: "auto approve off") { !builder.autoApprove && !lateBuilder.autoApprove }
        await builder.send("Tidy the lot")
        await wait(for: "the approval") { builder.stopReason == .requiresAction }

        server.disconnect()
        latecomer.disconnect()
    }

    func testInterruptingStopsOnlyThatCharacter() async throws {
        let (server, birdwatcher, builder) = try await connect()

        await builder.send("Build a pond")
        await wait(for: "the approval") { builder.stopReason == .requiresAction }
        await birdwatcher.send("Water the roses")
        await builder.interrupt()
        await wait(for: "the interrupt") { builder.stopReason == .interrupted }
        XCTAssertFalse(builder.isWaitingForYou)
        XCTAssertEqual(builder.status, .idle)
        XCTAssertTrue(builder.conversation.contains {
            if case .approval(_, .withdrawn) = $0 { return true }
            return false
        })

        await wait(for: "the Birdwatcher to finish anyway") { birdwatcher.stopReason == .endTurn }
        XCTAssertEqual(builder.stopReason, .interrupted)

        server.disconnect()
    }

    func testSomethingSaidMidTaskIsAnsweredStraightAway() async throws {
        // A slow step, so the question surely arrives while the first one runs.
        let hub = SessionHub(id: "birdwatcher", name: "Birdwatcher")
        let birdwatcher = DummyCharacter(.birdwatcher, hub: hub, step: .milliseconds(300))
        await birdwatcher.reset()

        try await birdwatcher.handleMessage("Look for snails")
        try await birdwatcher.handleMessage("What are you doing?")
        for _ in 0..<600 where await hub.state.stopReason != .endTurn {
            try await Task.sleep(nanoseconds: 10_000_000)
        }

        let lines = await hub.state.messages.map { "\($0.speaker): \($0.text)" }
        XCTAssertEqual(lines.count, 4, "\(lines)")
        XCTAssertEqual(lines.prefix(3), [
            "You: Look for snails",
            "You: What are you doing?",
            "Birdwatcher: Still on “Look for snails”. Right now I'm looking around the lot.",
        ])
        XCTAssertTrue(lines.last?.hasPrefix("Birdwatcher: Had a look around") == true)
    }

    /// Plays a dummy's script for `instruction` and returns its events, up
    /// to where the dummy stops for `stopReason`.
    private func play(_ profile: Character, _ instruction: String, until stopReason: StopReason) async throws -> [SessionEvent] {
        let hub = SessionHub(id: profile.id, name: profile.name)
        let character = DummyCharacter(profile, hub: hub, step: .milliseconds(10))
        await character.reset()
        let stream = await hub.subscribe(conversationID: nil, after: 0)
        try await character.handleMessage(instruction)
        var events: [SessionEvent] = []
        for await envelope in stream {
            events.append(envelope.event)
            if envelope.event == .statusChanged(.idle, stopReason: stopReason) { break }
        }
        return events
    }

    func testTheBirdwatcherWaitsForItsHelpersToReportBack() async throws {
        let events = try await play(.birdwatcher, "Look for snails", until: .endTurn)

        var sent: [Subagent] = []
        var reported: [String] = []
        for event in events {
            if case .subagentStarted(let helper) = event { sent.append(helper) }
            if case .subagentFinished(let id) = event { reported.append(id) }
        }
        XCTAssertEqual(sent.map(\.task), ["Search the flower beds", "Check the hedges"])
        // The quicker errand comes back first, and nobody is left out.
        XCTAssertEqual(reported, sent.map(\.id))

        // It answers only once both have reported back.
        let lastReport = try XCTUnwrap(events.lastIndex { $0.type == "subagent.finished" })
        let answer = try XCTUnwrap(events.firstIndex { event in
            guard case .message(let message) = event else { return false }
            return message.kind == .agent
        })
        XCTAssertLessThan(lastReport, answer)
    }

    func testTheBuildersHelperIsBackBeforeItAsks() async throws {
        let events = try await play(.builder, "Tidy the lot", until: .requiresAction)
        let types = events.map(\.type).filter { $0.hasPrefix("subagent.") || $0.hasPrefix("approval.") }
        XCTAssertEqual(types, ["subagent.started", "subagent.finished", "approval.requested"])
        guard case .subagentStarted(let helper) = events.first(where: { $0.type == "subagent.started" }) else {
            return XCTFail("no helper was sent")
        }
        XCTAssertEqual(helper.task, "Measure the north corner")
    }

    func testInterruptingCallsTheHelpersBack() async throws {
        // Slow steps, so the helpers are surely still out.
        let hub = SessionHub(id: "birdwatcher", name: "Birdwatcher")
        let birdwatcher = DummyCharacter(.birdwatcher, hub: hub, step: .milliseconds(300))
        await birdwatcher.reset()
        try await birdwatcher.handleMessage("Look for snails")
        for _ in 0..<300 where await hub.state.subagents.count < 2 {
            try await Task.sleep(nanoseconds: 10_000_000)
        }
        var state = await hub.state
        XCTAssertEqual(state.subagents.count, 2)

        await birdwatcher.interrupt()
        state = await hub.state
        XCTAssertTrue(state.subagents.isEmpty)
        XCTAssertEqual(state.stopReason, .interrupted)

        // Nobody reports back afterwards, or is sent off again.
        let seq = state.lastSeq
        try await Task.sleep(nanoseconds: 1_000_000_000)
        state = await hub.state
        XCTAssertEqual(state.lastSeq, seq)
    }

    func testAReconnectingClientIsSentOnlyWhatItMissed() async throws {
        let client = makeClient()
        try await client.sendMessage("Plant a tree", to: "builder")

        var state = SessionState(id: "builder", name: "Builder", color: "#F2A633")
        for try await envelope in try await client.events(of: "builder") {
            state.apply(envelope)
            if state.stopReason == .requiresAction { break }
        }
        let seen = state.lastSeq
        try await client.decide(approvalID: XCTUnwrap(state.approvals.first).id, allow: true, in: "builder")

        var firstMissed: Int?
        for try await envelope in try await client.events(of: "builder", conversationID: state.conversationID, after: seen) {
            firstMissed = firstMissed ?? envelope.seq
            // Each says when it happened, so a front end catching up can tell.
            let time = try XCTUnwrap(envelope.time)
            XCTAssertLessThan(abs(time.timeIntervalSinceNow), 60)
            state.apply(envelope)
            if state.stopReason == .endTurn { break }
        }
        XCTAssertEqual(firstMissed, seen + 1)
        XCTAssertTrue(state.messages.last?.text.hasPrefix("Moved the shed") == true)
        let snapshot = try await client.state(of: "builder")
        XCTAssertEqual(snapshot, state)
        let listed = try await client.sessions()
        XCTAssertEqual(listed.map(\.id), ["birdwatcher", "builder", "engineer"])
        XCTAssertEqual(listed[1], state)

        // Naming a conversation the server doesn't have replays the current one in full.
        for try await envelope in try await client.events(of: "builder", conversationID: "gone", after: 999) {
            XCTAssertEqual(envelope.event, .conversationStarted(conversationID: try XCTUnwrap(state.conversationID)))
            break
        }
    }

    func testTheInitCallHasEverythingAndEventsCarryOnFromIt() async throws {
        let client = makeClient()
        try await client.sendMessage("Plant a tree", to: "builder")
        for try await envelope in try await client.events(of: "builder") {
            if envelope.event == .statusChanged(.idle, stopReason: .requiresAction) { break }
        }

        // Every session, the lot and the usage, as they are.
        let initial = try await client.initialState()
        let (listed, lot, usage) = (try await client.sessions(), try await client.lot(), try await client.usage())
        XCTAssertEqual(initial.sessions.map(\.id), ["birdwatcher", "builder", "engineer"])
        XCTAssertEqual(initial.sessions, listed)
        XCTAssertEqual(initial.lot, lot)
        XCTAssertEqual(initial.usage, usage)
        var builder = initial.sessions[1]
        XCTAssertEqual(builder.stopReason, .requiresAction)
        XCTAssertEqual(builder.messages.first?.text, "Plant a tree")

        // Followed from where it says, the events carry on from the very
        // next one, and bring it to where the server is.
        try await client.decide(approvalID: XCTUnwrap(builder.approvals.first).id, allow: true, in: "builder")
        var first: Int?
        for try await envelope in try await client.events(of: "builder", conversationID: builder.conversationID, after: builder.lastSeq) {
            first = first ?? envelope.seq
            builder.apply(envelope)
            if builder.stopReason == .endTurn { break }
        }
        XCTAssertEqual(first, initial.sessions[1].lastSeq + 1)
        let now = try await client.state(of: "builder")
        XCTAssertEqual(builder, now)
    }

    func testALatecomerTakesOnEverythingAtOnceAndLogsWhatItMissed() async throws {
        let (server, birdwatcher, _) = try await connect()
        await birdwatcher.send("Look for snails")
        await wait(for: "the Birdwatcher to finish") { birdwatcher.stopReason == .endTurn }

        let (latecomer, lateBirdwatcher, _) = try await connect()
        // The whole job is there as soon as it is live, without its helpers
        // coming and going, and nothing of it is new.
        XCTAssertEqual(lateBirdwatcher.state, birdwatcher.state)
        XCTAssertTrue(lateBirdwatcher.subagents.isEmpty)
        XCTAssertTrue(lateBirdwatcher.newMessages.isEmpty)
        // It finished while the latecomer was away: a missed call.
        XCTAssertEqual(lateBirdwatcher.finishedWhileAway.map(\.id), birdwatcher.transcript.suffix(1).map(\.id))
        // And what it did is in the log, as while you were away.
        await wait(for: "the log") { latecomer.log.entries.contains { $0.kind == .jobDone } }
        XCTAssertEqual(latecomer.log.entries.filter { $0.kind == .helperSent }.count, 2)
        XCTAssertTrue(latecomer.log.entries.allSatisfy(\.isWhileAway))

        server.disconnect()
        latecomer.disconnect()
    }

    func testBadRequestsAreRefused() async throws {
        let client = makeClient()
        do {
            try await client.decide(approvalID: "nope", allow: true, in: "builder")
            XCTFail("expected a 404")
        } catch let error as ALifeClientError {
            XCTAssertEqual(error, .server(status: 404, reason: "No such approval"))
        }
        do {
            try await client.sendMessage("   ", to: "birdwatcher")
            XCTFail("expected a 400")
        } catch let error as ALifeClientError {
            XCTAssertEqual(error, .server(status: 400, reason: "The message is empty"))
        }
        do {
            try await client.sendMessage("Hello", to: "team-lead")
            XCTFail("expected a 404")
        } catch let error as ALifeClientError {
            XCTAssertEqual(error, .server(status: 404, reason: "No such session"))
        }
    }

    func testHealth() async throws {
        let (data, response) = try await URLSession(configuration: .ephemeral).data(from: baseURL.appendingPathComponent("health"))
        XCTAssertEqual((response as? HTTPURLResponse)?.statusCode, 200)
        XCTAssertEqual(String(decoding: data, as: UTF8.self), #"{"status":"ok"}"#)
    }
}
