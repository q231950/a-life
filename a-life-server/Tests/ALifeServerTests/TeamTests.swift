import ALifeAPI
import ALifeClient
@testable import ALifeServer
import Vapor
import XCTest
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif

/// Agents joining and leaving the lot while the server runs: what the Team
/// Lead's add-agent and remove-agent write to the added agents file reaches
/// the sessions, the roster stream and the front ends, with no restart.
@MainActor
final class TeamTests: XCTestCase {
    private var app: Application!
    private var baseURL: URL!
    private var addedFile: URL!
    /// What the commands see: the files, and no agents file of the person's.
    private var environment: [String: String]!

    private let plumber = """
        id: plumber
        name: Plumber
        color: "#2266AA"
        role: |
          You are the Plumber, a character in a*life, a little life sim.
        helper:
          name: wrench
          tools: [Read]
          description: Fixes pipes.
          prompt: You are the Plumber's wrench.
        """

    override func setUp() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        addTeardownBlock { try? FileManager.default.removeItem(at: directory) }
        addedFile = directory.appendingPathComponent("added-agents.yaml")
        environment = [
            "ALIFE_AGENTS_FILE": directory.appendingPathComponent("agents.yaml").path,
            "ALIFE_ADDED_AGENTS_FILE": addedFile.path,
        ]
        // Arguments of its own, rather than `.testing`'s, which some test
        // runners leave the test bundle in, for Vapor to take as a command.
        app = try await Application.make(Environment(name: "testing", arguments: ["vapor"]))
        try await configure(
            app, players: .dummies(step: .milliseconds(20)), cast: [.birdwatcher, .builder],
            addedAgentsFile: addedFile, teamWatchInterval: .milliseconds(25)
        )
        app.http.server.configuration.hostname = "127.0.0.1"
        app.http.server.configuration.port = 0 // any free port
        try await app.startup()
        let port = try XCTUnwrap(app.http.server.shared.localAddress?.port)
        baseURL = try XCTUnwrap(URL(string: "http://127.0.0.1:\(port)"))
    }

    override func tearDown() async throws {
        try await app.asyncShutdown()
    }

    private func makeClient() -> ALifeServerClient {
        ALifeServerClient(baseURL: baseURL, urlSession: URLSession(configuration: .ephemeral))
    }

    private func wait(
        for description: String, file: StaticString = #filePath, line: UInt = #line, until condition: () async -> Bool
    ) async {
        for _ in 0..<400 {
            if await condition() { return }
            try? await Task.sleep(nanoseconds: 25_000_000)
        }
        XCTFail("timed out waiting for \(description)", file: file, line: line)
    }

    func testAnAgentTheTeamLeadAddsJoinsTheLotAtOnceAndLeavesItWhenTakenAway() async throws {
        let client = makeClient()
        var rosters: [Roster] = []
        let following = Task { @MainActor in
            for try await roster in try await client.rosterChanges() { rosters.append(roster) }
        }
        defer { following.cancel() }

        // The first roster is who is there, at revision 1.
        await wait(for: "the first roster") { !rosters.isEmpty }
        XCTAssertEqual(rosters.last, Roster(revision: 1, sessions: ["birdwatcher", "builder"]))
        var sessions = try await client.sessions()
        XCTAssertEqual(sessions.map(\.id), ["birdwatcher", "builder"])

        // The recruiter's command only writes the file.
        XCTAssertTrue(AddAgent.run(entry: plumber, environment: environment).added)
        await wait(for: "the Plumber to join") { rosters.last?.sessions == ["birdwatcher", "builder", "plumber"] }
        XCTAssertEqual(rosters.last?.revision, 2)
        let initial = try await client.initialState()
        XCTAssertEqual(initial.sessions.map(\.id), ["birdwatcher", "builder", "plumber"])
        XCTAssertEqual(initial.sessions.last?.name, "Plumber")
        XCTAssertEqual(initial.sessions.last?.color, "#2266AA")
        sessions = try await client.sessions()
        XCTAssertEqual(sessions.map(\.name), ["Birdwatcher", "Builder", "Plumber"])

        // The new character is a session like any other: it has begun its
        // conversation, its events stream, and it takes messages.
        let state = try await client.state(of: "plumber")
        XCTAssertNotNil(state.conversationID)
        try await client.sendMessage("Fix the sink", to: "plumber")
        await wait(for: "the Plumber to answer") {
            ((try? await client.state(of: "plumber"))?.messages.contains { $0.speaker == "Plumber" }) == true
        }

        // Taking it away ends its session, and every other session carries on.
        XCTAssertTrue(RemoveAgent.run(id: "plumber", confirmed: true, environment: environment).succeeded)
        await wait(for: "the Plumber to leave") { rosters.last?.sessions == ["birdwatcher", "builder"] }
        XCTAssertEqual(rosters.last?.revision, 3)
        do {
            _ = try await client.state(of: "plumber")
            XCTFail("the Plumber is still there")
        } catch ALifeClientError.server(status: 404, reason: _) {
        }
        sessions = try await client.sessions()
        XCTAssertEqual(sessions.map(\.id), ["birdwatcher", "builder"])
        try await client.sendMessage("Hello", to: "builder")

        // It can join again, as a fresh session.
        XCTAssertTrue(AddAgent.run(entry: plumber, environment: environment).added)
        await wait(for: "the Plumber to join again") { rosters.last?.sessions.last == "plumber" }
        let fresh = try await client.state(of: "plumber")
        XCTAssertEqual(fresh.messages, [])
    }

    func testAFileThatIsWrongLeavesTheLotAsItIsUntilItIsPutRight() async throws {
        let client = makeClient()
        try "agents:\n  - id: plumber\n".write(to: addedFile, atomically: true, encoding: .utf8)
        try await Task.sleep(nanoseconds: 300_000_000)
        var sessions = try await client.sessions()
        XCTAssertEqual(sessions.map(\.id), ["birdwatcher", "builder"])

        XCTAssertTrue(AddAgent.run(entry: plumber, environment: environment).added == false, "added to a wrong file")
        try "agents:\n".write(to: addedFile, atomically: true, encoding: .utf8)
        XCTAssertTrue(AddAgent.run(entry: plumber, environment: environment).added)
        await wait(for: "the Plumber to join") { ((try? await client.sessions())?.count) == 3 }
        sessions = try await client.sessions()
        XCTAssertEqual(sessions.map(\.id), ["birdwatcher", "builder", "plumber"])
    }

    func testABuiltInAgentInTheAddedFileDoesntJoinTwice() async throws {
        let client = makeClient()
        // The cast here is Birdwatcher and Builder, which are "built in" to
        // this server, so an agent with the Builder's id is ignored.
        try "agents:\n  - id: builder\n    name: Other Builder\n    role: You build.\n    helper: {name: brick, tools: [Read], description: Builds., prompt: Build.}\n"
            .write(to: addedFile, atomically: true, encoding: .utf8)
        try await Task.sleep(nanoseconds: 300_000_000)
        let sessions = try await client.sessions()
        XCTAssertEqual(sessions.map(\.name), ["Birdwatcher", "Builder"])
    }

    func testAFrontEndFollowingTheServerSeesAnAgentAppearAndDisappear() async throws {
        let server = ServerConnection(serverURLStore: InMemoryServerURLStore(baseURL), urlSession: URLSession(configuration: .ephemeral))
        server.connect()
        defer { server.disconnect() }
        await wait(for: "live") { server.phase == .live && server.sessions.allSatisfy { $0.state.conversationID != nil } }
        XCTAssertEqual(server.sessions.map(\.id), ["birdwatcher", "builder"])
        let birdwatcher = try XCTUnwrap(server.session("birdwatcher"))

        XCTAssertTrue(AddAgent.run(entry: plumber, environment: environment).added)
        await wait(for: "the Plumber to appear") { server.session("plumber")?.state.conversationID != nil }
        XCTAssertEqual(server.sessions.map(\.id), ["birdwatcher", "builder", "plumber"])
        XCTAssertEqual(server.session("plumber")?.name, "Plumber")
        // The sessions that were there are the same ones, still followed.
        XCTAssertTrue(server.session("birdwatcher") === birdwatcher)
        await birdwatcher.send("Look for snails")
        await wait(for: "the Birdwatcher to answer") { birdwatcher.stopReason == .endTurn }
        let plumber = try XCTUnwrap(server.session("plumber"))
        await plumber.send("Fix the sink")
        await wait(for: "the Plumber to answer") { plumber.stopReason == .endTurn }

        XCTAssertTrue(RemoveAgent.run(id: "plumber", confirmed: true, environment: environment).succeeded)
        await wait(for: "the Plumber to go") { server.session("plumber") == nil }
        XCTAssertEqual(server.sessions.map(\.id), ["birdwatcher", "builder"])
        XCTAssertEqual(server.phase, .live)
    }
}

