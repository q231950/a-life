import ALifeAPI
import Vapor

/// A character that only pretends. Every instruction plays a short script,
/// so a front end can be exercised end to end without any real agents. What
/// the script does depends on the character:
///
/// - One that only looks around (`changes_things` false) reads, then sends two helpers
///   off to search, and reports once both have reported back to it. It never
///   needs permission, like a Claude Code session in plan mode.
/// - One that changes things (the Builder) looks first and sends a helper off
///   to measure, then asks before it runs a shell command, and waits as long
///   as it takes for the answer.
///
/// The helpers stand in for a Claude Code session's subagents: each works on
/// its own for a few steps, then reports back to the character that sent it.
///
/// Like a real session, it can be talked to while it works. Something said
/// mid-task is answered at the character's next step, with what it is
/// doing, and the work carries on. Something said while it waits for an
/// approval is refused: answer the approval first. Anything said after the
/// last step becomes the next instruction.
///
/// Each instruction also uses up a little of a made-up 5-hour window, so the
/// front ends' gauge and the lot's day can be tried without a model, and
/// fills a made-up context, which "compacts" once it reaches the point
/// where Claude Code would, so the context ring can be tried too.
///
/// It takes a model from the model picker as a Claude Code session would,
/// so the picker can be tried, but runs on none, and its choice isn't kept
/// across a restart of the server.
actor DummyCharacter: SessionBackend {
    /// The made-up context's window, where it compacts, what it holds when
    /// it starts and after it compacts, and what a step and a reply add.
    static let contextWindow = 200_000
    static let compactsAt = 167_000
    static let startingTokens = 15_000
    static let compactedTokens = 20_000
    static let tokensPerStep = 12_000
    static let tokensPerReply = 2_000

    private let profile: Character
    private let hub: SessionHub
    private let step: Duration
    /// Where the made-up usage goes.
    private let usage: UsageHub?

    /// What was said and not yet taken up, oldest first.
    private var inbox: [String] = []
    private var worker: Task<Void, Never>?
    /// Goes up whenever the current worker is abandoned, so it can tell.
    private var generation = 0
    private var pendingApproval: (id: String, answer: AsyncStream<Bool>.Continuation)?
    /// The helpers that are out and haven't reported back yet, by id.
    private var helpersOut: [String] = []
    /// How many tokens the made-up context holds, once the session has
    /// started.
    private var usedTokens: Int?

    init(_ profile: Character, hub: SessionHub, step: Duration, usage: UsageHub? = nil) {
        self.profile = profile
        self.hub = hub
        self.step = step
        self.usage = usage
    }

    // MARK: SessionBackend

    func handleMessage(_ text: String) async throws {
        guard pendingApproval == nil else {
            throw Abort(.conflict, reason: "\(profile.name) is waiting for an answer to its request")
        }
        await hub.emit(.message(Message(kind: .user, speaker: "You", text: text)))
        await usage?.recordMadeUpUse(at: Date())
        await fillContext(by: usedTokens == nil ? Self.startingTokens : Self.tokensPerReply)
        inbox.append(text)
        if worker == nil {
            let generation = generation
            worker = Task { await self.workThroughInbox(generation) }
        }
    }

    func interrupt() async {
        let wasBusy = worker != nil
        await stopWorking()
        guard wasBusy else { return }
        await hub.emit(.activityChanged(nil))
        await hub.emit(.statusChanged(.idle, stopReason: .interrupted))
    }

    func decide(approvalID: String, allow: Bool) async throws {
        guard await answer(approvalID, allow: allow, as: allow ? .allowed : .denied) else {
            throw Abort(.notFound, reason: "No such approval")
        }
    }

    func setAutoApprove(_ enabled: Bool) async {
        await hub.setAutoApprove(enabled)
        if enabled, let pending = pendingApproval {
            _ = await answer(pending.id, allow: true, as: .autoApproved)
        }
    }

    func setModel(_ model: ClaudeModel?) async {
        await hub.setModel(model ?? profile.model)
    }

    func reset() async {
        await stopWorking()
        usedTokens = nil
        await hub.startConversation()
    }

    // MARK: The script

    private func workThroughInbox(_ generation: Int) async {
        while self.generation == generation, !inbox.isEmpty {
            let instruction = inbox.removeFirst()
            do {
                try await carryOut(instruction)
            } catch {
                return // interrupted or reset; whoever did that tidies up
            }
        }
        if self.generation == generation { worker = nil }
    }

    private func carryOut(_ instruction: String) async throws {
        try await post(.statusChanged(.running, stopReason: nil))
        try await work("read", doing: "looking around the lot", on: instruction)

        guard profile.changesThings else {
            try await sendHelpers([
                Errand(task: "Search the flower beds", steps: 4),
                Errand(task: "Check the hedges", steps: 6),
            ], on: instruction)
            try await finish("Had a look around for “\(instruction)”. My helpers searched the flower beds and checked the hedges, and nothing is in the way.")
            return
        }

        try await sendHelpers([Errand(task: "Measure the north corner", steps: 4)], on: instruction)
        let allowed = try await ask(Approval(toolName: "bash", input: "mv ./shed ./lot/north-corner"))
        if allowed {
            try await work("bash", doing: "moving the shed", on: instruction)
            try await finish("Moved the shed to the north corner for “\(instruction)”.")
        } else {
            try await finish("Left the shed where it is, so nothing changed for “\(instruction)”.")
        }
    }

    // MARK: Steps

    /// One step of the work. Afterwards, answers whatever was said meanwhile.
    private func work(_ activity: String, doing description: String, on instruction: String) async throws {
        try await post(.activityChanged(activity))
        try await post(.toolUsed(ToolUse(toolName: activity, input: description)))
        await fillContext(by: Self.tokensPerStep)
        try await Task.sleep(for: step)
        try await answerWhatWasSaid(doing: description, on: instruction)
    }

    /// Something a helper is sent off to do, and how many steps it takes.
    private struct Errand {
        let task: String
        let steps: Int
    }

    /// Sends a helper off for each errand, all at once, and waits until every
    /// one has reported back. Answers whatever is said meanwhile at each step.
    private func sendHelpers(_ errands: [Errand], on instruction: String) async throws {
        var out: [(helper: Subagent, stepsLeft: Int)] = []
        for errand in errands {
            let helper = Subagent(task: errand.task)
            // Counted as out before it is announced, so stopping the work
            // meanwhile calls it back. A stopped worker sends no one.
            try Task.checkCancellation()
            helpersOut.append(helper.id)
            await hub.emit(.subagentStarted(helper))
            out.append((helper, errand.steps))
        }
        try await post(.activityChanged("agent"))

        while !out.isEmpty {
            try await Task.sleep(for: step)
            for index in out.indices {
                out[index].stepsLeft -= 1
            }
            for (helper, stepsLeft) in out where stepsLeft <= 0 {
                try Task.checkCancellation() // if stopped, it was called back already
                helpersOut.removeAll { $0 == helper.id }
                await hub.emit(.subagentFinished(subagentID: helper.id))
            }
            out.removeAll { $0.stepsLeft <= 0 }
            try await answerWhatWasSaid(doing: "waiting for my helpers to report back", on: instruction)
        }
    }

    private func answerWhatWasSaid(doing description: String, on instruction: String) async throws {
        // A worker that was stopped mustn't take what was said to the next one.
        while !Task.isCancelled, !inbox.isEmpty {
            inbox.removeFirst()
            try await say("Still on “\(instruction)”. Right now I'm \(description).")
        }
    }

    /// Asks for approval of a tool call and waits until a front end answers,
    /// or allows it straight away if auto approve is on.
    private func ask(_ approval: Approval) async throws -> Bool {
        let (answers, continuation) = AsyncStream<Bool>.makeStream()
        pendingApproval = (approval.id, continuation)
        try await post(.activityChanged(nil))
        try await post(.approvalRequested(approval))
        let waits = await !hub.state.autoApprove
        if waits {
            try await post(.statusChanged(.idle, stopReason: .requiresAction))
        } else {
            _ = await answer(approval.id, allow: true, as: .autoApproved)
        }
        for await allowed in answers { // the approval has been resolved already
            if waits {
                try await post(.statusChanged(.running, stopReason: nil))
            }
            return allowed
        }
        throw CancellationError() // the stream ended without an answer
    }

    /// Answers the approval waiting, if `approvalID` is it, and says how it
    /// was settled. Returns `false` if it isn't waiting.
    private func answer(_ approvalID: String, allow: Bool, as outcome: ApprovalOutcome) async -> Bool {
        guard let pending = pendingApproval, pending.id == approvalID else { return false }
        pendingApproval = nil
        await hub.emit(.approvalResolved(approvalID: approvalID, outcome: outcome))
        pending.answer.yield(allow)
        pending.answer.finish()
        return true
    }

    private func finish(_ reply: String) async throws {
        try await post(.activityChanged(nil))
        try await say("\(reply) (Dummy: nothing real happened.)")
        try await post(.statusChanged(.idle, stopReason: .endTurn))
    }

    private func say(_ text: String) async throws {
        try await post(.message(Message(kind: .agent, speaker: profile.name, text: text)))
        await fillContext(by: Self.tokensPerReply)
    }

    /// Adds `tokens` to the made-up context and says how full it is. Once
    /// it would pass the compaction point, it compacts, as Claude Code's
    /// would.
    private func fillContext(by tokens: Int) async {
        guard !Task.isCancelled else { return } // a stopped script says no more
        var used = (usedTokens ?? 0) + tokens
        if used > Self.compactsAt { used = Self.compactedTokens }
        usedTokens = used
        await hub.emit(.contextChanged(Self.context(holding: used)))
    }

    /// The made-up context, holding `usedTokens`.
    static func context(holding usedTokens: Int) -> SessionContext {
        SessionContext(model: "dummy", usedTokens: usedTokens, compactsAt: compactsAt, contextWindow: contextWindow, autoCompact: true)
    }

    /// Emits an event, unless the script was cancelled in the meantime.
    private func post(_ event: SessionEvent) async throws {
        try Task.checkCancellation()
        await hub.emit(event)
    }

    /// Cancels the script and forgets what was said and not yet taken up.
    /// Emits only what must not be left dangling: a pending approval, and
    /// helpers that are still out, which are called back.
    private func stopWorking() async {
        generation += 1
        worker?.cancel()
        worker = nil
        inbox = []
        let calledBack = helpersOut
        helpersOut = []
        if let pending = pendingApproval {
            pendingApproval = nil
            pending.answer.finish()
            await hub.emit(.approvalResolved(approvalID: pending.id, outcome: .withdrawn))
        }
        for id in calledBack {
            await hub.emit(.subagentFinished(subagentID: id))
        }
    }
}
