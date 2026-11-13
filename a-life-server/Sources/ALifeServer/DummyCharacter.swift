import ALifeAPI
import Vapor

/// A character that only pretends. Every instruction plays a short script,
/// so a front end can be exercised end to end without any real agents. What
/// the script does depends on the character:
///
/// - One that only looks around (the Gardener) reads and searches, then
///   reports. It never needs permission, like a Claude Code session in plan
///   mode.
/// - One that changes things (the Builder) looks first, then asks before it
///   runs a shell command, and waits as long as it takes for the answer.
///
/// Like a real session, it can be talked to while it works. Something said
/// mid-task is answered at the character's next step, with what it is
/// doing, and the work carries on. Something said while it waits for an
/// approval is refused: answer the approval first. Anything said after the
/// last step becomes the next instruction.
actor DummyCharacter: SessionBackend {
    struct Profile: Sendable {
        /// Used in the session's URLs, such as `gardener`.
        let id: String
        let name: String
        /// Whether the character changes things, and so asks before it runs
        /// a command.
        let changesThings: Bool
    }

    private let profile: Profile
    private let hub: SessionHub
    private let step: Duration

    /// What was said and not yet taken up, oldest first.
    private var inbox: [String] = []
    private var worker: Task<Void, Never>?
    /// Goes up whenever the current worker is abandoned, so it can tell.
    private var generation = 0
    private var pendingApproval: (id: String, answer: AsyncStream<Bool>.Continuation)?

    init(_ profile: Profile, hub: SessionHub, step: Duration) {
        self.profile = profile
        self.hub = hub
        self.step = step
    }

    // MARK: SessionBackend

    func handleMessage(_ text: String) async throws {
        guard pendingApproval == nil else {
            throw Abort(.conflict, reason: "\(profile.name) is waiting for an answer to its request")
        }
        await hub.emit(.message(Message(kind: .user, speaker: "You", text: text)))
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
        guard let pending = pendingApproval, pending.id == approvalID else {
            throw Abort(.notFound, reason: "No such approval")
        }
        pendingApproval = nil
        await hub.emit(.approvalResolved(approvalID: approvalID))
        pending.answer.yield(allow)
        pending.answer.finish()
    }

    func reset() async {
        await stopWorking()
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
            try await work("grep", doing: "searching the flower beds", on: instruction)
            try await finish("Had a look around for “\(instruction)”. Nothing is in the way.")
            return
        }

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
        try await Task.sleep(for: step)
        // A worker that was stopped mustn't take what was said to the next one.
        while !Task.isCancelled, !inbox.isEmpty {
            inbox.removeFirst()
            try await say("Still on “\(instruction)”. Right now I'm \(description).")
        }
    }

    /// Asks for approval of a tool call and waits until a front end answers.
    private func ask(_ approval: Approval) async throws -> Bool {
        let (answers, continuation) = AsyncStream<Bool>.makeStream()
        pendingApproval = (approval.id, continuation)
        try await post(.activityChanged(nil))
        try await post(.approvalRequested(approval))
        try await post(.statusChanged(.idle, stopReason: .requiresAction))
        for await allowed in answers { // `decide` has already resolved the approval
            try await post(.statusChanged(.running, stopReason: nil))
            return allowed
        }
        throw CancellationError() // the stream ended without an answer
    }

    private func finish(_ reply: String) async throws {
        try await post(.activityChanged(nil))
        try await say("\(reply) (Dummy: nothing real happened.)")
        try await post(.statusChanged(.idle, stopReason: .endTurn))
    }

    private func say(_ text: String) async throws {
        try await post(.message(Message(kind: .agent, speaker: profile.name, text: text)))
    }

    /// Emits an event, unless the script was cancelled in the meantime.
    private func post(_ event: SessionEvent) async throws {
        try Task.checkCancellation()
        await hub.emit(event)
    }

    /// Cancels the script and forgets what was said and not yet taken up.
    /// Emits only what must not be left dangling: a pending approval.
    private func stopWorking() async {
        generation += 1
        worker?.cancel()
        worker = nil
        inbox = []
        if let pending = pendingApproval {
            pendingApproval = nil
            pending.answer.finish()
            await hub.emit(.approvalResolved(approvalID: pending.id))
        }
    }
}
