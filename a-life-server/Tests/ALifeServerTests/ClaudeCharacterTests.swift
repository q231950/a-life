import ALifeClient
@testable import ALifeServer
import Vapor
import XCTest

/// A character played by Claude Code, with a stand-in for the `claude` CLI
/// that speaks its stream-json. The lines it sends are trimmed from what
/// Claude Code 2.1 really writes.
final class ClaudeCharacterTests: XCTestCase {
    private func make(_ character: Character) async -> (ClaudeCharacter, SessionHub, FakeClaudeCode) {
        let hub = SessionHub(id: character.id, name: character.name, model: character.model, fileModel: character.model)
        let claudeCode = FakeClaudeCode()
        let backend = ClaudeCharacter(character, hub: hub, claudeCode: claudeCode, logger: Logger(label: "test"), model: character.model)
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
        XCTAssertEqual(value(after: "--model", in: arguments), "haiku") // the agents file's
        XCTAssertFalse(arguments.contains("--resume"))
        let agents = try JSONValue.decode(Data(XCTUnwrap(value(after: "--agents", in: arguments)).utf8))
        XCTAssertEqual(agents["construction-worker"]?["tools"], ["Read", "Glob", "Grep", "Write", "Edit"])
        XCTAssertEqual(agents["construction-worker"]?["model"], "inherit")
        XCTAssertNil(agents["keeper"])
        XCTAssertTrue(try XCTUnwrap(value(after: "--append-system-prompt", in: arguments)).contains("`construction-worker` agent"))

        // It is told what you said, after the SDK's handshake and asking how
        // full its context is.
        let cli = try XCTUnwrap(claudeCode.clis.first)
        XCTAssertEqual(cli.sent.map { $0["type"]?.string }, ["control_request", "control_request", "user"])
        XCTAssertEqual(cli.sent[0]["request"]?["subtype"], "initialize")
        XCTAssertEqual(cli.sent[1]["request"]?["subtype"], "get_context_usage")
        XCTAssertEqual(cli.sent[2]["message"], ["role": "user", "content": "Build me an office"])
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
        XCTAssertEqual(state.approvals, [Approval(id: "request-write", toolName: "Write", input: "construction-worker: buildings/office.md", toolUseID: "toolu_write")])
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
        // The whole conversation keeps the Builder sending its helper off,
        // and its helper's request with your answer, in order. The helper's
        // own tools aren't in it.
        XCTAssertEqual(state.conversation, [
            .message(state.messages[0]),
            .toolUse(ToolUse(id: "toolu_agent", toolName: "Agent", input: "Build an office")),
            .approval(Approval(id: "request-write", toolName: "Write", input: "construction-worker: buildings/office.md", toolUseID: "toolu_write"), outcome: .allowed),
            .message(state.messages[1]),
        ])
        XCTAssertNil(state.activity)
        XCTAssertEqual(state.status, .idle)
    }

