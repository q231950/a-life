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
        app = try await Application.make(.testing)
        try await configure(app, dummyStep: .milliseconds(20))
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

    private func connect() async throws -> (ServerConnection, gardener: AgentSession, builder: AgentSession) {
        let server = ServerConnection(serverURLStore: InMemoryServerURLStore(baseURL), urlSession: URLSession(configuration: .ephemeral))
        server.connect()
        await wait(for: "live") { server.phase == .live && server.sessions.allSatisfy { $0.state.conversationID != nil } }
        return (server, try XCTUnwrap(server.session("gardener")), try XCTUnwrap(server.session("builder")))
    }

    private func makeClient() -> ALifeServerClient {
        ALifeServerClient(baseURL: baseURL, urlSession: URLSession(configuration: .ephemeral))
    }

    func testEveryCharacterHasASessionOfItsOwn() async throws {
        let (server, gardener, builder) = try await connect()
        XCTAssertEqual(server.sessions.map(\.name), ["Gardener", "Builder"])
        XCTAssertEqual(gardener.status, .idle)

        // The Gardener only looks, so it never asks for anything.
        await gardener.send("Look for snails")
        XCTAssertNil(gardener.lastError)
        await wait(for: "the Gardener to finish") { gardener.stopReason == .endTurn }
        XCTAssertEqual(gardener.transcript.map(\.speaker), ["You", "Gardener"])
        XCTAssertEqual(gardener.transcript.first?.text, "Look for snails")
        XCTAssertTrue(gardener.transcript.last?.text.hasPrefix("Had a look around for “Look for snails”.") == true)
        XCTAssertNil(gardener.activity)

        // None of that happened in the Builder's session.
        XCTAssertTrue(builder.transcript.isEmpty)
        XCTAssertEqual(builder.status, .idle)

        server.disconnect()
    }

    func testTheBuilderAsksBeforeItActs() async throws {
        let (server, gardener, builder) = try await connect()

        await builder.send("Tidy the lot")
        await wait(for: "the approval") { builder.stopReason == .requiresAction }
        XCTAssertTrue(builder.isWaitingForYou)
        XCTAssertEqual(builder.pendingApprovals.map(\.toolName), ["bash"])

        // It can't be told anything else until it has an answer.
        await builder.send("What are you doing?")
        XCTAssertEqual(builder.lastError, "Builder is waiting for an answer to its request (HTTP 409)")
        XCTAssertEqual(builder.transcript.count, 1)
        // The Gardener can, meanwhile.
        await gardener.send("Look for snails")
        XCTAssertNil(gardener.lastError)

        await builder.respond(to: builder.pendingApprovals[0], allow: false)
        await wait(for: "the end of the turn") { builder.stopReason == .endTurn }
        XCTAssertFalse(builder.isWaitingForYou)
        XCTAssertTrue(builder.transcript.last?.text.hasPrefix("Left the shed where it is") == true)

        // A second front end joining late sees the same sessions.
        let (latecomer, lateGardener, lateBuilder) = try await connect()
        await wait(for: "the latecomer to catch up") { lateBuilder.state == builder.state }

        // Starting the Builder over empties it for both, and leaves the Gardener be.
        await wait(for: "the Gardener to finish") { gardener.stopReason == .endTurn && lateGardener.stopReason == .endTurn }
        await builder.startOver()
        await wait(for: "the reset") { builder.transcript.isEmpty && lateBuilder.transcript.isEmpty }
        XCTAssertEqual(gardener.transcript.count, 2)
        XCTAssertEqual(lateGardener.transcript, gardener.transcript)

        server.disconnect()
        latecomer.disconnect()
    }

    func testInterruptingStopsOnlyThatCharacter() async throws {
        let (server, gardener, builder) = try await connect()

        await builder.send("Build a pond")
        await wait(for: "the approval") { builder.stopReason == .requiresAction }
        await gardener.send("Water the roses")
        await builder.interrupt()
        await wait(for: "the interrupt") { builder.stopReason == .interrupted }
        XCTAssertFalse(builder.isWaitingForYou)
        XCTAssertEqual(builder.status, .idle)

        await wait(for: "the Gardener to finish anyway") { gardener.stopReason == .endTurn }
        XCTAssertEqual(builder.stopReason, .interrupted)

        server.disconnect()
    }

    func testSomethingSaidMidTaskIsAnsweredStraightAway() async throws {
        // A slow step, so the question surely arrives while the first one runs.
        let hub = SessionHub(id: "gardener", name: "Gardener")
        let gardener = DummyCharacter(cast[0], hub: hub, step: .milliseconds(300))
        await gardener.reset()

        try await gardener.handleMessage("Look for snails")
        try await gardener.handleMessage("What are you doing?")
        for _ in 0..<300 where await hub.state.stopReason != .endTurn {
            try await Task.sleep(nanoseconds: 10_000_000)
        }

        let lines = await hub.state.messages.map { "\($0.speaker): \($0.text)" }
        XCTAssertEqual(lines.count, 4, "\(lines)")
        XCTAssertEqual(lines.prefix(3), [
            "You: Look for snails",
            "You: What are you doing?",
            "Gardener: Still on “Look for snails”. Right now I'm looking around the lot.",
        ])
        XCTAssertTrue(lines.last?.hasPrefix("Gardener: Had a look around") == true)
    }

    func testAReconnectingClientIsSentOnlyWhatItMissed() async throws {
        let client = makeClient()
        try await client.sendMessage("Plant a tree", to: "builder")

        var state = SessionState(id: "builder", name: "Builder")
        for try await envelope in try await client.events(of: "builder") {
            state.apply(envelope)
            if state.stopReason == .requiresAction { break }
        }
        let seen = state.lastSeq
        try await client.decide(approvalID: XCTUnwrap(state.approvals.first).id, allow: true, in: "builder")

        var firstMissed: Int?
        for try await envelope in try await client.events(of: "builder", conversationID: state.conversationID, after: seen) {
            firstMissed = firstMissed ?? envelope.seq
            state.apply(envelope)
            if state.stopReason == .endTurn { break }
        }
        XCTAssertEqual(firstMissed, seen + 1)
        XCTAssertTrue(state.messages.last?.text.hasPrefix("Moved the shed") == true)
        let snapshot = try await client.state(of: "builder")
        XCTAssertEqual(snapshot, state)
        let listed = try await client.sessions()
        XCTAssertEqual(listed.map(\.id), ["gardener", "builder"])
        XCTAssertEqual(listed.last, state)

        // Naming a conversation the server doesn't have replays the current one in full.
        for try await envelope in try await client.events(of: "builder", conversationID: "gone", after: 999) {
            XCTAssertEqual(envelope.event, .conversationStarted(conversationID: try XCTUnwrap(state.conversationID)))
            break
        }
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
            try await client.sendMessage("   ", to: "gardener")
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
