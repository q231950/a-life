import ALifeAPI
import Foundation
import Vapor

/// A character played by a Claude Code session of its own.
///
/// The session is the `claude` CLI, driven the way the Agent SDK drives it:
/// what you say goes in on its stdin, and what it does comes out of its
/// stdout as stream-json, which this turns into the session's events.
///
/// - Its replies become messages, everything it says along the way as well
///   as its answer at the end.
/// - Each tool it uses is a tool use in the conversation, so you can follow
///   along. Its helpers' tools aren't: they're out working on their own.
/// - When it wants to use a tool that needs permission, the CLI asks over
///   the same pipe (`can_use_tool`), and that becomes an approval that waits
///   for a front end to answer.
/// - When it sends a subagent off (a call to the `Agent` tool), that is a
///   helper out, until the subagent reports back. Each character has one
///   subagent of its own, defined with `--agents`: see `Character.helper`.
///
/// The CLI runs where the character works: on the lot, in the a*life
/// checkout for the Engineer, or in a project of its own
/// (`Character.workspace`). It starts with the
/// first message of a conversation and keeps running, so the character
/// remembers what was said. Starting over stops
/// it; the next message starts a fresh session. If the CLI stops on its own,
/// the next message resumes the same session.
///
/// A turn that ends on Claude's 5-hour usage limit isn't the end of the
/// job: the character waits for the limit to reset, and a minute after it
/// tells itself "please continue", as a*life, in the same session. Telling
/// it anything yourself, stopping it or starting it over calls that off.
/// Who is waiting is kept in `PendingContinues`, so it outlasts a restart.
/// The weekly limits are only reported.
actor ClaudeCharacter: SessionBackend {
    /// What a*life says to a character once the usage limit has reset.
    static let pleaseContinue = "please continue"
    /// How long after the limit resets the character carries on, to be sure
    /// it has.
    static let afterReset: TimeInterval = 60
    /// How soon after the server starts a character carries on whose limit
    /// reset while the server wasn't running.
    static let afterStart: TimeInterval = 10

    private let character: Character
    private let hub: SessionHub
    private let claudeCode: any ClaudeCodeLauncher
    private let logger: Logger
    private let continues: PendingContinues
    private let clock: any WakeClock

    /// The CLI playing the character in this conversation, once started.
    private var connection: (any ClaudeCodeConnection)?
    /// The Claude Code session the conversation is in, once the CLI has
    /// said, so that it can be resumed.
    private var claudeSessionID: String?
    /// Whether the character is taking a turn: from what you say until the
    /// CLI reports the result.
    private var turnActive = false
    /// An interrupted turn still ends with a result, which mustn't end the
    /// next turn too. The interrupt already said the character stopped.
    private var swallowNextResult = false
    /// Tool calls waiting for a yes or no, by the CLI's request id, with the
    /// input to allow them with.
    private var approvals: [String: JSONValue] = [:]
    /// Helpers out, by the id of the tool call that sent them off.
    private var helpers: [String: HelperOut] = [:]
    private var activity: String?
    /// What the character last said in this turn, so the turn's result isn't
    /// repeated.
    private var lastReply: String?
    /// What Claude Code last said about the usage limits.
    private var rateLimit: UsageLimit.Info?
    /// Whether this turn ran into a usage limit, and what Claude Code said
    /// about it, held back until the turn ends in case the character waits
    /// it out rather than having it shown as an error.
    private var hitLimit = false
    private var limitNotice: String?
    /// Waits for the usage limit to reset, then carries on.
    private var waitingForLimit: Task<Void, Never>?

    private struct HelperOut {
        /// The kind of subagent, such as `construction-worker`.
        var agentType: String?
        /// Claude Code's id for its work, which its own requests carry.
        var taskID: String?
        /// Whether it works on after the call that sent it returns.
        var inBackground = false
    }

    init(
        _ character: Character,
        hub: SessionHub,
        claudeCode: any ClaudeCodeLauncher,
        logger: Logger,
        continues: PendingContinues = PendingContinues(file: nil),
        clock: any WakeClock = SystemWakeClock()
    ) {
        self.character = character
        self.hub = hub
        self.claudeCode = claudeCode
        self.logger = logger
        self.continues = continues
        self.clock = clock
    }

    /// The CLI's arguments, apart from the model, which the launcher adds.
    var arguments: [String] {
        let agents: JSONValue = [character.helper.name: character.helper.definition]
        var arguments = [
            "--print",
            "--input-format", "stream-json",
            "--output-format", "stream-json",
            "--verbose",
            // Permission requests come to this server, over stdio.
            "--permission-prompt-tool", "stdio",
            "--permission-mode", character.permissionMode,
            "--append-system-prompt", character.role,
            "--agents", String(decoding: (try? agents.encoded()) ?? Data("{}".utf8), as: UTF8.self),
        ]
        if let claudeSessionID {
            arguments += ["--resume", claudeSessionID]
        }
        return arguments
    }

    // MARK: SessionBackend

    func handleMessage(_ text: String) async throws {
        guard approvals.isEmpty else {
            throw Abort(.conflict, reason: "\(character.name) is waiting for an answer to its request")
        }
        await stopWaitingForLimit() // you've said what to do next
        try await say(text, as: "You")
    }

    /// Tells the character `text`, as `speaker`, starting its CLI if needed.
    private func say(_ text: String, as speaker: String) async throws {
        let connection = try startIfNeeded()
        let startsTurn = !turnActive
        turnActive = true
        await hub.emit(.message(Message(kind: .user, speaker: speaker, text: text)))
        if startsTurn {
            await hub.emit(.statusChanged(.running, stopReason: nil))
        }
        // Said mid-turn, Claude Code takes it up at its next step.
        do {
            try connection.send([
                "type": "user",
                "message": ["role": "user", "content": .string(text)],
                "parent_tool_use_id": .null,
                "session_id": "",
            ])
        } catch {
            // The CLI has gone. Whatever reads its output reports that.
            throw Abort(.serviceUnavailable, reason: "\(character.name)'s Claude Code session has stopped")
        }
    }

    func interrupt() async {
        if await stopWaitingForLimit(), !(turnActive || !approvals.isEmpty || !helpers.isEmpty) {
            await hub.emit(.statusChanged(.idle, stopReason: .interrupted))
            return
        }
        guard let connection, turnActive || !approvals.isEmpty || !helpers.isEmpty else { return }
        if turnActive { swallowNextResult = true }
        turnActive = false
        try? connection.send(Self.controlRequest(["subtype": "interrupt"]))
        // Helpers in the background aren't stopped by the interrupt.
        for helper in helpers.values where helper.inBackground {
            if let taskID = helper.taskID {
                try? connection.send(Self.controlRequest(["subtype": "stop_task", "task_id": .string(taskID)]))
            }
        }
        await callEveryoneBack()
        await setActivity(nil)
        await hub.emit(.statusChanged(.idle, stopReason: .interrupted))
    }

    func decide(approvalID: String, allow: Bool) async throws {
        guard await settle(approvalID, allow: allow, as: allow ? .allowed : .denied) else {
            throw Abort(.notFound, reason: "No such approval")
        }
        if approvals.isEmpty, turnActive {
            await hub.emit(.statusChanged(.running, stopReason: nil))
        }
    }

    func setAutoApprove(_ enabled: Bool) async {
        await hub.setAutoApprove(enabled)
        guard enabled, !approvals.isEmpty else { return }
        for id in approvals.keys {
            _ = await settle(id, allow: true, as: .autoApproved)
        }
        if approvals.isEmpty, turnActive {
            await hub.emit(.statusChanged(.running, stopReason: nil))
        }
    }

    func reset() async {
        await stopWaitingForLimit()
        connection?.close()
        connection = nil
        claudeSessionID = nil
        turnActive = false
        swallowNextResult = false
        lastReply = nil
        rateLimit = nil
        hitLimit = false
        limitNotice = nil
        activity = nil
        await callEveryoneBack()
        await hub.startConversation()
    }

    func shutdown() async {
        // What it waits for stays in `continues`, for the next start.
        waitingForLimit?.cancel()
        waitingForLimit = nil
        connection?.close()
        connection = nil
    }

    // MARK: The usage limit

    /// Waits for the limit `waiting` ran into before the server restarted,
    /// and carries on in its Claude Code session after it resets: straight
    /// after starting if it has reset already.
    func carryOn(after waiting: PendingContinues.Entry) async {
        claudeSessionID = waiting.claudeSessionID
        let soonest = clock.now().addingTimeInterval(Self.afterStart)
        let resumesAt = max(waiting.resetsAt.addingTimeInterval(Self.afterReset), soonest)
        await wait(until: resumesAt, for: waiting)
        logger.notice("\(character.name) is still waiting for the usage limit to reset, and carries on at \(resumesAt)")
        await hub.emit(.statusChanged(.idle, stopReason: .usageLimit, resumesAt: resumesAt))
    }

    /// Remembers that the character waits for the limit to reset, and
    /// carries on at `resumesAt`.
    private func wait(until resumesAt: Date, for waiting: PendingContinues.Entry) async {
        waitingForLimit?.cancel()
        await continues.set(waiting)
        let clock = self.clock
        waitingForLimit = Task { [weak self] in
            do {
                try await clock.sleep(until: resumesAt)
            } catch {
                return // called off
            }
            await self?.continueAfterLimit()
        }
    }

    /// Calls off carrying on after the limit. Returns whether it was waiting.
    @discardableResult
    private func stopWaitingForLimit() async -> Bool {
        guard let waitingForLimit else { return false }
        waitingForLimit.cancel()
        self.waitingForLimit = nil
        await continues.remove(character.id)
        logger.info("\(character.name) no longer waits for the usage limit")
        return true
    }

    /// The limit has reset: tells the character to carry on.
    private func continueAfterLimit() async {
        guard waitingForLimit != nil, !Task.isCancelled else { return }
        waitingForLimit = nil
        await continues.remove(character.id)
        guard approvals.isEmpty else { return }
        logger.notice("The usage limit has reset, so \(character.name) carries on")
        do {
            try await say(Self.pleaseContinue, as: Message.aLife)
        } catch {
            let reason = (error as? AbortError)?.reason ?? "\(error)"
            await hub.emit(.message(Message(kind: .error, speaker: character.name, text: "Couldn't carry on after the usage limit: \(reason)")))
            turnActive = false
            await hub.emit(.statusChanged(.idle, stopReason: .endTurn))
        }
    }

    // MARK: The CLI

    private func startIfNeeded() throws -> any ClaudeCodeConnection {
        if let connection { return connection }
        let connection: any ClaudeCodeConnection
        do {
            connection = try claudeCode.launch(arguments, in: character.workspace)
        } catch {
            logger.error("Couldn't start Claude Code for \(character.name): \(error)")
            throw Abort(.serviceUnavailable, reason: "Couldn't start Claude Code for \(character.name): \(error)")
        }
        self.connection = connection
        logger.info("Started Claude Code for \(character.name)")
        try? connection.send(Self.controlRequest(["subtype": "initialize"]))
        Task { [weak self] in
            for await message in connection.messages {
                await self?.handle(message, from: connection)
            }
            await self?.ended(connection)
        }
        return connection
    }

    private func handle(_ message: JSONValue, from connection: any ClaudeCodeConnection) async {
        guard connection === self.connection else { return } // from before a reset
        if let sessionID = message["session_id"]?.string, !sessionID.isEmpty, sessionID != claudeSessionID {
            claudeSessionID = sessionID
            logger.info("\(character.name) is Claude Code session \(sessionID)")
        }
        switch message["type"]?.string {
        case "rate_limit_event":
            if let info = UsageLimit.Info(message["rate_limit_info"]) { rateLimit = info }
        case "assistant": await handleAssistant(message)
        case "user": await handleToolResults(message)
        case "system": await handleSystem(message)
        case "result": await handleResult(message)
        case "control_request": await handleControlRequest(message, from: connection)
        case "control_cancel_request": await withdrawApproval(message["request_id"]?.string)
        default: break
        }
    }

    /// Something the character, or one of its helpers, says or does.
    private func handleAssistant(_ message: JSONValue) async {
        let fromHelper = message["parent_tool_use_id"]?.string != nil
        if !fromHelper, !turnActive, !swallowNextResult {
            // It took up something without being asked, such as a helper's
            // report from the background.
            turnActive = true
            await hub.emit(.statusChanged(.running, stopReason: nil))
        }
        for block in message["message"]?["content"]?.array ?? [] {
            switch block["type"]?.string {
            case "text" where !fromHelper:
                let text = (block["text"]?.string ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
                guard !text.isEmpty else { continue }
                lastReply = text
                if let error = message["error"], UsageLimit.isLimit(error: error.string, text: text) {
                    // Shown when the turn ends, unless it is waited out.
                    hitLimit = true
                    limitNotice = text
                    continue
                }
                let kind: Message.Kind = message["error"] == nil ? .agent : .error
                await hub.emit(.message(Message(kind: kind, speaker: character.name, text: text)))
            case "tool_use":
                guard let id = block["id"]?.string, let name = block["name"]?.string else { continue }
                if !fromHelper {
                    let input = Self.isAgentTool(name)
                        ? block["input"]?["description"]?.string ?? ""
                        : Self.summarise(block["input"])
                    await hub.emit(.toolUsed(ToolUse(id: id, toolName: name, input: input)))
                }
                if Self.isAgentTool(name) {
                    let input = block["input"]
                    await sendOff(
                        id: id,
                        task: input?["description"]?.string,
                        agentType: input?["subagent_type"]?.string,
                        inBackground: input?["run_in_background"]?.bool ?? false
                    )
                }
                if !fromHelper {
                    await setActivity(Self.isAgentTool(name) ? "agent" : name.lowercased())
                }
            default:
                break
            }
        }
    }

    /// The results of tool calls, which end a helper's errand when the call
    /// sent one off.
    private func handleToolResults(_ message: JSONValue) async {
        var sawResult = false
        for block in message["message"]?["content"]?.array ?? [] where block["type"]?.string == "tool_result" {
            sawResult = true
            if let id = block["tool_use_id"]?.string, let helper = helpers[id], !helper.inBackground {
                await reportedBack(id)
            }
        }
        if sawResult, message["parent_tool_use_id"]?.string == nil {
            await setActivity(helpers.values.contains { !$0.inBackground } ? "agent" : nil)
        }
    }

    /// Claude Code's own reports. The ones about tasks follow subagents,
    /// including those in the background.
    private func handleSystem(_ message: JSONValue) async {
        switch message["subtype"]?.string {
        case "task_started":
            // Background shell commands are tasks too.
            let taskType = message["task_type"]?.string ?? "local_agent"
            guard taskType == "local_agent", let id = message["tool_use_id"]?.string else { return }
            await sendOff(
                id: id,
                task: message["description"]?.string,
                agentType: message["subagent_type"]?.string,
                inBackground: message["is_backgrounded"]?.bool ?? false
            )
            helpers[id]?.taskID = message["task_id"]?.string
            if let inBackground = message["is_backgrounded"]?.bool {
                helpers[id]?.inBackground = inBackground
            }
        case "task_notification":
            if let id = message["tool_use_id"]?.string, helpers[id] != nil {
                await reportedBack(id)
            } else if let taskID = message["task_id"]?.string {
                await reportedBack(taskID: taskID)
            }
        case "task_updated":
            let status = message["patch"]?["status"]?.string ?? ""
            if ["completed", "failed", "killed", "stopped", "cancelled"].contains(status),
               let taskID = message["task_id"]?.string
            {
                await reportedBack(taskID: taskID)
            }
        default:
            break
        }
    }

    /// The end of a turn.
    private func handleResult(_ message: JSONValue) async {
        // Helpers in the foreground can't outlive the turn that sent them.
        for (id, helper) in helpers where !helper.inBackground {
            await reportedBack(id)
        }
        await setActivity(nil)
        let reply = lastReply
        lastReply = nil
        var hitLimit = self.hitLimit
        let limitNotice = self.limitNotice
        self.hitLimit = false
        self.limitNotice = nil
        if swallowNextResult {
            swallowNextResult = false
            return
        }

        let result = (message["result"]?.string ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        let isError = message["is_error"]?.bool == true
        if isError, UsageLimit.isLimit(error: nil, text: result) || rateLimit?.status == "rejected" {
            hitLimit = true
        }
        // The 5-hour limit is waited out; any other is an error, as ever.
        var resumesAt: Date?
        if hitLimit, approvals.isEmpty, let claudeSessionID,
           let resetsAt = UsageLimit.fiveHourReset(info: rateLimit, text: limitNotice ?? result, now: clock.now())
        {
            let at = resetsAt.addingTimeInterval(Self.afterReset)
            await wait(until: at, for: PendingContinues.Entry(character: character.id, claudeSessionID: claudeSessionID, resetsAt: resetsAt))
            logger.notice("\(character.name) ran into the 5-hour usage limit, which resets at \(resetsAt), and carries on at \(at)")
            resumesAt = at
        } else {
            if let limitNotice {
                await hub.emit(.message(Message(kind: .error, speaker: character.name, text: limitNotice)))
            }
            if isError {
                let errors = message["errors"]?.array?.compactMap(\.string).joined(separator: " ") ?? ""
                let text = [result, errors].first { !$0.isEmpty }
                    ?? "Claude Code stopped (\(message["subtype"]?.string ?? "error"))."
                if text != reply {
                    await hub.emit(.message(Message(kind: .error, speaker: character.name, text: text)))
                }
            } else if reply == nil, !result.isEmpty {
                await hub.emit(.message(Message(kind: .agent, speaker: character.name, text: result)))
            }
        }
        if approvals.isEmpty {
            turnActive = false
            await hub.emit(.statusChanged(.idle, stopReason: resumesAt == nil ? .endTurn : .usageLimit, resumesAt: resumesAt))
        }
    }

    private func handleControlRequest(_ message: JSONValue, from connection: any ClaudeCodeConnection) async {
        guard let requestID = message["request_id"]?.string, let request = message["request"] else { return }
        guard request["subtype"]?.string == "can_use_tool" else {
            // Hooks, MCP servers and the like, which this server doesn't host.
            let subtype = request["subtype"]?.string ?? "this request"
            try? connection.send(Self.controlError(to: requestID, "a*life doesn't handle \(subtype)"))
            return
        }
        let toolName = request["display_name"]?.string ?? request["tool_name"]?.string ?? "a tool"
        var input = Self.describe(request)
        if let agentID = request["agent_id"]?.string,
           let helper = helpers.values.first(where: { $0.taskID == agentID })
        {
            input = "\(helper.agentType ?? "Its helper"): \(input)"
        }
        let startsWaiting = approvals.isEmpty
        approvals[requestID] = request["input"] ?? [:]
        let approval = Approval(id: requestID, toolName: toolName, input: input, toolUseID: request["tool_use_id"]?.string)
        // Asked in the conversation all the same, so you can see what was let through.
        await hub.emit(.approvalRequested(approval))
        if await hub.state.autoApprove {
            _ = await settle(requestID, allow: true, as: .autoApproved)
        } else if startsWaiting {
            await hub.emit(.statusChanged(.idle, stopReason: .requiresAction))
        }
    }

    /// Gives Claude Code the answer to a tool call that waits for one, and
    /// says how it was settled. Returns `false` if it no longer waits.
    private func settle(_ approvalID: String, allow: Bool, as outcome: ApprovalOutcome) async -> Bool {
        guard let input = approvals.removeValue(forKey: approvalID) else { return false }
        let decision: JSONValue = allow
            ? ["behavior": "allow", "updatedInput": input]
            : ["behavior": "deny", "message": "The person you're working for said no to this."]
        try? connection?.send(Self.controlResponse(to: approvalID, decision))
        await hub.emit(.approvalResolved(approvalID: approvalID, outcome: outcome))
        return true
    }

    /// Claude Code no longer needs an answer, such as after an interrupt.
    private func withdrawApproval(_ requestID: String?) async {
        guard let requestID, approvals.removeValue(forKey: requestID) != nil else { return }
        await hub.emit(.approvalResolved(approvalID: requestID, outcome: .withdrawn))
        if approvals.isEmpty, turnActive {
            await hub.emit(.statusChanged(.running, stopReason: nil))
        }
    }

    /// The CLI has exited.
    private func ended(_ connection: any ClaudeCodeConnection) async {
        guard connection === self.connection else { return } // stopped on purpose
        self.connection = nil
        let wasWorking = turnActive || !approvals.isEmpty || !helpers.isEmpty
        turnActive = false
        swallowNextResult = false
        lastReply = nil
        await callEveryoneBack()
        await setActivity(nil)
        let diagnostics = connection.diagnostics()
        logger.warning("Claude Code for \(character.name) stopped. \(diagnostics)")
        guard wasWorking else { return } // the next message starts it again
        var text = "Claude Code stopped unexpectedly."
        if !diagnostics.isEmpty { text += " " + diagnostics }
        await hub.emit(.message(Message(kind: .error, speaker: character.name, text: text)))
        await hub.emit(.statusChanged(.idle, stopReason: .endTurn))
    }

    // MARK: Helpers

    private func sendOff(id: String, task: String?, agentType: String?, inBackground: Bool) async {
        guard helpers[id] == nil else { return }
        helpers[id] = HelperOut(agentType: agentType, inBackground: inBackground)
        let task = [task, agentType].compactMap { $0 }.first { !$0.isEmpty } ?? "Helping out"
        await hub.emit(.subagentStarted(Subagent(id: id, task: task)))
    }

    private func reportedBack(_ id: String) async {
        guard helpers.removeValue(forKey: id) != nil else { return }
        await hub.emit(.subagentFinished(subagentID: id))
    }

    private func reportedBack(taskID: String) async {
        for (id, helper) in helpers where helper.taskID == taskID {
            await reportedBack(id)
        }
    }

    /// Withdraws every pending approval and calls every helper back.
    private func callEveryoneBack() async {
        let withdrawn = approvals.keys
        let calledBack = helpers.keys
        approvals = [:]
        helpers = [:]
        for id in withdrawn {
            await hub.emit(.approvalResolved(approvalID: id, outcome: .withdrawn))
        }
        for id in calledBack {
            await hub.emit(.subagentFinished(subagentID: id))
        }
    }

    private func setActivity(_ activity: String?) async {
        guard activity != self.activity else { return }
        self.activity = activity
        await hub.emit(.activityChanged(activity))
    }

    // MARK: Wire format

    /// The tool that sends a subagent off. Older versions call it `Task`.
    private static func isAgentTool(_ name: String) -> Bool {
        name == "Agent" || name == "Task"
    }

    /// What a tool call that needs permission would do, as text to show.
    static func describe(_ request: JSONValue) -> String {
        let input = request["input"]
        if let command = input?["command"]?.string { return command }
        if let description = request["description"]?.string, !description.isEmpty { return description }
        let summary = summarise(input)
        if !summary.isEmpty { return summary }
        guard let input, let json = try? input.encoded() else { return "" }
        let text = String(decoding: json, as: UTF8.self)
        return text.count > 500 ? String(text.prefix(500)) + "…" : text
    }

    /// What a tool call does in a few words, such as its command or the
    /// file it works on. Empty if there's nothing short to say.
    static func summarise(_ input: JSONValue?) -> String {
        for key in ["command", "file_path", "notebook_path", "path", "url", "query", "pattern", "description"] {
            if let value = input?[key]?.string, !value.isEmpty { return value }
        }
        return ""
    }

    private static func controlRequest(_ request: JSONValue) -> JSONValue {
        ["type": "control_request", "request_id": .string(UUID().uuidString), "request": request]
    }

    private static func controlResponse(to requestID: String, _ response: JSONValue) -> JSONValue {
        [
            "type": "control_response",
            "response": ["subtype": "success", "request_id": .string(requestID), "response": response],
        ]
    }

    private static func controlError(to requestID: String, _ error: String) -> JSONValue {
        [
            "type": "control_response",
            "response": ["subtype": "error", "request_id": .string(requestID), "error": .string(error)],
        ]
    }
}