    func testTheConservationistSendsItsKeeper() async throws {
        let (conservationist, hub, claudeCode) = await make(.conservationist)
        try await conservationist.handleMessage("Plant some roses")

        // Its edits on the lot go ahead without asking.
        let arguments = try XCTUnwrap(claudeCode.launches.first)
        XCTAssertEqual(value(after: "--permission-mode", in: arguments), "acceptEdits")
        let agents = try JSONValue.decode(Data(XCTUnwrap(value(after: "--agents", in: arguments)).utf8))
        XCTAssertNotNil(agents["keeper"])
        XCTAssertNil(agents["construction-worker"])

        // A helper sent by an older Claude Code's `Task` tool, reporting back
        // with its tool result alone.
        let cli = try XCTUnwrap(claudeCode.clis.first)
        cli.say(sendsOff("keeper", to: "Plant roses").replacingOccurrences(of: #""name":"Agent""#, with: #""name":"Task""#))
        var state = await until(hub, "the keeper") { !$0.subagents.isEmpty }
        XCTAssertEqual(state.subagents.map(\.task), ["Plant roses"])
        cli.say(helperReport())
        await until(hub, "the keeper to report back") { $0.subagents.isEmpty }
        cli.say(says("Roses are in."))
        cli.say(result(text: "Roses are in."))
        state = await until(hub, "the end of the turn") { $0.stopReason == .endTurn }
        XCTAssertEqual(transcript(state), ["You: Plant some roses", "Conservationist: Roses are in."])
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
        XCTAssertEqual(state.approvals, [Approval(id: "request-test", toolName: "Bash", input: "a-life-expert: swift test --package-path ALifeKit", toolUseID: "toolu_test")])

        try await engineer.decide(approvalID: "request-test", allow: true)
        cli.say(taskNotification("completed"))
        cli.say(helperReport())
        cli.say(says("The sheep jump before they fly off now, and the tests pass."))
        cli.say(result(text: "The sheep jump before they fly off now, and the tests pass."))
        state = await until(hub, "the end of the turn") { $0.stopReason == .endTurn }
        XCTAssertTrue(state.subagents.isEmpty)
        XCTAssertEqual(transcript(state).last, "Engineer: The sheep jump before they fly off now, and the tests pass.")
    }

    func testTheTeamLeadSendsItsRecruiterToAddAnAgent() async throws {
        let (teamLead, hub, claudeCode) = await make(.teamLead)
        try await teamLead.handleMessage("Add a Painter who paints the houses on the lot")

        // On the lot, but asking before every change, with a recruiter that
        // can't write files: it adds agents with the server's command.
        let arguments = try XCTUnwrap(claudeCode.launches.first)
        XCTAssertEqual(claudeCode.workspaces, [.lot])
        XCTAssertEqual(value(after: "--permission-mode", in: arguments), "default")
        let agents = try JSONValue.decode(Data(XCTUnwrap(value(after: "--agents", in: arguments)).utf8))
        XCTAssertEqual(agents["recruiter"]?["tools"], ["Read", "Glob", "Grep", "Bash"])
        XCTAssertNil(agents["construction-worker"])
        XCTAssertTrue(try XCTUnwrap(value(after: "--append-system-prompt", in: arguments)).contains("`recruiter` agent"))

        // The recruiter asks before it adds the agent.
        let cli = try XCTUnwrap(claudeCode.clis.first)
        cli.say(sendsOff("recruiter", to: "Add the Painter"))
        cli.say(taskStarted("recruiter"))
        var state = await until(hub, "the recruiter") { !$0.subagents.isEmpty }
        XCTAssertEqual(state.subagents, [Subagent(id: "toolu_agent", task: "Add the Painter")])
        cli.say(#"{"type":"control_request","request_id":"request-add","request":{"subtype":"can_use_tool","tool_name":"Bash","input":{"command":"\"$ALIFE_SERVER_COMMAND\" add-agent"},"tool_use_id":"toolu_add","agent_id":"task-1"}}"#)
        state = await until(hub, "the approval") { !$0.approvals.isEmpty }
        XCTAssertEqual(state.approvals, [Approval(id: "request-add", toolName: "Bash", input: "recruiter: \"$ALIFE_SERVER_COMMAND\" add-agent", toolUseID: "toolu_add")])

        try await teamLead.decide(approvalID: "request-add", allow: true)
        cli.say(taskNotification("completed"))
        cli.say(helperReport())
        cli.say(says("The Painter is on the team, and joins the lot once you restart the server."))
        cli.say(result(text: "The Painter is on the team, and joins the lot once you restart the server."))
        state = await until(hub, "the end of the turn") { $0.stopReason == .endTurn }
        XCTAssertTrue(state.subagents.isEmpty)
        XCTAssertEqual(transcript(state).last, "Team Lead: The Painter is on the team, and joins the lot once you restart the server.")
    }

    func testDenyingTellsClaudeCodeNo() async throws {
        let (builder, hub, claudeCode) = await make(.builder)
        try await builder.handleMessage("Knock down the shed")
        let cli = try XCTUnwrap(claudeCode.clis.first)
        cli.say(#"{"type":"control_request","request_id":"request-rm","request":{"subtype":"can_use_tool","tool_name":"Bash","input":{"command":"rm -r buildings/shed.md","description":"Remove the shed"},"tool_use_id":"toolu_rm"}}"#)
        var state = await until(hub, "the approval") { !$0.approvals.isEmpty }
        let approval = Approval(id: "request-rm", toolName: "Bash", input: "rm -r buildings/shed.md", toolUseID: "toolu_rm")
        XCTAssertEqual(state.approvals, [approval])

        try await builder.decide(approvalID: "request-rm", allow: false)
        XCTAssertEqual(cli.sent.last?["response"]?["response"]?["behavior"], "deny")
        // It stays in the conversation, saying you said no.
        state = await hub.state
        XCTAssertTrue(state.approvals.isEmpty)
        XCTAssertEqual(state.conversation.last, .approval(approval, outcome: .denied))
        do {
            try await builder.decide(approvalID: "request-rm", allow: true)
            XCTFail("expected a 404")
        } catch let abort as Abort {
            XCTAssertEqual(abort.status, .notFound)
        }
    }

    func testAutoApproveAllowsWithoutAsking() async throws {
        let (builder, hub, claudeCode) = await make(.builder)
        try await builder.handleMessage("Knock down the shed")
        let cli = try XCTUnwrap(claudeCode.clis.first)
        let asksToRemove = #"{"type":"control_request","request_id":"request-rm","request":{"subtype":"can_use_tool","tool_name":"Bash","input":{"command":"rm -r buildings/shed.md"},"tool_use_id":"toolu_rm"}}"#
        let approval = Approval(id: "request-rm", toolName: "Bash", input: "rm -r buildings/shed.md", toolUseID: "toolu_rm")

        // Turned on while it waits, it lets that one through.
        cli.say(asksToRemove)
        await until(hub, "the approval") { !$0.approvals.isEmpty }
        await builder.setAutoApprove(true)
        var state = await hub.state
        XCTAssertTrue(state.autoApprove)
        XCTAssertTrue(state.approvals.isEmpty)
        XCTAssertEqual(state.status, .running)
        XCTAssertEqual(state.conversation.last, .approval(approval, outcome: .autoApproved))
        XCTAssertEqual(cli.sent.last?["response"]?["request_id"], "request-rm")
        XCTAssertEqual(cli.sent.last?["response"]?["response"]?["behavior"], "allow")

        // Afterwards, nothing waits for you, but each request is still shown.
        cli.say(asksToRemove.replacingOccurrences(of: "request-rm", with: "request-rm-2").replacingOccurrences(of: "toolu_rm", with: "toolu_rm_2"))
        state = await until(hub, "the second approval") { $0.conversation.count == 3 }
        let again = Approval(id: "request-rm-2", toolName: "Bash", input: "rm -r buildings/shed.md", toolUseID: "toolu_rm_2")
        XCTAssertEqual(state.conversation.last, .approval(again, outcome: .autoApproved))
        XCTAssertTrue(state.approvals.isEmpty)
        XCTAssertNotEqual(state.stopReason, .requiresAction)
        XCTAssertEqual(cli.sent.last?["response"]?["request_id"], "request-rm-2")
        XCTAssertEqual(cli.sent.last?["response"]?["response"]?["behavior"], "allow")
        do {
            try await builder.decide(approvalID: "request-rm-2", allow: false)
            XCTFail("expected a 404")
        } catch let abort as Abort {
            XCTAssertEqual(abort.status, .notFound)
        }
    }

    func testEverythingTheCharacterSaysAndDoesIsInTheConversation() async throws {
        let (builder, hub, claudeCode) = await make(.builder)
        try await builder.handleMessage("What's on the lot?")
        let cli = try XCTUnwrap(claudeCode.clis.first)

        // It says something, looks, says something more, then asks before it
        // runs a command, which takes the place of that tool use.
        cli.say(says("Let me look."))
        cli.say(#"{"type":"assistant","message":{"role":"assistant","content":[{"type":"tool_use","id":"toolu_read","name":"Read","input":{"file_path":"/lot/lot.md"}}]},"parent_tool_use_id":null,"session_id":"session-1"}"#)
        cli.say(#"{"type":"user","message":{"role":"user","content":[{"type":"tool_result","tool_use_id":"toolu_read","content":"Nothing yet."}]},"parent_tool_use_id":null,"session_id":"session-1"}"#)
        cli.say(says("The lot is empty. I'll count the tiles."))
        cli.say(#"{"type":"assistant","message":{"role":"assistant","content":[{"type":"tool_use","id":"toolu_ls","name":"Bash","input":{"command":"ls buildings"}}]},"parent_tool_use_id":null,"session_id":"session-1"}"#)
        cli.say(#"{"type":"control_request","request_id":"request-ls","request":{"subtype":"can_use_tool","tool_name":"Bash","input":{"command":"ls buildings"},"tool_use_id":"toolu_ls"}}"#)
        await until(hub, "the approval") { !$0.approvals.isEmpty }
        try await builder.decide(approvalID: "request-ls", allow: true)
        cli.say(says("There's nothing on it yet."))
        cli.say(result(text: "There's nothing on it yet."))
        let state = await until(hub, "the end of the turn") { $0.stopReason == .endTurn }

        XCTAssertEqual(transcript(state), [
            "You: What's on the lot?",
            "Builder: Let me look.",
            "Builder: The lot is empty. I'll count the tiles.",
            "Builder: There's nothing on it yet.",
        ])
        XCTAssertEqual(state.conversation.map(\.id), [
            "message-" + state.messages[0].id,
            "message-" + state.messages[1].id,
            "tool-toolu_read",
            "message-" + state.messages[2].id,
            "approval-request-ls",
            "message-" + state.messages[3].id,
        ])
        XCTAssertEqual(state.conversation[2], .toolUse(ToolUse(id: "toolu_read", toolName: "Read", input: "/lot/lot.md")))
        XCTAssertEqual(
            state.conversation[4],
            .approval(Approval(id: "request-ls", toolName: "Bash", input: "ls buildings", toolUseID: "toolu_ls"), outcome: .allowed)
        )
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
        XCTAssertEqual(state.conversation.last?.id, "approval-request-write")
        if case .approval(_, let outcome) = state.conversation.last {
            XCTAssertEqual(outcome, .withdrawn) // nobody answered it
        }
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
        let claudeCode = ClaudeCode(executable: URL(fileURLWithPath: "/bin/sh"), lot: lot)
        // `sh -c` takes the arguments after the script as $1, …: the launcher
        // adds none, as the character's arguments carry its model.
        let script = #"printf '{"background":"%s","directory":"%s","extra":"%s"}\n' "$CLAUDE_CODE_DISABLE_BACKGROUND_TASKS" "$(pwd -P)" "$#""#
        let connection = try claudeCode.launch(["-c", script], in: .lot)
        var said: JSONValue?
        for await message in connection.messages {
            said = message
        }
        XCTAssertEqual(said?["background"], "1")
        XCTAssertEqual(said?["extra"], "0")
        let directory = try XCTUnwrap(said?["directory"]?.string)
        // On macOS, /var is a link to /private/var.
        XCTAssertEqual(URL(fileURLWithPath: directory).resolvingSymlinksInPath().path, lot.resolvingSymlinksInPath().path)
    }

    func testSessionsAreToldTheAgentsFileAndTheServersCommand() async throws {
        // For the Team Lead's recruiter, to add an agent.
        var claudeCode = ClaudeCode(executable: URL(fileURLWithPath: "/bin/sh"), lot: try lot())
        let script = #"printf '{"agents":"%s","server":"%s"}\n' "$ALIFE_AGENTS_FILE" "$ALIFE_SERVER_COMMAND""#
        claudeCode.agentsFile = URL(fileURLWithPath: "/tmp/team/agents.yaml")
        claudeCode.serverCommand = URL(fileURLWithPath: "/tmp/team/ALifeServer")
        var said: JSONValue?
        for await message in try claudeCode.launch(["-c", script], in: .lot).messages {
            said = message
        }
        XCTAssertEqual(said?["agents"], "/tmp/team/agents.yaml")
        XCTAssertEqual(said?["server"], "/tmp/team/ALifeServer")
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

    func testCharactersWhoWorkOnAProjectWorkInIt() async throws {
        let directory = try lot(), clone = try lot()
        var claudeCode = ClaudeCode(executable: URL(fileURLWithPath: "/bin/sh"), lot: try lot())
        claudeCode.clones = [
            "ada": .success(clone),
            "bob": .failure(ConfigurationError("Couldn't clone https://example.com/app.git")),
        ]
        /// The directory a stand-in for `claude` finds itself in.
        func workingDirectory(of workspace: Workspace) async throws -> String {
            let connection = try claudeCode.launch(["-c", #"printf '{"directory":"%s"}\n' "$(pwd -P)""#], in: workspace)
            var said: JSONValue?
            for await message in connection.messages {
                said = message
            }
            return URL(fileURLWithPath: try XCTUnwrap(said?["directory"]?.string)).resolvingSymlinksInPath().path
        }

        let onADirectory = Project(id: "cy", source: .directory(directory))
        let workedIn = try await workingDirectory(of: .project(onADirectory))
        XCTAssertEqual(workedIn, directory.resolvingSymlinksInPath().path)
        let onARepository = Project(id: "ada", source: .repository("https://example.com/app.git", branch: nil))
        let clonedIn = try await workingDirectory(of: .project(onARepository))
        XCTAssertEqual(clonedIn, clone.resolvingSymlinksInPath().path)

        // A project that couldn't be cloned says why; one never cloned, too.
        let failed = Project(id: "bob", source: .repository("https://example.com/app.git", branch: nil))
        XCTAssertThrowsError(try claudeCode.launch(["-c", "true"], in: .project(failed))) { error in
            XCTAssertEqual("\(error)", "Couldn't clone https://example.com/app.git")
        }
        let never = Project(id: "dee", source: .repository("https://example.com/other.git", branch: nil))
        XCTAssertThrowsError(try claudeCode.launch(["-c", "true"], in: .project(never))) { error in
            XCTAssertEqual("\(error)", "https://example.com/other.git hasn't been cloned. Restart the server to clone it.")
        }

        // A project of several repositories works in the directory their clones are in.
        let clones = try lot()
        claudeCode.clones["eve"] = .success(clones)
        let repositories = [Project.Repository(address: "https://example.com/app.git"), Project.Repository(address: "https://example.com/server.git")]
        let onRepositories = Project(id: "eve", source: .repositories(repositories))
        let worksIn = try await workingDirectory(of: .project(onRepositories))
        XCTAssertEqual(worksIn, clones.resolvingSymlinksInPath().path)
        let neverCloned = Project(id: "fay", source: .repositories(repositories))
        XCTAssertThrowsError(try claudeCode.launch(["-c", "true"], in: .project(neverCloned))) { error in
            XCTAssertEqual("\(error)", "https://example.com/app.git, https://example.com/server.git haven't been cloned. Restart the server to clone them.")
        }
    }

    func testProjectsAreClonedIntoALIFE_PROJECTS_DIR() {
        XCTAssertEqual(
            ClaudeCode.projectsDirectory(in: [:]).path,
            FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("a-life-projects").path
        )
        XCTAssertEqual(ClaudeCode.projectsDirectory(in: ["ALIFE_PROJECTS_DIR": ""]).lastPathComponent, "a-life-projects")
        XCTAssertEqual(
            ClaudeCode.projectsDirectory(in: ["ALIFE_PROJECTS_DIR": "~/elsewhere"]).path,
            FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("elsewhere").path
        )
    }

    /// Runs git in `directory`, and returns what it printed.
    @discardableResult
    private func git(_ arguments: [String], in directory: URL) throws -> String {
        let git = Process()
        git.executableURL = URL(fileURLWithPath: "/usr/bin/env")
        git.arguments = ["git", "-c", "user.name=a*life", "-c", "user.email=a-life@example.com", "-c", "commit.gpgsign=false"] + arguments
        git.currentDirectoryURL = directory
        let output = Pipe(), errors = Pipe()
        git.standardOutput = output
        git.standardError = errors
        try git.run()
        let printed = String(decoding: output.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self)
        let complaint = String(decoding: errors.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self)
        git.waitUntilExit()
        XCTAssertEqual(git.terminationStatus, 0, "git \(arguments.joined(separator: " ")): \(complaint)")
        return printed.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    func testAProjectsRepositoryIsClonedOnceAndThenReusedAsItIs() throws {
        // A repository with a main and a feature branch, on this machine.
        let place = try lot()
        defer { try? FileManager.default.removeItem(at: place) }
        let bare = place.appendingPathComponent("app.git")
        let work = place.appendingPathComponent("work")
        try FileManager.default.createDirectory(at: work, withIntermediateDirectories: true)
        try git(["init", "--quiet", "--bare", "-b", "main", bare.path], in: place)
        try git(["init", "--quiet", "-b", "main"], in: work)
        try "# App\n".write(to: work.appendingPathComponent("README.md"), atomically: true, encoding: .utf8)
        try git(["add", "README.md"], in: work)
        try git(["commit", "--quiet", "-m", "First"], in: work)
        try git(["branch", "feature"], in: work)
        try git(["push", "--quiet", bare.path, "main", "feature"], in: work)
        let address = bare.absoluteString // file:///…/app.git
        let projects = place.appendingPathComponent("projects")

        // The first start clones it, into a directory named after its character.
        let first = try ClaudeCode.checkOut(address, branch: nil, for: "ada", in: projects)
        let clone = projects.appendingPathComponent("ada", isDirectory: true)
        XCTAssertEqual(first, .cloned(clone))
        XCTAssertEqual(try String(contentsOf: clone.appendingPathComponent("README.md"), encoding: .utf8), "# App\n")
        XCTAssertEqual(try git(["rev-parse", "--abbrev-ref", "HEAD"], in: clone), "main")

        // Later starts use it as it is, with whatever was done in it.
        try "Half done".write(to: clone.appendingPathComponent("notes.txt"), atomically: true, encoding: .utf8)
        try git(["checkout", "--quiet", "feature"], in: clone)
        XCTAssertEqual(try ClaudeCode.checkOut(address, branch: nil, for: "ada", in: projects), .reused(clone))
        XCTAssertEqual(try String(contentsOf: clone.appendingPathComponent("notes.txt"), encoding: .utf8), "Half done")
        XCTAssertEqual(try git(["rev-parse", "--abbrev-ref", "HEAD"], in: clone), "feature")

        // A branch is checked out when it is cloned.
        let onFeature = try ClaudeCode.checkOut(address, branch: "feature", for: "bob", in: projects)
        XCTAssertEqual(try git(["rev-parse", "--abbrev-ref", "HEAD"], in: onFeature.directory), "feature")

        // A repository that isn't there says so, and leaves nothing behind
        // to stop the next start trying again.
        let nowhere = place.appendingPathComponent("nowhere.git").absoluteString
        XCTAssertThrowsError(try ClaudeCode.checkOut(nowhere, branch: nil, for: "cy", in: projects)) { error in
            XCTAssertTrue("\(error)".hasPrefix("Couldn't clone \(nowhere) into \(projects.appendingPathComponent("cy").path): "), "\(error)")
        }
        XCTAssertFalse(FileManager.default.fileExists(atPath: projects.appendingPathComponent("cy").path))
        XCTAssertThrowsError(try ClaudeCode.checkOut(address, branch: "no-such-branch", for: "cy", in: projects)) { error in
            XCTAssertTrue("\(error)".hasPrefix("Couldn't clone \(address) at no-such-branch into "), "\(error)")
        }

        // Something else in the clone's place isn't cloned over.
        let taken = projects.appendingPathComponent("dee")
        try FileManager.default.createDirectory(at: taken, withIntermediateDirectories: true)
        try "Mine".write(to: taken.appendingPathComponent("mine.txt"), atomically: true, encoding: .utf8)
        XCTAssertThrowsError(try ClaudeCode.checkOut(address, branch: nil, for: "dee", in: projects)) { error in
            XCTAssertEqual("\(error)", "\(taken.path) is there, but isn't a git checkout, so \(address) won't be cloned over it. Move it out of the way and restart the server.")
        }
        XCTAssertEqual(try String(contentsOf: taken.appendingPathComponent("mine.txt"), encoding: .utf8), "Mine")
    }

    func testAProjectsRepositoriesAreClonedSideBySideOnceAndThenReusedAsTheyAre() throws {
        // Two repositories on this machine, an app and its server.
        let place = try lot()
        defer { try? FileManager.default.removeItem(at: place) }
        var addresses: [String] = []
        for name in ["app", "server"] {
            let bare = place.appendingPathComponent("\(name).git")
            let work = place.appendingPathComponent("work-\(name)")
            try FileManager.default.createDirectory(at: work, withIntermediateDirectories: true)
            try git(["init", "--quiet", "--bare", "-b", "main", bare.path], in: place)
            try git(["init", "--quiet", "-b", "main"], in: work)
            try "# \(name)\n".write(to: work.appendingPathComponent("README.md"), atomically: true, encoding: .utf8)
            try git(["add", "README.md"], in: work)
            try git(["commit", "--quiet", "-m", "First"], in: work)
            try git(["branch", "feature"], in: work)
            try git(["push", "--quiet", bare.path, "main", "feature"], in: work)
            addresses.append(bare.absoluteString)
        }
        let projects = place.appendingPathComponent("projects")
        let repositories = [
            Project.Repository(address: addresses[0]),
            Project.Repository(address: addresses[1], branch: "feature"),
        ]

        // The first start clones each into the character's directory, named after it.
        let home = projects.appendingPathComponent("ada", isDirectory: true)
        let app = home.appendingPathComponent("app", isDirectory: true)
        let server = home.appendingPathComponent("server", isDirectory: true)
        let first = ClaudeCode.checkOut(repositories, for: "ada", in: projects)
        XCTAssertEqual(try first.map { try $0.get() }, [.cloned(app), .cloned(server)])
        XCTAssertEqual(try String(contentsOf: app.appendingPathComponent("README.md"), encoding: .utf8), "# app\n")
        XCTAssertEqual(try git(["rev-parse", "--abbrev-ref", "HEAD"], in: app), "main")
        XCTAssertEqual(try git(["rev-parse", "--abbrev-ref", "HEAD"], in: server), "feature")

        // Later starts use them as they are.
        try "Half done".write(to: app.appendingPathComponent("notes.txt"), atomically: true, encoding: .utf8)
        let again = ClaudeCode.checkOut(repositories, for: "ada", in: projects)
        XCTAssertEqual(try again.map { try $0.get() }, [.reused(app), .reused(server)])
        XCTAssertEqual(try String(contentsOf: app.appendingPathComponent("notes.txt"), encoding: .utf8), "Half done")

        // One that can't be cloned says why; the others are cloned all the same.
        let nowhere = place.appendingPathComponent("nowhere.git").absoluteString
        let partly = ClaudeCode.checkOut([Project.Repository(address: nowhere)] + repositories, for: "bob", in: projects)
        XCTAssertEqual(partly.count, 3)
        guard case .failure(let problem) = partly[0] else { return XCTFail("\(partly[0])") }
        XCTAssertTrue("\(problem)".hasPrefix("Couldn't clone \(nowhere) into \(projects.appendingPathComponent("bob/nowhere").path): "), "\(problem)")
        XCTAssertEqual(try partly[1].get(), .cloned(projects.appendingPathComponent("bob/app", isDirectory: true)))

        // The clone of a single repository from before isn't cloned into.
        _ = try ClaudeCode.checkOut(addresses[0], branch: nil, for: "cy", in: projects)
        let single = projects.appendingPathComponent("cy", isDirectory: true)
        for checkout in ClaudeCode.checkOut(repositories, for: "cy", in: projects) {
            guard case .failure(let problem) = checkout else { return XCTFail("\(checkout)") }
            XCTAssertEqual("\(problem)", "\(single.path) is a git checkout itself, so the project's repos won't be cloned into it. Move it out of the way and restart the server.")
        }
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
/// `ALIFE_LIVE_CLAUDE=1`. It runs on the Builder's model, haiku.
final class LiveClaudeCodeTests: XCTestCase {
    func testBuildMeAnOfficeOnTheRealClaudeCode() async throws {
        let environment = ProcessInfo.processInfo.environment
        try XCTSkipUnless(environment["ALIFE_LIVE_CLAUDE"] == "1", "set ALIFE_LIVE_CLAUDE=1 to run Claude Code for real")
        let executable = try XCTUnwrap(ClaudeCode.findExecutable(in: environment), "no claude command")
        let lot = FileManager.default.temporaryDirectory.appendingPathComponent("a-life-lot-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: lot, withIntermediateDirectories: true)
        let claudeCode = ClaudeCode(executable: executable, lot: lot)

        let hub = SessionHub(id: "builder", name: "Builder")
        let builder = ClaudeCharacter(.builder, hub: hub, claudeCode: claudeCode, logger: Logger(label: "live"), model: Character.builder.model)
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
            case .statusChanged(.idle, stopReason: .endTurn?, _):
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
