import ALifeAPI
import Vapor

/// A team that only pretends. Every instruction plays the same short script,
/// so a front end can be exercised end to end without any real agents:
///
/// 1. The team lead plans, and hands a task each to the Gardener and the Builder.
/// 2. The Gardener reports back.
/// 3. The Builder asks for approval of a shell command and waits for the answer.
/// 4. The Builder reports back, and the team lead sums up.
///
/// Instructions that arrive while the script is playing queue up. An
/// interrupt stops the whole team, whichever agent it names.
actor DummyTeam: TeamBackend {
    private let hub: SessionHub
    private let step: Duration

    private var lead = Agent(id: "lead", name: "Team lead", isCoordinator: true)
    private var teammates: [String: Agent] = [:]
    private var queue: [String] = []
    private var worker: Task<Void, Never>?
    /// Goes up whenever the current worker is abandoned, so it can tell.
    private var generation = 0
    private var pendingApproval: (id: String, answer: AsyncStream<Bool>.Continuation)?

    init(hub: SessionHub, step: Duration) {
        self.hub = hub
        self.step = step
    }

    // MARK: TeamBackend

    func handleMessage(_ text: String) async {
        await hub.emit(.message(Message(kind: .user, speaker: "You", text: text)))
        queue.append(text)
        if worker == nil {
            let generation = generation
            worker = Task { await self.workThroughQueue(generation) }
        }
    }

    func interrupt(agentID: String?) async {
        let wasBusy = worker != nil
        await stopWorking()
        guard wasBusy else { return }
        lead.status = .idle
        lead.activity = nil
        await hub.emit(.agentUpdated(lead))
        for id in teammates.keys.sorted() {
            teammates[id]?.status = .idle
            teammates[id]?.activity = nil
            await hub.emit(.agentUpdated(teammates[id]!))
        }
        await hub.emit(.statusChanged(.idle, stopReason: .interrupted))
    }

    func decide(approvalID: String, allow: Bool) async throws {
        guard let pending = pendingApproval, pending.id == approvalID else {
            throw Abort(.notFound, reason: "No such approval")
        }
        pendingApproval = nil
        pending.answer.yield(allow)
        pending.answer.finish()
    }

    func reset() async {
        await stopWorking()
        lead = Agent(id: "lead", name: "Team lead", isCoordinator: true)
        teammates = [:]
        await hub.startSession()
        await hub.emit(.agentUpdated(lead))
    }

    // MARK: The script

    private func workThroughQueue(_ generation: Int) async {
        while self.generation == generation, !queue.isEmpty {
            let instruction = queue.removeFirst()
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
        try await setLead(.running, doing: "planning")
        try await pause()

        try await say(.handoff, as: "Team lead → Gardener", "Take a look around for: \(instruction)")
        try await setTeammate("gardener", named: "Gardener", .running, doing: "read")
        try await say(.handoff, as: "Team lead → Builder", "Get ready to do: \(instruction)")
        try await setTeammate("builder", named: "Builder", .running, doing: "bash")
        try await setLead(.idle)
        try await pause()

        try await say(.handoff, as: "Gardener → Team lead", "Had a look. Nothing is in the way.")
        try await setTeammate("gardener", named: "Gardener", .idle)
        try await pause()

        let approval = Approval(agentID: "builder", agentName: "Builder", toolName: "bash", input: "mv ./shed ./lot/north-corner")
        try await setTeammate("builder", named: "Builder", .idle)
        try await post(.approvalRequested(approval))
        try await post(.statusChanged(.idle, stopReason: .requiresAction))
        let allowed = try await answer(to: approval)
        try await post(.approvalResolved(approvalID: approval.id))
        try await post(.statusChanged(.running, stopReason: nil))

        try await setTeammate("builder", named: "Builder", .running, doing: "bash")
        try await pause()
        try await say(.handoff, as: "Builder → Team lead", allowed ? "Moved the shed to the north corner." : "Left the shed where it is.")
        try await setTeammate("builder", named: "Builder", .idle)

        try await setLead(.running, doing: "writing")
        try await pause()
        let outcome = allowed ? "the Builder moved the shed" : "the Builder left the shed alone"
        try await say(.agent, as: "Team lead", "Done with “\(instruction)”: the Gardener checked the lot and \(outcome). (Dummy team: nothing real happened.)")
        try await setLead(.idle)
        try await post(.statusChanged(.idle, stopReason: .endTurn))
    }

    /// Waits until a front end answers the approval.
    private func answer(to approval: Approval) async throws -> Bool {
        let (answers, continuation) = AsyncStream<Bool>.makeStream()
        pendingApproval = (approval.id, continuation)
        for await allowed in answers {
            return allowed
        }
        throw CancellationError() // the stream ended without an answer
    }

    /// Cancels the script and forgets what was queued. Emits only what must
    /// not be left dangling: a pending approval.
    private func stopWorking() async {
        generation += 1
        worker?.cancel()
        worker = nil
        queue = []
        if let pending = pendingApproval {
            pendingApproval = nil
            pending.answer.finish()
            await hub.emit(.approvalResolved(approvalID: pending.id))
        }
    }

    // MARK: Steps

    /// Emits an event, unless the script was cancelled in the meantime.
    private func post(_ event: SessionEvent) async throws {
        try Task.checkCancellation()
        await hub.emit(event)
    }

    private func pause() async throws {
        try await Task.sleep(for: step)
    }

    private func say(_ kind: Message.Kind, as speaker: String, _ text: String) async throws {
        try await post(.message(Message(kind: kind, speaker: speaker, text: text)))
    }

    private func setLead(_ status: RunStatus, doing activity: String? = nil) async throws {
        try Task.checkCancellation()
        lead.status = status
        lead.activity = activity
        try await post(.agentUpdated(lead))
    }

    private func setTeammate(_ id: String, named name: String, _ status: RunStatus, doing activity: String? = nil) async throws {
        try Task.checkCancellation()
        let agent = Agent(id: id, name: name, status: status, activity: activity)
        teammates[id] = agent
        try await post(.agentUpdated(agent))
    }
}
