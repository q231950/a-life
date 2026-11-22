import ALifeAPI
import ALifeClient
@testable import ALifeServer
import Vapor
import XCTest

/// How full a character's context is, and the model playing it: asked of
/// Claude Code and followed from its replies, made up by the dummies, and
/// sent to the front ends. The lines the stand-in CLI writes are shaped like
/// Claude Code 2.1.323's, as its own code describes them; they haven't been
/// checked against a real run.
final class ContextTests: XCTestCase {
    private func make() async -> (ClaudeCharacter, SessionHub, FakeClaudeCode) {
        let hub = SessionHub(id: "builder", name: "Builder")
        let claudeCode = FakeClaudeCode()
        let builder = ClaudeCharacter(.builder, hub: hub, claudeCode: claudeCode, logger: Logger(label: "test"))
        await builder.reset()
        return (builder, hub, claudeCode)
    }

    @discardableResult
    private func until(
        _ hub: SessionHub,
        _ description: String,
        file: StaticString = #filePath,
        line: UInt = #line,
        _ condition: (SessionState) -> Bool
    ) async -> SessionState {
        for _ in 0..<300 {
            let state = await hub.state
            if condition(state) { return state }
            try? await Task.sleep(nanoseconds: 10_000_000)
        }
        XCTFail("timed out waiting for \(description)", file: file, line: line)
        return await hub.state
    }

    private func waitFor(_ description: String, file: StaticString = #filePath, line: UInt = #line, _ condition: () -> Bool) async {
        for _ in 0..<300 where !condition() {
            try? await Task.sleep(nanoseconds: 10_000_000)
        }
        XCTAssertTrue(condition(), "timed out waiting for \(description)", file: file, line: line)
    }

    /// The ids of the `get_context_usage` requests sent to `cli`, in order.
    private func questions(_ cli: FakeClaudeCLI) -> [String] {
        cli.sent.compactMap { message in
            guard message["type"]?.string == "control_request",
                  message["request"]?["subtype"]?.string == "get_context_usage" else { return nil }
            return message["request_id"]?.string
        }
    }

    /// Every reading the session's log has said, in order.
    private func readings(_ hub: SessionHub) async -> [SessionContext] {
        let state = await hub.state
        var readings: [SessionContext] = []
        for await envelope in await hub.subscribe(conversationID: state.conversationID, after: 0) {
            if case .contextChanged(let context) = envelope.event { readings.append(context) }
            if envelope.seq >= state.lastSeq { break }
        }
        return readings
    }

    // MARK: The CLI's lines

    private let started = #"{"type":"system","subtype":"init","session_id":"session-1","model":"claude-opus-4-7","tools":["Agent","Bash","Read","Write"]}"#

