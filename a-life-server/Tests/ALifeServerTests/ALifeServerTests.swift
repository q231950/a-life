import ALifeClient
@testable import ALifeServer
import Vapor
import XCTest
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif

/// Runs the real client package against the real server, over HTTP on a
/// local port, with the dummy team playing at speed.
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

    private func makeSession() -> AgentSession {
        AgentSession(serverURLStore: InMemoryServerURLStore(baseURL), urlSession: URLSession(configuration: .ephemeral))
    }

    func testAFrontEndCanDriveTheDummyTeamFromStartToFinish() async throws {
        let session = makeSession()
        session.connect()
        await wait(for: "the team lead") { session.agents.map(\.name) == ["Team lead"] }
        XCTAssertEqual(session.phase, .live)
        XCTAssertEqual(session.status, .idle)

        await session.send("Tidy the lot")
        XCTAssertNil(session.lastError)
        await wait(for: "the approval") { session.stopReason == .requiresAction }
        XCTAssertEqual(session.agents.map(\.name), ["Team lead", "Gardener", "Builder"])
        XCTAssertEqual(session.pendingApprovals.map(\.agentName), ["Builder"])
        XCTAssertEqual(session.transcript.first?.text, "Tidy the lot")

        await session.respond(to: session.pendingApprovals[0], allow: false)
        await wait(for: "the end of the turn") { session.stopReason == .endTurn }
        XCTAssertTrue(session.pendingApprovals.isEmpty)
        XCTAssertTrue(session.agents.allSatisfy { $0.status == .idle })
        XCTAssertEqual(session.transcript.last?.kind, .agent)
        XCTAssertTrue(session.transcript.contains { $0.text == "Left the shed where it is." })

        // A second front end joining late sees the same session.
        let latecomer = makeSession()
        latecomer.connect()
        await wait(for: "the latecomer to catch up") { latecomer.transcript == session.transcript }
        XCTAssertEqual(latecomer.agents, session.agents)

        // A new session empties both.
        await session.startNewSession()
        await wait(for: "the reset") { session.transcript.isEmpty && latecomer.transcript.isEmpty }
        XCTAssertEqual(session.agents.map(\.name), ["Team lead"])

        session.disconnect()
        latecomer.disconnect()
    }

    func testInterruptingStopsTheTeam() async throws {
        let session = makeSession()
        session.connect()
        await wait(for: "live") { session.phase == .live }

        await session.send("Build a pond")
        await wait(for: "the approval") { session.stopReason == .requiresAction }
        await session.interrupt()
        await wait(for: "the interrupt") { session.stopReason == .interrupted }
        XCTAssertTrue(session.pendingApprovals.isEmpty)
        XCTAssertEqual(session.status, .idle)

        session.disconnect()
    }

    func testAReconnectingClientIsSentOnlyWhatItMissed() async throws {
        let client = ALifeServerClient(baseURL: baseURL, urlSession: URLSession(configuration: .ephemeral))
        try await client.sendMessage("Plant a tree")

        var state = SessionState()
        for try await envelope in try await client.events() {
            state.apply(envelope)
            if state.stopReason == .requiresAction { break }
        }
        let seen = state.lastSeq
        try await client.decide(approvalID: XCTUnwrap(state.approvals.first).id, allow: true)

        var firstMissed: Int?
        for try await envelope in try await client.events(sessionID: state.sessionID, after: seen) {
            firstMissed = firstMissed ?? envelope.seq
            state.apply(envelope)
            if state.stopReason == .endTurn { break }
        }
        XCTAssertEqual(firstMissed, seen + 1)
        let snapshot = try await client.state()
        XCTAssertEqual(snapshot, state)

        // Naming a session the server doesn't have replays the current one in full.
        for try await envelope in try await client.events(sessionID: "gone", after: 999) {
            XCTAssertEqual(envelope.event, .sessionStarted(sessionID: try XCTUnwrap(state.sessionID)))
            break
        }
    }

    func testBadRequestsAreRefused() async throws {
        let client = ALifeServerClient(baseURL: baseURL, urlSession: URLSession(configuration: .ephemeral))
        do {
            try await client.decide(approvalID: "nope", allow: true)
            XCTFail("expected a 404")
        } catch let error as ALifeClientError {
            XCTAssertEqual(error, .server(status: 404, reason: "No such approval"))
        }
        do {
            try await client.sendMessage("   ")
            XCTFail("expected a 400")
        } catch let error as ALifeClientError {
            XCTAssertEqual(error, .server(status: 400, reason: "The message is empty"))
        }
    }

    func testHealth() async throws {
        let (data, response) = try await URLSession(configuration: .ephemeral).data(from: baseURL.appendingPathComponent("health"))
        XCTAssertEqual((response as? HTTPURLResponse)?.statusCode, 200)
        XCTAssertEqual(String(decoding: data, as: UTF8.self), #"{"status":"ok"}"#)
    }
}
