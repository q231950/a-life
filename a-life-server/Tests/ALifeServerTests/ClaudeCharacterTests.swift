import ALifeClient
@testable import ALifeServer
import Vapor
import XCTest

/// A character played by Claude Code, with a stand-in for the `claude` CLI
/// that speaks its stream-json. The lines it sends are trimmed from what
/// Claude Code 2.1 really writes.
final class ClaudeCharacterTests: XCTestCase {
    private func make(_ character: Character) async -> (ClaudeCharacter, SessionHub, FakeClaudeCode) {
        let hub = SessionHub(id: character.id, name: character.name)
        let claudeCode = FakeClaudeCode()
        let backend = ClaudeCharacter(character, hub: hub, claudeCode: claudeCode, logger: Logger(label: "test"))
        await backend.reset()
        return (backend, hub, claudeCode)
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

    private func transcript(_ state: SessionState) -> [String] {
        state.messages.map { "\($0.speaker): \($0.text)" }
    }

    private func value(after flag: String, in arguments: [String]) -> String? {
        arguments.firstIndex(of: flag).flatMap { arguments.indices.contains($0 + 1) ? arguments[$0 + 1] : nil }
    }

    // MARK: The CLI's lines

    private let started = #"{"type":"system","subtype":"init","session_id":"session-1","tools":["Agent","Bash","Read","Write"]}"#

    private func sendsOff(_ agentType: String, as id: String = "toolu_agent", to task: String) -> String {
        #"{"type":"assistant","message":{"role":"assistant","content":[{"type":"tool_use","id":"\#(id)","name":"Agent","input":{"description":"\#(task)","subagent_type":"\#(agentType)","prompt":"Do it."}}]},"parent_tool_use_id":null,"session_id":"session-1"}"#
    }

    private func taskStarted(_ agentType: String, as id: String = "toolu_agent", inBackground: Bool = false) -> String {
        #"{"type":"system","subtype":"task_started","task_id":"task-1","run_id":"run-1","tool_use_id":"\#(id)","description":"Build an office","subagent_type":"\#(agentType)","is_backgrounded":\#(inBackground),"task_type":"local_agent","session_id":"session-1"}"#
    }

    private let helperWrites = #"{"type":"assistant","message":{"role":"assistant","content":[{"type":"tool_use","id":"toolu_write","name":"Write","input":{"file_path":"/lot/buildings/office.md","content":"An office"}}]},"parent_tool_use_id":"toolu_agent","agent_id":"task-1","session_id":"session-1"}"#

    private let helperAsksToWrite = #"{"type":"control_request","request_id":"request-write","request":{"subtype":"can_use_tool","tool_name":"Write","display_name":"Write","input":{"file_path":"/lot/buildings/office.md","content":"An office"},"description":"buildings/office.md","tool_use_id":"toolu_write","agent_id":"task-1"}}"#

    private let helperWrote = #"{"type":"user","message":{"role":"user","content":[{"type":"tool_result","tool_use_id":"toolu_write","content":"File created successfully"}]},"parent_tool_use_id":"toolu_agent","agent_id":"task-1","session_id":"session-1"}"#

    private func taskNotification(_ status: String, for id: String = "toolu_agent") -> String {
        #"{"type":"system","subtype":"task_notification","task_id":"task-1","run_id":"run-1","tool_use_id":"\#(id)","status":"\#(status)","summary":"Done.","session_id":"session-1"}"#
    }

    private func helperReport(for id: String = "toolu_agent") -> String {
        #"{"type":"user","message":{"role":"user","content":[{"type":"tool_result","tool_use_id":"\#(id)","content":[{"type":"text","text":"Built the office."}]}]},"parent_tool_use_id":null,"session_id":"session-1"}"#
    }

    private func says(_ text: String) -> String {
        #"{"type":"assistant","message":{"role":"assistant","content":[{"type":"text","text":"\#(text)"}]},"parent_tool_use_id":null,"session_id":"session-1"}"#
    }

    private func result(_ subtype: String = "success", isError: Bool = false, text: String = "") -> String {
        #"{"type":"result","subtype":"\#(subtype)","is_error":\#(isError),"result":"\#(text)","session_id":"session-1"}"#
    }

    // MARK: Tests

    func testBuildMeAnOfficeSendsTheBuildersConstructionWorker() async throws {
        let (builder, hub, claudeCode) = await make(.builder)
        try await builder.handleMessage("Build me an office")

        // The Builder is a Claude Code session of its own, which knows its
        // construction worker and nobody else's helper.
        let arguments = try XCTUnwrap(claudeCode.launches.first)
        XCTAssertEqual(claudeCode.launches.count, 1)
        XCTAssertEqual(claudeCode.workspaces, [.lot])
        XCTAssertEqual(value(after: "--input-format", in: arguments), "stream-json")
        XCTAssertEqual(value(after: "--output-format", in: arguments), "stream-json")
        XCTAssertEqual(value(after: "--permission-prompt-tool", in: arguments), "stdio")
        XCTAssertEqual(value(after: "--permission-mode", in: arguments), "default")
        XCTAssertFalse(arguments.contains("--resume"))
        let agents = try JSONValue.decode(Data(XCTUnwrap(value(after: "--agents", in: arguments)).utf8))
        XCTAssertEqual(agents["construction-worker"]?["tools"], ["Read", "Glob", "Grep", "Write", "Edit"])
        XCTAssertEqual(agents["construction-worker"]?["model"], "inherit")
        XCTAssertNil(agents["planter"])
        XCTAssertTrue(try XCTUnwrap(value(after: "--append-system-prompt", in: arguments)).contains("`construction-worker` agent"))

        // It is told what you said, after the SDK's handshake.
        let cli = try XCTUnwrap(claudeCode.clis.first)
        XCTAssertEqual(cli.sent.map { $0["type"]?.string }, ["control_request", "user"])
        XCTAssertEqual(cli.sent[0]["request"]?["subtype"], "initialize")
        XCTAssertEqual(cli.sent[1]["message"], ["role": "user", "content": "Build me an office"])
        var state = await hub.state
        XCTAssertEqual(state.status, .running)

        // It sends its construction worker off, which is a helper out.
        cli.say(started)
        cli.say(sendsOff("construction-worker", to: "Build an office"))
        cli.say(taskStarted("construction-worker"))
        state = await until(hub, "the helper") { !$0.subagents.isEmpty }
        XCTAssertEqual(state.subagents, [Subagent(id: "toolu_agent", task: "Build an office")])
        XCTAssertEqual(state.activity, "agent")

        // The construction worker asks before it writes.
        cli.say(helperWrites)
        cli.say(helperAsksToWrite)
        state = await until(hub, "the approval") { !$0.approvals.isEmpty }
        XCTAssertEqual(state.approvals, [Approval(id: "request-write", toolName: "Write", input: "construction-worker: buildings/office.md")])
        XCTAssertEqual(state.status, .idle)
        XCTAssertEqual(state.stopReason, .requiresAction)
        do {
            try await builder.handleMessage("Hurry up")
            XCTFail("expected a 409")
        } catch let abort as Abort {
            XCTAssertEqual(abort.status, .conflict)
        }

        // Allowed, Claude Code is told so, with the input it asked about.
        try await builder.decide(approvalID: "request-write", allow: true)
        XCTAssertEqual(cli.sent.last, [
            "type": "control_response",
            "response": [
                "subtype": "success",
                "request_id": "request-write",
                "response": ["behavior": "allow", "updatedInput": ["file_path": "/lot/buildings/office.md", "content": "An office"]],
            ],
        ])
        state = await hub.state
        XCTAssertTrue(state.approvals.isEmpty)
        XCTAssertEqual(state.status, .running)

        // The construction worker reports back, then the Builder does.
        cli.say(helperWrote)
        cli.say(taskNotification("completed"))
        await until(hub, "the helper to report back") { $0.subagents.isEmpty }
        cli.say(helperReport())
        cli.say(says("The office is up in the north corner."))
        cli.say(result(text: "The office is up in the north corner."))
        state = await until(hub, "the end of the turn") { $0.stopReason == .endTurn }
        XCTAssertEqual(transcript(state), ["You: Build me an office", "Builder: The office is up in the north corner."])
        XCTAssertNil(state.activity)
        XCTAssertEqual(state.status, .idle)
    }

    func testTheGardenerSendsItsPlanter() async throws {
        let (gardener, hub, claudeCode) = await make(.gardener)
        try await gardener.handleMessage("Plant some roses")

        // Its edits on the lot go ahead without asking.
        let arguments = try XCTUnwrap(claudeCode.launches.first)
        XCTAssertEqual(value(after: "--permission-mode", in: arguments), "acceptEdits")
        let agents = try JSONValue.decode(Data(XCTUnwrap(value(after: "--agents", in: arguments)).utf8))
        XCTAssertNotNil(agents["planter"])
        XCTAssertNil(agents["construction-worker"])

        // A helper sent by an older Claude Code's `Task` tool, reporting back
        // with its tool result alone.
        let cli = try XCTUnwrap(claudeCode.clis.first)
        cli.say(sendsOff("planter", to: "Plant roses").replacingOccurrences(of: #""name":"Agent""#, with: #""name":"Task""#))
        var state = await until(hub, "the planter") { !$0.subagents.isEmpty }
        XCTAssertEqual(state.subagents.map(\.task), ["Plant roses"])
        cli.say(helperReport())
        await until(hub, "the planter to report back") { $0.subagents.isEmpty }
        cli.say(says("Roses are in."))
        cli.say(result(text: "Roses are in."))
        state = await until(hub, "the end of the turn") { $0.stopReason == .endTurn }
        XCTAssertEqual(transcript(state), ["You: Plant some roses", "Gardener: Roses are in."])
    }

    func testTheEngineerSendsItsALifeExpertToChangeALife() async throws {
        let (engineer, hub, claudeCode) = await make(.engineer)
        try await engineer.handleMessage("Make the sheep jump when they take off")

        // The Engineer is an ordinary Claude Code session, in the a*life
        // checkout rather than on the lot, which asks before every change.
        let arguments = try XCTUnwrap(claudeCode.launches.first)
        XCTAssertEqual(claudeCode.workspaces, [.aLife])
        XCTAssertEqual(value(after: "--permission-mode", in: arguments), "default")
        XCTAssertFalse(arguments.joined(separator: " ").contains("--cloud"))
        let agents = try JSONValue.decode(Data(XCTUnwrap(value(after: "--agents", in: arguments)).utf8))
        XCTAssertEqual(agents["a-life-expert"]?["tools"], ["Read", "Glob", "Grep", "Write", "Edit", "Bash"])
        XCTAssertEqual(agents["a-life-expert"]?["model"], "inherit")
        XCTAssertNil(agents["construction-worker"])
        XCTAssertTrue(try XCTUnwrap(value(after: "--append-system-prompt", in: arguments)).contains("`a-life-expert` agent"))

        // A change to a*life goes to its a*life expert, which asks before it
        // runs the tests.
        let cli = try XCTUnwrap(claudeCode.clis.first)
        cli.say(sendsOff("a-life-expert", to: "Make the sheep jump"))
        cli.say(taskStarted("a-life-expert"))
        var state = await until(hub, "the a*life expert") { !$0.subagents.isEmpty }
        XCTAssertEqual(state.subagents, [Subagent(id: "toolu_agent", task: "Make the sheep jump")])
        cli.say(#"{"type":"control_request","request_id":"request-test","request":{"subtype":"can_use_tool","tool_name":"Bash","input":{"command":"swift test --package-path ALifeKit"},"tool_use_id":"toolu_test","agent_id":"task-1"}}"#)
        state = await until(hub, "the approval") { !$0.approvals.isEmpty }
        XCTAssertEqual(state.approvals, [Approval(id: "request-test", toolName: "Bash", input: "a-life-expert: swift test --package-path ALifeKit")])

        try await engineer.decide(approvalID: "request-test", allow: true)
        cli.say(taskNotification("completed"))
        cli.say(helperReport())
        cli.say(says("The sheep jump before they fly off now, and the tests pass."))
        cli.say(result(text: "The sheep jump before they fly off now, and the tests pass."))
        state = await until(hub, "the end of the turn") { $0.stopReason == .endTurn }
        XCTAssertTrue(state.subagents.isEmpty)
        XCTAssertEqual(transcript(state).last, "Engineer: The sheep jump before they fly off now, and the tests pass.")
    }

    func testDenyingTellsClaudeCodeNo() async throws {
        let (builder, hub, claudeCode) = await make(.builder)
        try await builder.handleMessage("Knock down the shed")
        let cli = try XCTUnwrap(claudeCode.clis.first)
        cli.say(#"{"type":"control_request","request_id":"request-rm","request":{"subtype":"can_use_tool","tool_name":"Bash","input":{"command":"rm -r buildings/shed.md","description":"Remove the shed"},"tool_use_id":"toolu_rm"}}"#)
        let state = await until(hub, "the approval") { !$0.approvals.isEmpty }
        XCTAssertEqual(state.approvals, [Approval(id: "request-rm", toolName: "Bash", input: "rm -r buildings/shed.md")])

        try await builder.decide(approvalID: "request-rm", allow: false)
        XCTAssertEqual(cli.sent.last?["response"]?["response"]?["behavior"], "deny")
        do {
            try await builder.decide(approvalID: "request-rm", allow: true)
            XCTFail("expected a 404")
        } catch let abort as Abort {
            XCTAssertEqual(abort.status, .notFound)
        }
    }

    func testInterruptingStopsTheTurnAndCallsTheHelperBack() async throws {
        let (builder, hub, claudeCode) = await make(.builder)
        try await builder.handleMessage("Build me an office")
        let cli = try XCTUnwrap(claudeCode.clis.first)
        cli.say(sendsOff("construction-worker", to: "Build an office"))
        cli.say(taskStarted("construction-worker"))
        cli.say(helperAsksToWrite)
        await until(hub, "the approval") { !$0.approvals.isEmpty && !$0.subagents.isEmpty }

        await builder.interrupt()
        XCTAssertEqual(cli.sent.last?["request"]?["subtype"], "interrupt")
        var state = await hub.state
        XCTAssertTrue(state.approvals.isEmpty)
        XCTAssertTrue(state.subagents.isEmpty)
        XCTAssertNil(state.activity)
        XCTAssertEqual(state.status, .idle)
        XCTAssertEqual(state.stopReason, .interrupted)

        // What Claude Code says as it stops changes nothing more.
        let seq = state.lastSeq
        cli.say(#"{"type":"control_cancel_request","request_id":"request-write"}"#)
        cli.say(taskNotification("stopped"))
        cli.say(helperReport())
        cli.say(#"{"type":"user","message":{"role":"user","content":[{"type":"text","text":"[Request interrupted by user for tool use]"}]},"parent_tool_use_id":null,"session_id":"session-1"}"#)
        cli.say(result("error_during_execution", isError: true))
        try await Task.sleep(nanoseconds: 200_000_000)
        state = await hub.state
        XCTAssertEqual(state.lastSeq, seq)

        // The next thing said starts a turn that ends as usual.
        try await builder.handleMessage("Never mind, build a shed")
        state = await until(hub, "the next turn") { $0.status == .running }
        cli.say(says("Shed's up."))
        cli.say(result(text: "Shed's up."))
        state = await until(hub, "the end of the turn") { $0.stopReason == .endTurn }
        XCTAssertEqual(state.messages.last?.text, "Shed's up.")
        XCTAssertEqual(claudeCode.launches.count, 1) // the same session all along
    }

    func testIfClaudeCodeStopsTheNextMessageResumesItsSession() async throws {
        let (builder, hub, claudeCode) = await make(.builder)
        try await builder.handleMessage("Build me an office")
        let cli = try XCTUnwrap(claudeCode.clis.first)
        cli.say(started)
        cli.say(sendsOff("construction-worker", to: "Build an office"))
        await until(hub, "the helper") { !$0.subagents.isEmpty }

        cli.exit()
        let state = await until(hub, "the error") { $0.stopReason == .endTurn }
        XCTAssertEqual(state.messages.last?.kind, .error)
        XCTAssertEqual(state.messages.last?.text, "Claude Code stopped unexpectedly. Error: the lot is on fire")
        XCTAssertTrue(state.subagents.isEmpty)

        try await builder.handleMessage("Try again")
        XCTAssertEqual(claudeCode.launches.count, 2)
        XCTAssertEqual(value(after: "--resume", in: claudeCode.launches[1]), "session-1")
    }

    func testStartingOverEndsTheClaudeCodeSession() async throws {
        let (builder, hub, claudeCode) = await make(.builder)
        try await builder.handleMessage("Build me an office")
        let cli = try XCTUnwrap(claudeCode.clis.first)
        cli.say(started)
        cli.say(sendsOff("construction-worker", to: "Build an office"))
        let before = await until(hub, "the helper") { !$0.subagents.isEmpty }

        await builder.reset()
        XCTAssertTrue(cli.isClosed)
        let state = await hub.state
        XCTAssertNotEqual(state.conversationID, before.conversationID)
        XCTAssertTrue(state.messages.isEmpty)
        XCTAssertTrue(state.subagents.isEmpty)

        try await builder.handleMessage("Build me a shed")
        XCTAssertEqual(claudeCode.launches.count, 2)
        XCTAssertFalse(claudeCode.launches[1].contains("--resume"))
    }

    func testAHelperInTheBackgroundIsOutUntilItReportsBack() async throws {
        let (builder, hub, claudeCode) = await make(.builder)
        try await builder.handleMessage("Build me an office")
        let cli = try XCTUnwrap(claudeCode.clis.first)
        cli.say(sendsOff("construction-worker", to: "Build an office"))
        cli.say(taskStarted("construction-worker", inBackground: true))
        cli.say(#"{"type":"user","message":{"role":"user","content":[{"type":"tool_result","tool_use_id":"toolu_agent","content":[{"type":"text","text":"Async agent launched successfully."}]}]},"parent_tool_use_id":null,"session_id":"session-1"}"#)
        cli.say(says("My construction worker is on it."))
        cli.say(result(text: "My construction worker is on it."))
        var state = await until(hub, "the end of the turn") { $0.stopReason == .endTurn }
        XCTAssertEqual(state.subagents.map(\.id), ["toolu_agent"])

        // It reports back later, and the Builder takes that up by itself.
        cli.say(taskNotification("completed"))
        await until(hub, "the helper to report back") { $0.subagents.isEmpty }
        cli.say(says("The office is done."))
        state = await until(hub, "the Builder to carry on") { $0.status == .running }
        cli.say(result(text: "The office is done."))
        state = await until(hub, "the end of the turn") { $0.status == .idle }
        XCTAssertEqual(state.messages.last?.text, "The office is done.")
    }

    func testClaudeCodesErrorsAreShownOnce() async throws {
        let (builder, hub, claudeCode) = await make(.builder)
        try await builder.handleMessage("Hello")
        let cli = try XCTUnwrap(claudeCode.clis.first)
        cli.say(#"{"type":"assistant","message":{"role":"assistant","content":[{"type":"text","text":"Not logged in · Please run /login"}]},"parent_tool_use_id":null,"error":"authentication_failed","session_id":"session-1"}"#)
        cli.say(result(isError: true, text: "Not logged in · Please run /login"))
        let state = await until(hub, "the end of the turn") { $0.stopReason == .endTurn }
        XCTAssertEqual(state.messages.map(\.kind), [.user, .error])
        XCTAssertEqual(state.messages.last?.text, "Not logged in · Please run /login")
    }

    func testAClaudeCodeThatWontStartIsReported() async throws {
        let (builder, hub, claudeCode) = await make(.builder)
        claudeCode.failure = ConfigurationError("no such file")
        do {
            try await builder.handleMessage("Hello")
            XCTFail("expected a 503")
        } catch let abort as Abort {
            XCTAssertEqual(abort.status, .serviceUnavailable)
            XCTAssertEqual(abort.reason, "Couldn't start Claude Code for Builder: no such file")
        }
        let state = await hub.state
        XCTAssertTrue(state.messages.isEmpty)
        XCTAssertEqual(state.status, .idle)
    }
}

/// The plumbing to a real child process, with stand-ins for `claude`.
final class ClaudeCodeProcessTests: XCTestCase {
    private func lot() throws -> URL {
        let lot = FileManager.default.temporaryDirectory.appendingPathComponent("lot-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: lot, withIntermediateDirectories: true)
        return lot
    }

    func testMessagesGoInAndComeOutOneLineEach() async throws {
        let cat = try ClaudeCodeProcess(
            executable: URL(fileURLWithPath: "/bin/cat"),
            arguments: [],
            workingDirectory: try lot(),
            environment: [:]
        )
        try cat.send(["type": "user", "message": ["content": "Hello\nthere"]])
        try cat.send(["type": "control_request", "request_id": "1"])
        var received: [JSONValue] = []
        for await message in cat.messages {
            received.append(message)
            if received.count == 2 { cat.close() }
        }
        XCTAssertEqual(received, [
            ["type": "user", "message": ["content": "Hello\nthere"]],
            ["type": "control_request", "request_id": "1"],
        ])
        XCTAssertThrowsError(try cat.send(["type": "user"]))
    }

    func testWhatItSaysOnStderrExplainsWhyItStopped() async throws {
        let process = try ClaudeCodeProcess(
            executable: URL(fileURLWithPath: "/bin/sh"),
            arguments: ["-c", "echo 'not JSON'; echo 'error: unknown option' >&2; exit 1"],
            workingDirectory: try lot(),
            environment: [:]
        )
        for await _ in process.messages {
            XCTFail("nothing it said was a message")
        }
        for _ in 0..<100 where process.diagnostics().isEmpty {
            try await Task.sleep(nanoseconds: 10_000_000)
        }
        XCTAssertEqual(process.diagnostics(), "error: unknown option")
    }

    func testClaudeCodeRunsInTheLotWithHelpersInTheForeground() async throws {
        let lot = try lot()
        let claudeCode = ClaudeCode(executable: URL(fileURLWithPath: "/bin/sh"), lot: lot, model: "haiku")
        // `sh -c` takes the arguments after the script as $0, $1, …
        let script = #"printf '{"background":"%s","directory":"%s","model":"%s %s"}\n' "$CLAUDE_CODE_DISABLE_BACKGROUND_TASKS" "$(pwd -P)" "$0" "$1""#
        let connection = try claudeCode.launch(["-c", script], in: .lot)
        var said: JSONValue?
        for await message in connection.messages {
            said = message
        }
        XCTAssertEqual(said?["background"], "1")
        XCTAssertEqual(said?["model"], "--model haiku")
        let directory = try XCTUnwrap(said?["directory"]?.string)
        // On macOS, /var is a link to /private/var.
        XCTAssertEqual(URL(fileURLWithPath: directory).resolvingSymlinksInPath().path, lot.resolvingSymlinksInPath().path)
    }

    func testCharactersWhoWorkOnALifeWorkInTheCheckout() async throws {
        let checkout = try lot()
        let claudeCode = ClaudeCode(executable: URL(fileURLWithPath: "/bin/sh"), lot: try lot(), repository: checkout)
        let connection = try claudeCode.launch(["-c", #"printf '{"directory":"%s"}\n' "$(pwd -P)""#], in: .aLife)
        var said: JSONValue?
        for await message in connection.messages {
            said = message
        }
        let directory = try XCTUnwrap(said?["directory"]?.string)
        XCTAssertEqual(URL(fileURLWithPath: directory).resolvingSymlinksInPath().path, checkout.resolvingSymlinksInPath().path)

        // Without a checkout, they can't start; the others still can.
        let withoutCheckout = ClaudeCode(executable: URL(fileURLWithPath: "/bin/sh"), lot: try lot())
        XCTAssertThrowsError(try withoutCheckout.launch(["-c", "true"], in: .aLife)) { error in
            XCTAssertEqual("\(error)", "There's no a*life checkout to work in. Set ALIFE_REPO_DIR to one and restart the server.")
        }
        XCTAssertNoThrow(try withoutCheckout.launch(["-c", "true"], in: .lot).close())
    }

    func testTheCheckoutIsALIFE_REPO_DIROrTheOneTheServerWasBuiltFrom() throws {
        // These tests are built from an a*life checkout, too.
        let builtFrom = try XCTUnwrap(ClaudeCode.builtFrom)
        XCTAssertTrue(FileManager.default.fileExists(atPath: builtFrom.appendingPathComponent("a-life-server/Sources/ALifeServer/agents.yaml").path))
        XCTAssertEqual(try ClaudeCode.findRepository(in: [:])?.path, builtFrom.path)
        XCTAssertEqual(try ClaudeCode.findRepository(in: ["ALIFE_REPO_DIR": ""])?.path, builtFrom.path)

        let elsewhere = try lot()
        XCTAssertEqual(try ClaudeCode.findRepository(in: ["ALIFE_REPO_DIR": elsewhere.path])?.path, elsewhere.path)
        let missing = elsewhere.appendingPathComponent("nowhere").path
        XCTAssertThrowsError(try ClaudeCode.findRepository(in: ["ALIFE_REPO_DIR": missing])) { error in
            XCTAssertEqual("\(error)", "ALIFE_REPO_DIR is \(missing), which isn't a directory. Set it to a checkout of a*life.")
        }
    }
}

/// Runs the Builder on the `claude` installed here, to see a real
/// construction worker sent off. It costs a little, so it only runs with
/// `ALIFE_LIVE_CLAUDE=1`; set `ALIFE_CLAUDE_MODEL` to pick the model.
final class LiveClaudeCodeTests: XCTestCase {
    func testBuildMeAnOfficeOnTheRealClaudeCode() async throws {
        let environment = ProcessInfo.processInfo.environment
        try XCTSkipUnless(environment["ALIFE_LIVE_CLAUDE"] == "1", "set ALIFE_LIVE_CLAUDE=1 to run Claude Code for real")
        let executable = try XCTUnwrap(ClaudeCode.findExecutable(in: environment), "no claude command")
        let lot = FileManager.default.temporaryDirectory.appendingPathComponent("a-life-lot-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: lot, withIntermediateDirectories: true)
        let claudeCode = ClaudeCode(executable: executable, lot: lot, model: environment["ALIFE_CLAUDE_MODEL"])

        let hub = SessionHub(id: "builder", name: "Builder")
        let builder = ClaudeCharacter(.builder, hub: hub, claudeCode: claudeCode, logger: Logger(label: "live"))
        await builder.reset()
        let events = await hub.subscribe(conversationID: nil, after: 0)
        try await builder.handleMessage("Build me an office")

        let timeout = Task {
            try await Task.sleep(nanoseconds: 300_000_000_000)
            XCTFail("the Builder took longer than five minutes")
            await hub.closeStreams()
        }
        var helpers: [Subagent] = []
        events: for await envelope in events {
            switch envelope.event {
            case .subagentStarted(let helper):
                helpers.append(helper)
            case .approvalRequested(let approval):
                try await builder.decide(approvalID: approval.id, allow: true)
            case .statusChanged(.idle, stopReason: .endTurn?):
                break events
            default:
                break
            }
        }
        timeout.cancel()
        await builder.shutdown()

        let state = await hub.state
        print(state.messages.map { "\($0.speaker): \($0.text)" }.joined(separator: "\n"))
        XCTAssertFalse(helpers.isEmpty, "the Builder sent no construction worker")
        XCTAssertTrue(state.subagents.isEmpty)
        let buildings = (try? FileManager.default.contentsOfDirectory(atPath: lot.appendingPathComponent("buildings").path)) ?? []
        XCTAssertFalse(buildings.isEmpty, "nothing was built in \(lot.path)")
        XCTAssertFalse(state.messages.contains { $0.kind == .error }, "\(state.messages)")
    }
}

// MARK: Stand-ins

/// Starts `FakeClaudeCLI`s and remembers how each was started.
final class FakeClaudeCode: ClaudeCodeLauncher, @unchecked Sendable {
    private let lock = NSLock()
    private var _launches: [[String]] = []
    private var _workspaces: [Workspace] = []
    private var _clis: [FakeClaudeCLI] = []
    private var _failure: Error?

    var launches: [[String]] { lock.lock(); defer { lock.unlock() }; return _launches }
    /// Where each launch was to work, in the order they were launched.
    var workspaces: [Workspace] { lock.lock(); defer { lock.unlock() }; return _workspaces }
    var clis: [FakeClaudeCLI] { lock.lock(); defer { lock.unlock() }; return _clis }
    /// What starting the CLI fails with, if anything.
    var failure: Error? {
        get { lock.lock(); defer { lock.unlock() }; return _failure }
        set { lock.lock(); defer { lock.unlock() }; _failure = newValue }
    }

    func launch(_ arguments: [String], in workspace: Workspace) throws -> any ClaudeCodeConnection {
        lock.lock()
        defer { lock.unlock() }
        if let _failure { throw _failure }
        let cli = FakeClaudeCLI()
        _launches.append(arguments)
        _workspaces.append(workspace)
        _clis.append(cli)
        return cli
    }
}

/// Stands in for one running `claude`: keeps what it is sent, and says
/// what a test tells it to.
final class FakeClaudeCLI: ClaudeCodeConnection, @unchecked Sendable {
    let messages: AsyncStream<JSONValue>
    private let output: AsyncStream<JSONValue>.Continuation
    private let lock = NSLock()
    private var _sent: [JSONValue] = []
    private var _closed = false

    init() {
        (messages, output) = AsyncStream<JSONValue>.makeStream()
    }

    var sent: [JSONValue] { lock.lock(); defer { lock.unlock() }; return _sent }
    var isClosed: Bool { lock.lock(); defer { lock.unlock() }; return _closed }

    func send(_ message: JSONValue) throws {
        lock.lock()
        defer { lock.unlock() }
        if _closed { throw ClaudeCodeError.closed }
        _sent.append(message)
    }

    func close() {
        lock.lock()
        _closed = true
        lock.unlock()
        output.finish()
    }

    func diagnostics() -> String { "Error: the lot is on fire" }

    /// Writes one line of stream-json, as the CLI would.
    func say(_ line: String) {
        output.yield(try! JSONValue.decode(Data(line.utf8)))
    }

    /// The CLI stops by itself.
    func exit() {
        output.finish()
    }
}