    private func replies(_ text: String, input: Int, cacheRead: Int, cacheWrite: Int, output: Int, parent: String? = nil) -> String {
        let parent = parent.map { #""\#($0)""# } ?? "null"
        return #"{"type":"assistant","message":{"role":"assistant","model":"claude-opus-4-7","content":[{"type":"text","text":"\#(text)"}],"usage":{"input_tokens":\#(input),"cache_creation_input_tokens":\#(cacheWrite),"cache_read_input_tokens":\#(cacheRead),"output_tokens":\#(output)}},"parent_tool_use_id":\#(parent),"session_id":"session-1"}"#
    }

    private let turnEnds = #"{"type":"result","subtype":"success","is_error":false,"result":"Done.","session_id":"session-1","modelUsage":{"claude-opus-4-7":{"inputTokens":10,"outputTokens":500,"cacheReadInputTokens":40000,"cacheCreationInputTokens":3000,"webSearchRequests":0,"costUSD":0.1,"contextWindow":200000,"maxOutputTokens":32000},"claude-haiku-4-5":{"inputTokens":300,"outputTokens":20,"cacheReadInputTokens":0,"cacheCreationInputTokens":0,"webSearchRequests":0,"costUSD":0.001,"contextWindow":100000,"maxOutputTokens":8000}}}"#

    private func answer(_ id: String, total: Int = 52_000, threshold: Int? = 167_000, enabled: Bool = true) -> String {
        let threshold = threshold.map { #","autoCompactThreshold":\#($0)"# } ?? ""
        return #"{"type":"control_response","response":{"subtype":"success","request_id":"\#(id)","response":{"categories":[],"totalTokens":\#(total),"maxTokens":200000,"rawMaxTokens":200000,"autocompactSource":"model-default","percentage":26,"gridRows":[],"model":"claude-opus-4-7","memoryFiles":[],"mcpTools":[],"agents":[],"isAutoCompactEnabled":\#(enabled)\#(threshold)}}}"#
    }

    private func refusal(_ id: String) -> String {
        #"{"type":"control_response","response":{"subtype":"error","request_id":"\#(id)","error":"get_context_usage is not supported in this context"}}"#
    }

    // MARK: Asking Claude Code

    func testClaudeCodeIsAskedWhereItCompactsWhenItStartsAndAfterEachTurn() async throws {
        let (builder, hub, claudeCode) = await make()
        try await builder.handleMessage("Build me an office")
        let cli = try XCTUnwrap(claudeCode.clis.first)
        XCTAssertEqual(questions(cli).count, 1)

        cli.say(started)
        var state = await until(hub, "the model") { $0.context?.model != nil }
        XCTAssertEqual(state.context, SessionContext(model: "claude-opus-4-7"))

        cli.say(answer(questions(cli)[0]))
        state = await until(hub, "the answer") { $0.context?.compactsAt != nil }
        XCTAssertEqual(state.context, SessionContext(model: "claude-opus-4-7", usedTokens: 52_000, compactsAt: 167_000, contextWindow: 200_000, autoCompact: true))

        // Between answers, the tokens follow the character's own replies.
        cli.say(replies("On it.", input: 10, cacheRead: 60_000, cacheWrite: 2_000, output: 300))
        state = await until(hub, "the reply's tokens") { $0.context?.usedTokens == 62_310 }
        XCTAssertEqual(state.context?.compactsAt, 167_000)

        cli.say(turnEnds)
        await waitFor("the question after the turn") { questions(cli).count == 2 }
        cli.say(answer(questions(cli)[1], total: 63_000, threshold: 160_000))
        state = await until(hub, "the second answer") { $0.context?.compactsAt == 160_000 }
        XCTAssertEqual(state.context?.usedTokens, 63_000)
    }

    func testOnlyOneQuestionIsOutAtATime() async throws {
        let (builder, _, claudeCode) = await make()
        try await builder.handleMessage("Build me an office")
        let cli = try XCTUnwrap(claudeCode.clis.first)
        cli.say(started)
        cli.say(turnEnds)
        cli.say(#"{"type":"system","subtype":"compact_boundary","compact_metadata":{"trigger":"auto","pre_tokens":170000},"session_id":"session-1"}"#)
        // Neither the turn nor the compacting asks while the first is out.
        try await Task.sleep(nanoseconds: 50_000_000)
        XCTAssertEqual(questions(cli).count, 1)

        // Answered, it asks once more for what happened meanwhile.
        cli.say(answer(questions(cli)[0]))
        await waitFor("the question asked again") { questions(cli).count == 2 }
        try await Task.sleep(nanoseconds: 50_000_000)
        XCTAssertEqual(questions(cli).count, 2)
    }

    func testAnAnswerToAnotherRequestIsIgnored() async throws {
        let (builder, hub, claudeCode) = await make()
        try await builder.handleMessage("Build me an office")
        let cli = try XCTUnwrap(claudeCode.clis.first)
        cli.say(answer("someone-elses-request"))
        cli.say(started)
        let state = await until(hub, "the model") { $0.context?.model != nil }
        XCTAssertNil(state.context?.compactsAt)
        XCTAssertEqual(questions(cli).count, 1)
    }

    func testWithAutoCompactOffThereIsNoCompactionPoint() async throws {
        let (builder, hub, claudeCode) = await make()
        try await builder.handleMessage("Build me an office")
        let cli = try XCTUnwrap(claudeCode.clis.first)
        cli.say(answer(questions(cli)[0], threshold: 167_000, enabled: false))
        let state = await until(hub, "the answer") { $0.context?.autoCompact == false }
        XCTAssertNil(state.context?.compactsAt)
        XCTAssertEqual(state.context?.measure, .window(of: 200_000))
    }

    func testIfClaudeCodeWontSayTheWindowIsMeasuredAgainst() async throws {
        let (builder, hub, claudeCode) = await make()
        try await builder.handleMessage("Build me an office")
        let cli = try XCTUnwrap(claudeCode.clis.first)
        cli.say(refusal(questions(cli)[0]))
        cli.say(started)
        cli.say(replies("On it.", input: 10, cacheRead: 40_000, cacheWrite: 3_000, output: 500))
        cli.say(turnEnds)
        let state = await until(hub, "the turn's window") { $0.context?.contextWindow != nil }
        // The main model's window, not the one for small jobs on the side.
        XCTAssertEqual(state.context, SessionContext(model: "claude-opus-4-7", usedTokens: 43_510, contextWindow: 200_000))
        XCTAssertEqual(state.context?.measure, .window(of: 200_000))
        XCTAssertEqual(state.context?.percent, 22)
        // And it isn't asked again in this run.
        try await Task.sleep(nanoseconds: 50_000_000)
        XCTAssertEqual(questions(cli).count, 1)
    }

    func testAHelpersRepliesArentTheCharactersContext() async throws {
        let (builder, hub, claudeCode) = await make()
        try await builder.handleMessage("Build me an office")
        let cli = try XCTUnwrap(claudeCode.clis.first)
        cli.say(replies("Sending my construction worker.", input: 10, cacheRead: 30_000, cacheWrite: 0, output: 100))
        await until(hub, "the character's tokens") { $0.context?.usedTokens == 30_110 }
        cli.say(replies("Measuring.", input: 5, cacheRead: 9_000, cacheWrite: 0, output: 50, parent: "toolu_agent"))
        cli.say(replies("Still here.", input: 10, cacheRead: 31_000, cacheWrite: 0, output: 100))
        let state = await until(hub, "the next reply") { $0.messages.last?.text == "Still here." }
        XCTAssertEqual(state.context?.usedTokens, 31_110)
    }

    func testTheSameReadingIsntSaidTwice() async throws {
        let (builder, hub, claudeCode) = await make()
        try await builder.handleMessage("Build me an office")
        let cli = try XCTUnwrap(claudeCode.clis.first)
        let line = replies("On it.", input: 10, cacheRead: 30_000, cacheWrite: 0, output: 100)
        cli.say(line)
        cli.say(line)
        cli.say(replies("Done.", input: 10, cacheRead: 30_000, cacheWrite: 0, output: 101))
        await until(hub, "the last reply") { $0.messages.last?.text == "Done." }
        let said = await readings(hub)
        XCTAssertEqual(said.map(\.usedTokens), [30_110, 30_111])
    }

    func testStartingOverForgetsTheContextAndAResumedSessionKeepsIt() async throws {
        let (builder, hub, claudeCode) = await make()
        try await builder.handleMessage("Build me an office")
        let cli = try XCTUnwrap(claudeCode.clis.first)
        cli.say(started)
        cli.say(answer(questions(cli)[0]))
        await until(hub, "the answer") { $0.context?.compactsAt != nil }

        // The CLI stops; the next message resumes it, and asks afresh.
        cli.exit()
        try await Task.sleep(nanoseconds: 50_000_000)
        try await builder.handleMessage("Carry on")
        let resumed = try XCTUnwrap(claudeCode.clis.last)
        XCTAssertFalse(resumed === cli)
        XCTAssertEqual(questions(resumed).count, 1)
        var state = await hub.state
        XCTAssertEqual(state.context?.compactsAt, 167_000)

        await builder.reset()
        state = await hub.state
        XCTAssertNil(state.context)
        try await builder.handleMessage("Build me a shed")
        let fresh = try XCTUnwrap(claudeCode.clis.last)
        fresh.say(#"{"type":"system","subtype":"init","session_id":"session-2","model":"claude-sonnet-5","tools":[]}"#)
        state = await until(hub, "the new session's model") { $0.context != nil }
        XCTAssertEqual(state.context, SessionContext(model: "claude-sonnet-5"))
    }

    // MARK: Reading what Claude Code says

    func testTheWindowIsTheMainModelsEvenWithASuffix() throws {
        let usage = try JSONValue.decode(Data(#"{"claude-opus-4-7[1m]":{"contextWindow":1000000},"claude-haiku-4-5":{"contextWindow":200000}}"#.utf8))
        XCTAssertEqual(ClaudeCharacter.contextWindow(in: usage, for: "claude-opus-4-7[1m]"), 1_000_000)
        XCTAssertEqual(ClaudeCharacter.contextWindow(in: usage, for: "claude-opus-4-7"), 1_000_000)
        XCTAssertNil(ClaudeCharacter.contextWindow(in: usage, for: "claude-sonnet-5"))
        XCTAssertNil(ClaudeCharacter.contextWindow(in: usage, for: nil)) // which one?
        let one = try JSONValue.decode(Data(#"{"claude-opus-4-7":{"contextWindow":200000}}"#.utf8))
        XCTAssertEqual(ClaudeCharacter.contextWindow(in: one, for: nil), 200_000)
        XCTAssertNil(ClaudeCharacter.contextWindow(in: nil, for: "claude-opus-4-7"))
    }

    func testTheTokensAreEverythingTheLastCallTookAndGave() throws {
        let usage = try JSONValue.decode(Data(#"{"input_tokens":12,"cache_creation_input_tokens":3000,"cache_read_input_tokens":40000,"output_tokens":500,"service_tier":"standard"}"#.utf8))
        XCTAssertEqual(ClaudeCharacter.usedTokens(usage), 43_512)
        XCTAssertEqual(ClaudeCharacter.usedTokens(try JSONValue.decode(Data(#"{"input_tokens":7}"#.utf8))), 7)
        XCTAssertNil(ClaudeCharacter.usedTokens(try JSONValue.decode(Data(#"{}"#.utf8))))
        XCTAssertNil(ClaudeCharacter.usedTokens(nil))
    }

    // MARK: The dummies

    func testTheDummiesFillAMadeUpContextAndCompactIt() async throws {
        let hub = SessionHub(id: "builder", name: "Builder")
        let builder = DummyCharacter(.builder, hub: hub, step: .milliseconds(1))
        await builder.reset()
        try await builder.handleMessage("Build me a shed")
        var state = await until(hub, "the first reading") { $0.context != nil }
        XCTAssertEqual(state.context, DummyCharacter.context(holding: DummyCharacter.startingTokens))
        XCTAssertEqual(state.context?.modelName, "Dummy")
        state = await until(hub, "the job, with its approval") { !$0.approvals.isEmpty }
        let filled = try XCTUnwrap(state.context?.usedTokens)
        XCTAssertGreaterThan(filled, DummyCharacter.startingTokens)

        await builder.reset()
        state = await hub.state
        XCTAssertNil(state.context)
    }

    func testTheDummiesContextCompactsOnceItWouldPassThePoint() async throws {
        let hub = SessionHub(id: "builder", name: "Builder")
        let builder = DummyCharacter(.builder, hub: hub, step: .milliseconds(1))
        await builder.reset()
        var seen: [Int] = []
        for round in 0..<12 {
            try await builder.handleMessage("Build shed \(round)")
            let state = await until(hub, "the approval") { !$0.approvals.isEmpty }
            seen.append(state.context?.usedTokens ?? 0)
            try await builder.decide(approvalID: state.approvals[0].id, allow: true)
            await until(hub, "the end of the job") { $0.stopReason == .endTurn && $0.approvals.isEmpty }
        }
        XCTAssertTrue(seen.allSatisfy { $0 <= DummyCharacter.compactsAt })
        XCTAssertTrue(zip(seen, seen.dropFirst()).contains { $1 < $0 }, "it never compacted: \(seen)")
    }

    // MARK: The server

    @MainActor
    func testTheFrontEndsFollowTheContext() async throws {
        // Arguments of its own, rather than `.testing`'s, which some test
        // runners leave the test bundle in, for Vapor to take as a command.
        let app = try await Application.make(Environment(name: "testing", arguments: ["vapor"]))
        do {
            try await configure(app, players: .dummies(step: .milliseconds(20)))
            app.http.server.configuration.hostname = "127.0.0.1"
            app.http.server.configuration.port = 0 // any free port
            try await app.startup()
            let port = try XCTUnwrap(app.http.server.shared.localAddress?.port)
            let baseURL = try XCTUnwrap(URL(string: "http://127.0.0.1:\(port)"))

            let server = ServerConnection(serverURLStore: InMemoryServerURLStore(baseURL), urlSession: URLSession(configuration: .ephemeral))
            server.connect()
            for _ in 0..<500 where server.phase != .live {
                try await Task.sleep(nanoseconds: 10_000_000)
            }
            let builder = try XCTUnwrap(server.sessions.first)
            XCTAssertNil(builder.context)
            await builder.send("Build me a shed")
            for _ in 0..<500 where builder.context == nil {
                try await Task.sleep(nanoseconds: 10_000_000)
            }
            let context = try XCTUnwrap(builder.context)
            XCTAssertEqual(context.model, "dummy")
            XCTAssertEqual(context.measure, .compaction(at: DummyCharacter.compactsAt))

            // The snapshot says so too.
            let client = ALifeServerClient(baseURL: baseURL, urlSession: URLSession(configuration: .ephemeral))
            let snapshot = try await client.state(of: builder.id)
            XCTAssertNotNil(snapshot.context)
            server.disconnect()
        } catch {
            XCTFail("\(error)")
        }
        try await app.asyncShutdown()
    }
}
